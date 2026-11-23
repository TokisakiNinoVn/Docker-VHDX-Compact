# DockerCompact-Common.ps1
# Shared helpers for docker-compact.ps1, DockerCompact-AutoSetup.ps1
# and DockerCompact-UI.ps1. Dot-source this file; it has no side effects
# other than defining variables and functions.

$script:DcRoot = if ($PSScriptRoot) { $PSScriptRoot } else { "C:\Scripts" }

$script:DcTaskName   = "DockerCompact"
$script:DcEnginePath = Join-Path $script:DcRoot "docker-compact.ps1"
$script:DcSetupPath  = Join-Path $script:DcRoot "DockerCompact-AutoSetup.ps1"
$script:DcUiPath     = Join-Path $script:DcRoot "DockerCompact-UI.ps1"
# Installed copies (Program Files, admin-only) log to ProgramData;
# a portable copy (e.g. C:\Scripts) logs next to the scripts.
$script:DcLogDir = if (($script:DcRoot -like "$env:ProgramFiles\*") -or
                       (${env:ProgramFiles(x86)} -and ($script:DcRoot -like "${env:ProgramFiles(x86)}\*"))) {
    Join-Path $env:ProgramData "DockerCompact\logs"
}
else {
    Join-Path $script:DcRoot "logs"
}
$script:DcTxtLog     = Join-Path $script:DcLogDir "docker-compact.log"
$script:DcCsvLog     = Join-Path $script:DcLogDir "docker-compact-history-v2.csv"
$script:DcVhdxDefault = Join-Path $env:LOCALAPPDATA "Docker\wsl\disk\docker_data.vhdx"
# Callers may override this (engine/AutoSetup -VhdxPath, UI settings).
$script:DcVhdxPath    = $script:DcVhdxDefault
$script:DcLangPath    = Join-Path $script:DcRoot "DockerCompact-Lang.json"
$script:DcSettingsPath = Join-Path $env:APPDATA "DockerCompact\settings.json"
$script:DcStartupTaskName = "DockerCompact-Startup"
$script:DcDataMount   = "/mnt/docker-desktop-disk"
# GitHub repository used for update checks.
$script:DcRepo        = "TokisakiNinoVn/Docker-VHDX-Compact"
# True when running from the installer's copy (updates install over it).
$script:DcIsInstalled = $script:DcLogDir -like "$env:ProgramData\*"

# App version from the VERSION file (shipped next to the scripts).
$script:DcVersion = ""
$verFile = Join-Path $script:DcRoot "VERSION"
if (Test-Path -LiteralPath $verFile -PathType Leaf) {
    $script:DcVersion = ((Get-Content -LiteralPath $verFile -Raw) -replace '\s', '')
}

# App icon: installed copy next to the scripts, or the repo's assets folder.
$script:DcIconPath = @(
    (Join-Path $script:DcRoot "DockerCompact.ico"),
    (Join-Path $script:DcRoot "assets\images\icon-no-background.ico")
) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1

# Step ids and titles shared by the engine and the UI.
# Order matters: it is the order the engine executes them.
$script:DcSteps = @(
    [pscustomobject]@{ Id = "preflight";    Title = "Check prerequisites" }
    [pscustomobject]@{ Id = "prune";        Title = "Prune unused Docker objects" }
    [pscustomobject]@{ Id = "trim";         Title = "Trim free space (fstrim)" }
    [pscustomobject]@{ Id = "stop-docker";  Title = "Close Docker Desktop" }
    [pscustomobject]@{ Id = "wsl-shutdown"; Title = "Shut down WSL" }
    [pscustomobject]@{ Id = "release";      Title = "Release VHDX file lock" }
    [pscustomobject]@{ Id = "attach";       Title = "Attach VHDX (read-only)" }
    [pscustomobject]@{ Id = "compact";      Title = "Compact VHDX" }
    [pscustomobject]@{ Id = "detach";       Title = "Detach VHDX" }
    [pscustomobject]@{ Id = "start-docker"; Title = "Start Docker Desktop" }
)


function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}


function Find-DockerDesktopExe {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\DockerDesktop\Docker Desktop.exe"),
        (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe")
    )

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return $c
        }
    }

    return $null
}


