# DockerCompact-AutoSetup.ps1
# Install / update / remove the DockerCompact scheduled task.
# Task mode (-RunTask): runs docker-compact.ps1 and records TXT + CSV logs.
#
# Examples (Administrator PowerShell):
#   .\DockerCompact-AutoSetup.ps1                                   # weekly, Sunday 03:00
#   .\DockerCompact-AutoSetup.ps1 -Schedule Daily -At 02:30
#   .\DockerCompact-AutoSetup.ps1 -Schedule Daily -Interval 3 -At 01:00
#   .\DockerCompact-AutoSetup.ps1 -Schedule Weekly -DaysOfWeek "Monday,Friday" -At 22:00
#   .\DockerCompact-AutoSetup.ps1 -Schedule Monthly -DayOfMonth Last -At 03:00
#   .\DockerCompact-AutoSetup.ps1 -Remove

[CmdletBinding()]
param(
    # ---- install mode ----
    [ValidateSet("Daily", "Weekly", "Monthly")]
    [string]$Schedule = "Weekly",

    # Every N days (Daily) or every N weeks (Weekly).
    [ValidateRange(1, 365)]
    [int]$Interval = 1,

    # Weekly: comma-separated English day names, e.g. "Monday,Friday".
    [Alias("DayOfWeek")]
    [string]$DaysOfWeek = "Sunday",

    # Monthly: 1-31 or "Last".
    [string]$DayOfMonth = "1",

    # Time of day, e.g. "03:00", "22:30" or "3:00AM".
    [string]$At = "03:00",

    [switch]$PruneBeforeCompact,

    [switch]$Remove,

    # ---- both modes ----
    [switch]$PruneAll,
    [string]$VhdxPath,

    # ---- task mode (set by the registered task) ----
    [switch]$RunTask,
    [switch]$Prune
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "DockerCompact-Common.ps1")

if ($VhdxPath) { $script:DcVhdxPath = $VhdxPath }


function ConvertTo-XmlText([string]$s) {
    return [Security.SecurityElement]::Escape($s)
}


# ============================================================
# REMOVE MODE
# ============================================================

if ($Remove) {
    if (-not (Test-IsAdministrator)) {
        throw "Open PowerShell as Administrator, then run this again."
    }

    if (Get-ScheduledTask -TaskName $script:DcTaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $script:DcTaskName -Confirm:$false
        Write-Host "Task '$script:DcTaskName' removed." -ForegroundColor Green
    }
    else {
        Write-Host "Task '$script:DcTaskName' does not exist."
    }

    exit 0
}


# ============================================================
# INSTALL / REGISTER MODE
# ============================================================

