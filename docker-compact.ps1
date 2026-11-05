[CmdletBinding()]
param(
    # Only prune Docker objects when explicitly requested.
    [switch]$Prune,

    # With -Prune: also remove ALL unused images and ALL build cache
    # (docker system prune -a, docker builder prune -a). Volumes are kept.
    [switch]$PruneAll,

    # Emit machine-readable progress lines (used by DockerCompact-UI.ps1):
    #   ##STEP|<id>|<running|done|skipped|warn|failed>|<message>
    #   ##PCT|<id>|<0-100>
    [switch]$ProgressMarkers,

    # Do not start Docker Desktop afterwards if it was not running before.
    [switch]$KeepDockerStopped,

    # Docker data disk. Default: %LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx
    [string]$VhdxPath
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "DockerCompact-Common.ps1")

if ($VhdxPath) { $script:DcVhdxPath = $VhdxPath }

$vhd = $script:DcVhdxPath
$dockerExe = $null

$restartDocker = $false
$dockerWasRunning = $false
$compactSucceeded = $false
$script:currentStep = $null
$script:stepIndex = @{}
for ($i = 0; $i -lt $script:DcSteps.Count; $i++) {
    $script:stepIndex[$script:DcSteps[$i].Id] = $i + 1
}


function Write-Step {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)]
        [ValidateSet("running", "done", "skipped", "warn", "failed")]
        [string]$State,
        [string]$Message = ""
    )

    if ($State -eq "running") { $script:currentStep = $Id }
    elseif ($script:currentStep -eq $Id) { $script:currentStep = $null }

    $title = ($script:DcSteps | Where-Object Id -eq $Id).Title
    $n = $script:stepIndex[$Id]
    $total = $script:DcSteps.Count
    $text = if ($Message) { $Message } else { $title }

    $color = switch ($State) {
        "running" { "Cyan" }
        "done"    { "Green" }
        "skipped" { "DarkGray" }
        "warn"    { "Yellow" }
        "failed"  { "Red" }
    }

    Write-Host ("[{0}/{1}] {2,-8} {3}" -f $n, $total, $State.ToUpper(), $text) -ForegroundColor $color

    if ($ProgressMarkers) {
        $clean = ($Message -replace "[\r\n|]+", " ").Trim()
        Write-Host "##STEP|$Id|$State|$clean"
    }
}


function Write-Percent {
    param([string]$Id, [int]$Percent)

    if ($ProgressMarkers) {
        Write-Host "##PCT|$Id|$Percent"
    }
}


function Invoke-DiskPart {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Commands,

        # Step id that receives "NN percent completed" updates.
        [string]$PercentStep,

        [switch]$AllowFailure
    )

    $scriptFile = New-TemporaryFile

    try {
        $Commands | Set-Content -LiteralPath $scriptFile -Encoding ASCII

        $output = New-Object System.Collections.Generic.List[string]

        # Stream output line by line so progress is visible live.
        & diskpart.exe /s $scriptFile 2>&1 | ForEach-Object {
            $line = "$_"
            if ([string]::IsNullOrWhiteSpace($line)) { return }

            $output.Add($line)

            if ($PercentStep -and $line -match "(\d{1,3})\s+percent") {
                Write-Percent -Id $PercentStep -Percent ([int]$Matches[1])
            }
            else {
                Write-Host "    $line" -ForegroundColor DarkGray
            }
        }

        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0 -and -not $AllowFailure) {
            throw "DiskPart exited with code $exitCode. Output: $(($output | Select-Object -Last 3) -join ' / ')"
        }

        return ,$output.ToArray()
    }
    finally {
        Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
    }
}


function Invoke-DetachVhdx {
    # Returns "detached", "not-attached", or throws.
    $output = Invoke-DiskPart -AllowFailure -Commands @(
        "select vdisk file=`"$vhd`"",
        "detach vdisk",
        "exit"
    )

    $text = $output -join "`n"

    if ($text -match "(?i)successfully detached the virtual disk file") {
        return "detached"
    }

    if ($text -match "(?i)already detached|is not attached|not attached") {
        return "not-attached"
    }

    throw "Could not confirm that the VHDX was detached. Stopping for safety."
}


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


function Wait-FileUnlocked {
    param([string]$Path, [int]$TimeoutSeconds = 60)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        if (Test-FileUnlocked -Path $Path) { return $true }
        Start-Sleep -Seconds 2
    }

    return (Test-FileUnlocked -Path $Path)
}


# Docker Desktop mounts docker_data.vhdx here inside the docker-desktop
# WSL distro. The mount has no "discard" option, so space freed inside
# (deleted images, build cache...) is not released to the VHDX until
# fstrim runs. Without it, "compact vdisk" has nothing to reclaim.
$script:DataMount = "/mnt/docker-desktop-disk"