# Real space the (possibly sparse) VHDX occupies on the host drive.
# Works without the Hyper-V module, unlike Get-VHD.
if (-not ("DockerCompact.NativeFile" -as [type])) {
    Add-Type -Namespace DockerCompact -Name NativeFile -MemberDefinition @"
[DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
public static extern uint GetCompressedFileSizeW(string lpFileName, out uint lpFileSizeHigh);
"@
}

function Get-SizeOnDisk {
    param([Parameter(Mandatory = $true)][string]$Path)

    $high = [uint32]0
    $low = [DockerCompact.NativeFile]::GetCompressedFileSizeW($Path, [ref]$high)

    if ($low -eq [uint32]::MaxValue) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        if ($code -ne 0) { return $null }
    }

    return ([uint64]$high -shl 32) + [uint64]$low
}


function Get-DiskSnapshot {
    param([string]$Path = $script:DcVhdxPath)

    $fileSize = $null
    $onDisk = $null
    $allocated = $null
    $virtual = $null
    $lastWrite = $null
    $free = $null
    $errors = New-Object System.Collections.Generic.List[string]

    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $item = Get-Item -LiteralPath $Path

            $fileSize = [math]::Round($item.Length / 1GB, 3)
            $lastWrite = $item.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")

            $bytes = Get-SizeOnDisk -Path $Path
            if ($null -ne $bytes) {
                $onDisk = [math]::Round($bytes / 1GB, 3)
            }

            if (Get-Command Get-VHD -ErrorAction SilentlyContinue) {
                try {
                    $vhd = Get-VHD -Path $Path -ErrorAction Stop
                    $allocated = [math]::Round($vhd.FileSize / 1GB, 3)
                    $virtual = [math]::Round($vhd.Size / 1GB, 3)
                }
                catch {
                    $errors.Add("Get-VHD failed: $($_.Exception.Message)")
                }
            }
        }
        else {
            $errors.Add("VHDX not found: $Path")
        }

        $drive = Get-PSDrive -Name ($Path.Substring(0, 1)) -ErrorAction Stop
        $free = [math]::Round($drive.Free / 1GB, 3)
    }
    catch {
        $errors.Add($_.Exception.Message)
    }

    [pscustomobject]@{
        VhdxFileSizeGiB   = $fileSize
        VhdxOnDiskGiB     = $onDisk
        VhdxAllocatedGiB  = $allocated
        VhdxVirtualGiB    = $virtual
        VhdxLastWriteTime = $lastWrite
        CFreeGiB          = $free
        SnapshotError     = ($errors -join " | ")
    }
}


function Write-RunLog {
    param([Parameter(ValueFromPipeline = $true)][AllowEmptyString()][string[]]$Line)

    begin {
        New-Item -ItemType Directory -Path $script:DcLogDir -Force | Out-Null
    }
    process {
        if ($null -ne $Line) {
            Add-Content -LiteralPath $script:DcTxtLog -Encoding UTF8 -Value $Line
        }
    }
}


function Get-Delta {
    param($Before, $After)

    if ($null -ne $Before -and $null -ne $After) {
        return [math]::Round($After - $Before, 3)
    }

    return $null
}


function Start-CompactRunLog {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [bool]$Prune
    )

    $run = [pscustomobject]@{
        Source  = $Source
        Prune   = $Prune
        Started = Get-Date
        Watch   = [Diagnostics.Stopwatch]::StartNew()
        Before  = Get-DiskSnapshot
    }

    Write-RunLog @(
        "",
        "===== START $($run.Started.ToString('yyyy-MM-dd HH:mm:ss')) ($Source) =====",
        "User: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)",
        "Compaction script: $script:DcEnginePath",
        "Prune before compaction: $Prune",
        ("BEFORE: " + ($run.Before | ConvertTo-Json -Compress))
    )

    return $run
}