if (-not $RunTask) {
    if (-not (Test-IsAdministrator)) {
        throw "Open PowerShell as Administrator, then run this installer again."
    }

    if (-not (Test-Path -LiteralPath $script:DcEnginePath -PathType Leaf)) {
        throw "Cannot find compaction script: $script:DcEnginePath"
    }

    New-Item -ItemType Directory -Path $script:DcLogDir -Force | Out-Null

    # --- time ---
    $time = $null
    foreach ($fmt in @("HH:mm", "H:mm", "h:mmtt", "hh:mmtt", "h:mm tt", "hh:mm tt")) {
        try {
            $time = [datetime]::ParseExact($At.Trim(), $fmt, [Globalization.CultureInfo]::InvariantCulture)
            break
        }
        catch { }
    }
    if (-not $time) { throw "Invalid -At value '$At'. Use HH:mm, e.g. 03:00 or 22:30." }

    $startBoundary = (Get-Date).Date.AddHours($time.Hour).AddMinutes($time.Minute).ToString("yyyy-MM-dd'T'HH:mm:ss")

    # --- schedule element ---
    switch ($Schedule) {
        "Daily" {
            $scheduleXml = "<ScheduleByDay><DaysInterval>$Interval</DaysInterval></ScheduleByDay>"
            $summary = if ($Interval -eq 1) { "every day at $($time.ToString('HH:mm'))" } else { "every $Interval days at $($time.ToString('HH:mm'))" }
        }
        "Weekly" {
            $days = @($DaysOfWeek -split "[,;\s]+" | Where-Object { $_ } | ForEach-Object {
                $d = $_.Trim()
                $match = $script:DcWeekDays | Where-Object { $_ -ieq $d -or $_.Substring(0, 3) -ieq $d }
                if (-not $match) { throw "Invalid day '$d'. Use Sunday, Monday, ... Saturday." }
                $match
            } | Select-Object -Unique)
            if ($days.Count -eq 0) { throw "Weekly schedule needs at least one day in -DaysOfWeek." }

            $daysXml = ($days | ForEach-Object { "<$_ />" }) -join ""
            $scheduleXml = "<ScheduleByWeek><DaysOfWeek>$daysXml</DaysOfWeek><WeeksInterval>$Interval</WeeksInterval></ScheduleByWeek>"
            $every = if ($Interval -eq 1) { "every week" } else { "every $Interval weeks" }
            $summary = "$every on $($days -join ', ') at $($time.ToString('HH:mm'))"
        }
        "Monthly" {
            if ($DayOfMonth -ieq "Last") {
                $dom = "Last"
            }
            elseif ($DayOfMonth -match '^\d+$' -and [int]$DayOfMonth -ge 1 -and [int]$DayOfMonth -le 31) {
                $dom = [int]$DayOfMonth
            }
            else {
                throw "Invalid -DayOfMonth '$DayOfMonth'. Use 1-31 or Last."
            }

            $monthsXml = ([Globalization.CultureInfo]::InvariantCulture.DateTimeFormat.MonthNames |
                Where-Object { $_ } | ForEach-Object { "<$_ />" }) -join ""
            $scheduleXml = "<ScheduleByMonth><DaysOfMonth><Day>$dom</Day></DaysOfMonth><Months>$monthsXml</Months></ScheduleByMonth>"
            $summary = "monthly on day $dom at $($time.ToString('HH:mm'))"
        }
    }

    # --- action ---
    $actionArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -RunTask' -f $script:DcSetupPath
    if ($PruneBeforeCompact) { $actionArgs += " -Prune" }
    if ($PruneBeforeCompact -and $PruneAll) { $actionArgs += " -PruneAll" }
    if ($VhdxPath) { $actionArgs += (' -VhdxPath "{0}"' -f $VhdxPath) }

    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

    # Built as XML so every schedule type (including monthly) is available,
    # and so the task also runs on battery power.
    $taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Docker WSL disk (docker_data.vhdx) compaction with logging - $(ConvertTo-XmlText $summary)</Description>
    <URI>\$($script:DcTaskName)</URI>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>$startBoundary</StartBoundary>
      <Enabled>true</Enabled>
      $scheduleXml
    </CalendarTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$(ConvertTo-XmlText $currentUser)</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT3H</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$(ConvertTo-XmlText $psExe)</Command>
      <Arguments>$(ConvertTo-XmlText $actionArgs)</Arguments>
      <WorkingDirectory>$(ConvertTo-XmlText $script:DcRoot)</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    Register-ScheduledTask -TaskName $script:DcTaskName -Xml $taskXml -Force | Out-Null

    Write-Host ""
    Write-Host "Task '$script:DcTaskName' created/updated successfully." -ForegroundColor Green
    Write-Host "Schedule: $summary"
    Write-Host "Runs as: $currentUser"
    Write-Host "Task script: $script:DcSetupPath -RunTask"
    Write-Host "VHDX: $script:DcVhdxPath"
    Write-Host "TXT log: $script:DcTxtLog"
    Write-Host "CSV history: $script:DcCsvLog"
    Write-Host "Prune before compaction: $([bool]$PruneBeforeCompact)$(if ($PruneBeforeCompact -and $PruneAll) { ' (deep)' })"
    Write-Host ""

    exit 0
}


# ============================================================
# TASK / LOGGING MODE
# ============================================================

$run = Start-CompactRunLog -Source "Task" -Prune ([bool]$Prune)

$status = "Failed"
$exitCode = $null
$errorMessage = ""

$stamp = $run.Started.ToString("yyyyMMdd-HHmmss")
$stdoutPath = Join-Path $env:TEMP "docker-compact-$stamp-stdout.txt"
$stderrPath = Join-Path $env:TEMP "docker-compact-$stamp-stderr.txt"

try {
    if (-not (Test-Path -LiteralPath $script:DcEnginePath -PathType Leaf)) {
        throw "Cannot find compaction script: $script:DcEnginePath"
    }

    $compactArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $script:DcEnginePath
    if ($Prune) { $compactArgs += " -Prune" }
    if ($Prune -and $PruneAll) { $compactArgs += " -PruneAll" }
    if ($VhdxPath) { $compactArgs += (' -VhdxPath "{0}"' -f $VhdxPath) }

    $process = Start-Process -FilePath "powershell.exe" -ArgumentList $compactArgs `
        -PassThru -Wait -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath

    $exitCode = $process.ExitCode

    if (Test-Path -LiteralPath $stdoutPath) {
        Write-RunLog "--- SCRIPT STDOUT ---"
        Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue | Write-RunLog
    }

    if (Test-Path -LiteralPath $stderrPath) {
        $stderrText = Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue
        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
            Write-RunLog "--- SCRIPT STDERR ---"
            Write-RunLog $stderrText
        }
    }

    if ($exitCode -eq 0) {
        $status = "Success"
    }
    else {
        $errorMessage = "Compaction script exited with code $exitCode"
    }
}
catch {
    $errorMessage = $_.Exception.Message
    Write-RunLog "ERROR: $errorMessage"
}
finally {
    [void](Complete-CompactRunLog -Run $run -Status $status -ExitCode $exitCode -ErrorMessage $errorMessage)
    Remove-Item -LiteralPath $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
}

if ($status -ne "Success") { exit 1 }
exit 0