function Get-DockerDiskUsedBytes {
    $out = @(& wsl.exe -d docker-desktop -u root -e df -B1 $script:DataMount 2>$null |
        ForEach-Object { "$_" })
    if ($LASTEXITCODE -ne 0 -or $out.Count -lt 2) { return $null }

    $cols = ($out[-1].Trim() -split "\s+")
    if ($cols.Count -ge 3 -and $cols[2] -match '^\d+$') { return [int64]$cols[2] }
    return $null
}

function Invoke-DockerFsTrim {
    # Returns trimmed bytes (or 0 when the output could not be parsed); throws on failure.
    $out = @(& wsl.exe -d docker-desktop -u root -e /sbin/fstrim -v $script:DataMount 2>&1 |
        ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $out | Where-Object { $_.Trim() } | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

    if ($code -ne 0) {
        throw "fstrim failed (exit code $code): $(($out | Select-Object -Last 1))"
    }

    $text = $out -join " "
    if ($text -match '\((\d+) bytes\) trimmed') { return [int64]$Matches[1] }
    return [int64]0
}


function Get-DockerDesktopProcesses {
    Get-Process -Name "Docker Desktop", "com.docker.backend", "com.docker.build" `
        -ErrorAction SilentlyContinue
}


try {
    # 1. Preflight.
    Write-Step preflight running
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

    if (-not (Test-IsAdministrator)) {
        throw "Please run PowerShell as Administrator."
    }

    if (-not (Test-Path -LiteralPath $vhd -PathType Leaf)) {
        throw "Docker VHDX not found: $vhd"
    }

    $dockerExe = Find-DockerDesktopExe
    if (-not $dockerExe) {
        throw "Docker Desktop executable not found (checked %LOCALAPPDATA%\Programs\DockerDesktop and %ProgramFiles%\Docker\Docker)."
    }

    $dockerWasRunning = [bool](Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue)
    $snap = Get-DiskSnapshot
    $script:BeforeSnap = $snap
    $usedText = ""

    if ($dockerWasRunning) {
        $usedBytes = Get-DockerDiskUsedBytes
        if ($null -ne $usedBytes) {
            $usedGiB = [math]::Round($usedBytes / 1GB, 2)
            $maxGain = [math]::Max(0, [math]::Round($snap.VhdxOnDiskGiB - $usedGiB, 2))
            $usedText = ", data used inside {0} GiB (at most ~{1} GiB reclaimable)" -f $usedGiB, $maxGain
        }

        & docker.exe system df 2>$null | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
    }

    Write-Step preflight done ("VHDX {0} GiB (on disk {1} GiB), {4} free {2} GiB{3}" -f `
        $snap.VhdxFileSizeGiB, $snap.VhdxOnDiskGiB, $snap.CFreeGiB, $usedText, $vhd.Substring(0, 2))

    # 2. Optional cleanup. Never prune unless -Prune was explicitly supplied.
    if ($Prune) {
        Write-Step prune running "Checking Docker Engine..."

        & docker.exe info *> $null
        if ($LASTEXITCODE -ne 0) {
            throw "Docker Engine is unavailable. Prune and compaction cancelled."
        }

        $pruneFlags = @(if ($PruneAll) { "-a", "-f" } else { "-f" })

        Write-Step prune running "docker system prune $($pruneFlags -join ' ')"
        & docker.exe system prune @pruneFlags 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            throw "docker system prune failed. Compaction cancelled."
        }

        Write-Step prune running "docker builder prune $($pruneFlags -join ' ')"
        & docker.exe builder prune @pruneFlags 2>&1 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -ne 0) {
            throw "docker builder prune failed. Compaction cancelled."
        }

        Write-Step prune done
    }
    else {
        Write-Step prune skipped "Prune not requested"
    }

    # 3. Release free blocks inside the ext4 filesystem to the VHDX.
    if ($dockerWasRunning) {
        Write-Step trim running "fstrim $script:DataMount (can take a few minutes)..."
        try {
            $trimmed = Invoke-DockerFsTrim
            Write-Step trim done ("{0} GiB of free space released to the VHDX" -f [math]::Round($trimmed / 1GB, 2))
        }
        catch {
            Write-Step trim warn "$($_.Exception.Message) - compaction may reclaim little space"
        }
    }
    else {
        Write-Step trim warn "Docker Desktop is not running, so fstrim cannot run - compaction may reclaim little space"
    }

    # 4. Close Docker Desktop gracefully first.
    Write-Step stop-docker running
    $restartDocker = $dockerWasRunning -or -not $KeepDockerStopped

    if (Get-DockerDesktopProcesses) {
        Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue |
            ForEach-Object { [void]$_.CloseMainWindow() }

        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Process -Name "Docker Desktop" -ErrorAction SilentlyContinue) -and
               (Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
        }

        # Force-close anything that did not exit, including the backend
        # processes that can keep the VHDX open.
        Get-DockerDesktopProcesses | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Write-Step stop-docker done
    }
    else {
        Write-Step stop-docker done "Docker Desktop was not running"
    }

    # 4. Shut down WSL.
    Write-Step wsl-shutdown running
    & wsl.exe --shutdown
    if ($LASTEXITCODE -ne 0) {
        throw "wsl --shutdown failed. Compaction cancelled."
    }
    Start-Sleep -Seconds 5
    Write-Step wsl-shutdown done

    # 5. Make sure nothing holds the VHDX (previous failures were sharing
    # violations). Detach a stale DiskPart attachment if needed.
    Write-Step release running "Waiting for the VHDX to be released..."

    if (-not (Wait-FileUnlocked -Path $vhd -TimeoutSeconds 30)) {
        Write-Step release running "VHDX still locked; detaching stale attachment..."
        [void](Invoke-DetachVhdx)

        if (-not (Wait-FileUnlocked -Path $vhd -TimeoutSeconds 30)) {
            throw "The VHDX is still in use by another process. Close anything using WSL/Docker and retry."
        }
    }
    Write-Step release done "VHDX is not in use"

    # 6. Attach the VHDX read-only.
    Write-Step attach running
    $attachOutput = Invoke-DiskPart -Commands @(
        "select vdisk file=`"$vhd`"",
        "attach vdisk readonly",
        "exit"
    )
    if (($attachOutput -join "`n") -notmatch "(?i)successfully attached the virtual disk file") {
        throw "DiskPart did not confirm attachment. Compact was not attempted."
    }
    Write-Step attach done

    # 7. Compact the VHDX.
    Write-Step compact running "Compacting (this can take several minutes)..."
    Write-Percent -Id compact -Percent 0
    $compactOutput = Invoke-DiskPart -PercentStep compact -Commands @(
        "select vdisk file=`"$vhd`"",
        "compact vdisk",
        "exit"
    )
    if (($compactOutput -join "`n") -notmatch "(?i)successfully compacted the virtual disk file") {
        throw "DiskPart did not confirm successful compaction."
    }
    Write-Percent -Id compact -Percent 100
    Write-Step compact done

    # 8. Detach the VHDX before Docker starts again.
    Write-Step detach running
    $detachOutput = Invoke-DiskPart -Commands @(
        "select vdisk file=`"$vhd`"",
        "detach vdisk",
        "exit"
    )
    if (($detachOutput -join "`n") -notmatch "(?i)successfully detached the virtual disk file") {
        throw "Compaction may have succeeded, but VHDX detach was not confirmed."
    }
    Write-Step detach done

    $compactSucceeded = $true
}
catch {
    $message = $_.Exception.Message
    if ($script:currentStep) {
        Write-Step $script:currentStep failed $message
    }
    Write-Host "ERROR: $message" -ForegroundColor Red
}
finally {
    # On failure, try to detach the VHDX before restarting Docker.
    # Never delete, reset, unregister, or reformat the VHDX.
    if ($restartDocker -and -not $compactSucceeded) {
        try {
            Write-Host "Attempting VHDX cleanup after failure..."
            $r = Invoke-DetachVhdx
            Write-Host "VHDX cleanup: $r"
        }
        catch {
            Write-Warning ("Could not confirm VHDX detach. Check DiskPart output " +
                "before retrying. $($_.Exception.Message)")
        }
    }

    # Restart Docker if we stopped it (or always, unless -KeepDockerStopped).
    if ($restartDocker -and $dockerExe) {
        try {
            Write-Step start-docker running
            Start-Process -FilePath $dockerExe
            Write-Step start-docker done "Docker Desktop launched"
        }
        catch {
            Write-Step start-docker warn "Could not start Docker Desktop: $($_.Exception.Message)"
        }
    }
    else {
        Write-Step start-docker skipped "Docker Desktop left stopped"
    }
}

if (-not $compactSucceeded) {
    Write-Host "Docker VHDX compaction did not complete successfully." -ForegroundColor Red
    exit 1
}

$snap = Get-DiskSnapshot
$gain = Get-Delta $snap.VhdxOnDiskGiB $script:BeforeSnap.VhdxOnDiskGiB
Write-Host ""
Write-Host ("Docker VHDX compacted and detached successfully. VHDX now {0} GiB (on disk {1} GiB), reclaimed {2} GiB, {4} free {3} GiB." -f `
    $snap.VhdxFileSizeGiB, $snap.VhdxOnDiskGiB, $gain, $snap.CFreeGiB, $vhd.Substring(0, 2)) -ForegroundColor Green

if ($null -ne $gain -and $gain -lt 0.5) {
    Write-Host ("HINT: Little space was reclaimed. The VHDX can only shrink down to the data Docker still keeps. " +
        "Free more first, e.g. 'docker builder prune -a', 'docker image prune -a', 'docker volume prune', " +
        "then run the compaction again with Docker Desktop running so fstrim can release the space.") -ForegroundColor Yellow
}
exit 0