function Complete-CompactRunLog {
    param(
        [Parameter(Mandatory = $true)]$Run,
        [Parameter(Mandatory = $true)][string]$Status,
        $ExitCode,
        [string]$ErrorMessage = ""
    )

    $Run.Watch.Stop()
    $ended = Get-Date
    $after = Get-DiskSnapshot
    $before = $Run.Before
    $duration = [math]::Round($Run.Watch.Elapsed.TotalSeconds, 2)

    Write-RunLog @(
        ("AFTER: " + ($after | ConvertTo-Json -Compress)),
        "Status: $Status; ExitCode: $ExitCode; DurationSeconds: $duration; Error: $ErrorMessage",
        "===== END $($ended.ToString('yyyy-MM-dd HH:mm:ss')) ====="
    )

    $row = [pscustomobject][ordered]@{
        StartTime              = $Run.Started.ToString("yyyy-MM-dd HH:mm:ss")
        EndTime                = $ended.ToString("yyyy-MM-dd HH:mm:ss")
        DurationSeconds        = $duration
        Source                 = $Run.Source
        Status                 = $Status
        ExitCode               = $ExitCode
        VhdxPath               = $script:DcVhdxPath
        VhdxFileSizeBeforeGiB  = $before.VhdxFileSizeGiB
        VhdxFileSizeAfterGiB   = $after.VhdxFileSizeGiB
        VhdxFileSizeDeltaGiB   = Get-Delta $before.VhdxFileSizeGiB $after.VhdxFileSizeGiB
        VhdxOnDiskBeforeGiB    = $before.VhdxOnDiskGiB
        VhdxOnDiskAfterGiB     = $after.VhdxOnDiskGiB
        VhdxOnDiskDeltaGiB     = Get-Delta $before.VhdxOnDiskGiB $after.VhdxOnDiskGiB
        VhdxAllocatedBeforeGiB = $before.VhdxAllocatedGiB
        VhdxAllocatedAfterGiB  = $after.VhdxAllocatedGiB
        VhdxAllocatedDeltaGiB  = Get-Delta $before.VhdxAllocatedGiB $after.VhdxAllocatedGiB
        VhdxVirtualBeforeGiB   = $before.VhdxVirtualGiB
        VhdxVirtualAfterGiB    = $after.VhdxVirtualGiB
        CFreeBeforeGiB         = $before.CFreeGiB
        CFreeAfterGiB          = $after.CFreeGiB
        CFreeDeltaGiB          = Get-Delta $before.CFreeGiB $after.CFreeGiB
        Error                  = $ErrorMessage
        BeforeSnapshotError    = $before.SnapshotError
        AfterSnapshotError     = $after.SnapshotError
    }

    New-Item -ItemType Directory -Path $script:DcLogDir -Force | Out-Null

    if (Test-Path -LiteralPath $script:DcCsvLog) {
        # -Force tolerates history files written by older versions.
        $row | Export-Csv -LiteralPath $script:DcCsvLog -NoTypeInformation `
            -Append -Force -Encoding UTF8
    }
    else {
        $row | Export-Csv -LiteralPath $script:DcCsvLog -NoTypeInformation `
            -Encoding UTF8
    }

    return [pscustomobject]@{ Before = $before; After = $after; Row = $row }
}


# ------------------------------------------------------------
# Per-user GUI settings (language, VHDX path).
# ------------------------------------------------------------
function Get-DcSettings {
    $s = [pscustomobject]@{ Language = $null; VhdxPath = $null }

    try {
        if (Test-Path -LiteralPath $script:DcSettingsPath) {
            $raw = [IO.File]::ReadAllText($script:DcSettingsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($raw.Language) { $s.Language = [string]$raw.Language }
            if ($raw.VhdxPath) { $s.VhdxPath = [string]$raw.VhdxPath }
        }
    }
    catch { }

    return $s
}

function Save-DcSettings {
    param([Parameter(Mandatory = $true)]$Settings)

    try {
        $dir = Split-Path -Parent $script:DcSettingsPath
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $json = $Settings | ConvertTo-Json
        [IO.File]::WriteAllText($script:DcSettingsPath, $json, (New-Object Text.UTF8Encoding($false)))
    }
    catch { }
}

# UI strings live in a UTF-8 JSON file so Vietnamese text survives
# Windows PowerShell 5.1 (which reads BOM-less .ps1 files as ANSI).
function Read-DcStrings {
    $json = [IO.File]::ReadAllText($script:DcLangPath, [Text.Encoding]::UTF8)
    return ($json | ConvertFrom-Json)
}


# ------------------------------------------------------------
# Scheduled task: read the current schedule back from its XML.
# ------------------------------------------------------------
$script:DcWeekDays = @("Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday")

function Get-DcSchedule {
    try {
        $task = Get-ScheduledTask -TaskName $script:DcTaskName -ErrorAction Stop
    }
    catch {
        return $null
    }

    $s = [pscustomobject]@{
        State      = "$($task.State)"
        NextRun    = $null
        LastRun    = $null
        LastResult = $null
        Frequency  = "Custom"
        Interval   = 1
        Days       = @()
        DayOfMonth = $null
        Time       = "03:00"
        Prune      = $false
        PruneAll   = $false
        VhdxPath   = $null
    }

    try {
        $info = $task | Get-ScheduledTaskInfo
        $s.NextRun = $info.NextRunTime
        $s.LastRun = $info.LastRunTime
        $s.LastResult = $info.LastTaskResult
    }
    catch { }

    try {
        [xml]$x = Export-ScheduledTask -TaskName $script:DcTaskName
        $ns = New-Object Xml.XmlNamespaceManager($x.NameTable)
        $ns.AddNamespace("t", "http://schemas.microsoft.com/windows/2004/02/mit/task")

        $ct = $x.SelectSingleNode("//t:Triggers/t:CalendarTrigger", $ns)
        if ($ct) {
            $sb = $ct.SelectSingleNode("t:StartBoundary", $ns)
            if ($sb) { $s.Time = ([datetime]$sb.InnerText).ToString("HH:mm") }

            $byDay = $ct.SelectSingleNode("t:ScheduleByDay", $ns)
            $byWeek = $ct.SelectSingleNode("t:ScheduleByWeek", $ns)
            $byMonth = $ct.SelectSingleNode("t:ScheduleByMonth", $ns)

            if ($byDay) {
                $s.Frequency = "Daily"
                $n = $byDay.SelectSingleNode("t:DaysInterval", $ns)
                if ($n) { $s.Interval = [int]$n.InnerText }
            }
            elseif ($byWeek) {
                $s.Frequency = "Weekly"
                $n = $byWeek.SelectSingleNode("t:WeeksInterval", $ns)
                if ($n) { $s.Interval = [int]$n.InnerText }
                $s.Days = @($byWeek.SelectNodes("t:DaysOfWeek/*", $ns) | ForEach-Object { $_.LocalName })
            }
            elseif ($byMonth) {
                $days = @($byMonth.SelectNodes("t:DaysOfMonth/t:Day", $ns) | ForEach-Object { $_.InnerText })
                if ($days.Count -eq 1) {
                    $s.Frequency = "Monthly"
                    $s.DayOfMonth = $days[0]
                }
            }
        }

        $argNode = $x.SelectSingleNode("//t:Actions/t:Exec/t:Arguments", $ns)
        if ($argNode) {
            $a = $argNode.InnerText
            $s.Prune = $a -match '(^|\s)-Prune(\s|$)'
            $s.PruneAll = $a -match '(^|\s)-PruneAll(\s|$)'
            if ($a -match '-VhdxPath\s+"([^"]+)"') { $s.VhdxPath = $Matches[1] }
        }
    }
    catch { }

    return $s
}


# ------------------------------------------------------------
# VHDX information (used by the engine's preflight and the UI)
# ------------------------------------------------------------
function Test-FileUnlocked {
    param([string]$Path)

    try {
        $fs = [IO.File]::Open(
            $Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            [IO.FileShare]::None
        )
        $fs.Dispose()
        return $true
    }
    catch {
        return $false
    }
}

function Get-DockerDiskUsedBytes {
    # Space used by the ext4 filesystem inside the VHDX. Only call this while
    # Docker Desktop is running, or wsl.exe would boot the distro.
    $out = @(& wsl.exe -d docker-desktop -u root -e df -B1 $script:DcDataMount 2>$null |
        ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or $out.Count -lt 2) { return $null }

    $cols = ($out[-1].Trim() -split "\s+")
    if ($cols.Count -ge 3 -and $cols[2] -match '^\d+$') { return [int64]$cols[2] }
    return $null
}

function Read-VhdxMetadata {
    # Reads the maximum (virtual) size and the disk type straight from the
    # VHDX header (MS-VHDX spec), so it works without the Hyper-V module.
    # Returns $null when the file cannot be read (e.g. opened exclusively).
    param([string]$Path)

    $regionMeta = [guid]"8B7CA206-4790-4B9A-B8FE-575F050F886E"
    $itemSize   = [guid]"2FA54224-CD1B-4876-B211-5DBED83BF4B8"
    $itemParams = [guid]"CAA16737-FA36-4D43-B3B6-33F0AA44E76B"

    $fs = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $br = New-Object IO.BinaryReader($fs)

        $sig = [Text.Encoding]::ASCII.GetString($br.ReadBytes(8))
        if ($sig -ne "vhdxfile") { return $null }

        # Region table (first copy at 192 KiB).
        $fs.Position = 192KB
        if ([Text.Encoding]::ASCII.GetString($br.ReadBytes(4)) -ne "regi") { return $null }
        [void]$br.ReadUInt32()                      # checksum
        $count = $br.ReadUInt32()
        [void]$br.ReadUInt32()                      # reserved
        $metaOffset = $null
        for ($i = 0; $i -lt [math]::Min($count, 2047); $i++) {
            $id = [guid]::new([byte[]]$br.ReadBytes(16))
            $off = $br.ReadUInt64()
            [void]$br.ReadUInt32(); [void]$br.ReadUInt32()
            if ($id -eq $regionMeta) { $metaOffset = [int64]$off }
        }
        if ($null -eq $metaOffset) { return $null }

        # Metadata table.
        $fs.Position = $metaOffset
        if ([Text.Encoding]::ASCII.GetString($br.ReadBytes(8)) -ne "metadata") { return $null }
        [void]$br.ReadUInt16()
        $entries = $br.ReadUInt16()
        [void]$br.ReadBytes(20)
        $items = @{}
        for ($i = 0; $i -lt [math]::Min($entries, 2047); $i++) {
            $id = [guid]::new([byte[]]$br.ReadBytes(16))
            $off = $br.ReadUInt32()
            [void]$br.ReadUInt32(); [void]$br.ReadUInt32(); [void]$br.ReadUInt32()
            $items[$id] = $off
        }

        $r = [pscustomobject]@{ VirtualSize = $null; Type = $null }
        if ($items.ContainsKey($itemSize)) {
            $fs.Position = $metaOffset + $items[$itemSize]
            $r.VirtualSize = [int64]$br.ReadUInt64()
        }
        if ($items.ContainsKey($itemParams)) {
            $fs.Position = $metaOffset + $items[$itemParams]
            [void]$br.ReadUInt32()                  # block size
            $flags = $br.ReadUInt32()
            $r.Type = if ($flags -band 2) { "Differencing" } elseif ($flags -band 1) { "Fixed" } else { "Dynamic" }
        }
        return $r
    }
    catch {
        return $null
    }
    finally {
        if ($fs) { $fs.Dispose() }
    }
}

function Get-VhdxInfo {
    # Everything the UI's "VHDX info" view shows. Sizes are in bytes.
    param([string]$Path = $script:DcVhdxPath)

    $i = [ordered]@{
        Path          = $Path
        Exists        = $false
        FileSize      = $null
        OnDisk        = $null
        Created       = $null
        Modified      = $null
        VirtualSize   = $null
        Type          = $null
        Sparse        = $false
        InUse         = $null
        DockerRunning = [bool](Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)
        UsedInside    = $null
        Drive         = $Path.Substring(0, [math]::Min(2, $Path.Length))
        DriveFree     = $null
    }

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $item = Get-Item -LiteralPath $Path
        $i.Exists   = $true
        $i.FileSize = [int64]$item.Length
        $i.OnDisk   = Get-SizeOnDisk -Path $Path
        $i.Created  = $item.CreationTime
        $i.Modified = $item.LastWriteTime
        $i.Sparse   = [bool]($item.Attributes -band [IO.FileAttributes]::SparseFile)
        $i.InUse    = -not (Test-FileUnlocked -Path $Path)

        $meta = Read-VhdxMetadata -Path $Path
        if ($meta) { $i.VirtualSize = $meta.VirtualSize; $i.Type = $meta.Type }
        elseif (Get-Command Get-VHD -ErrorAction SilentlyContinue) {
            try {
                $vhd = Get-VHD -Path $Path -ErrorAction Stop
                $i.VirtualSize = [int64]$vhd.Size
                $i.Type = [string]$vhd.VhdType
            }
            catch { }
        }

        if ($i.DockerRunning) { $i.UsedInside = Get-DockerDiskUsedBytes }
    }

    try {
        $drive = Get-PSDrive -Name ($Path.Substring(0, 1)) -ErrorAction Stop
        $i.DriveFree = [int64]$drive.Free
    }
    catch { }

    return [pscustomobject]$i
}


# ------------------------------------------------------------
# Start with Windows: a logon task that opens the UI (elevated,
# so there is no UAC prompt at every sign-in).
# ------------------------------------------------------------
function Get-DcStartupTask {
    return Get-ScheduledTask -TaskName $script:DcStartupTaskName -ErrorAction SilentlyContinue
}

function Set-DcStartup {
    param([Parameter(Mandatory = $true)][bool]$Enabled)

    if (-not $Enabled) {
        if (Get-DcStartupTask) {
            Unregister-ScheduledTask -TaskName $script:DcStartupTaskName -Confirm:$false -ErrorAction Stop
        }
        return
    }

    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $esc = { param($s) [Security.SecurityElement]::Escape($s) }
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Minimized' -f $script:DcUiPath

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Opens Docker VHDX Compact when you sign in.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$(& $esc $user)</UserId>
      <Delay>PT30S</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(& $esc $user)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(& $esc $psExe)</Command>
      <Arguments>$(& $esc $arguments)</Arguments>
      <WorkingDirectory>$(& $esc $script:DcRoot)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $script:DcStartupTaskName -Xml $xml -Force -ErrorAction Stop | Out-Null
}
