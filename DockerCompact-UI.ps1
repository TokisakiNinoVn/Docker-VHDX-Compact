# DockerCompact-UI.ps1
# Windows Forms front-end for docker-compact.ps1.
# Shows every step live (pending / running / done / skipped / failed),
# overall + compaction progress, elapsed time, live output, before/after
# sizes; lets you pick the VHDX, switch English / Vietnamese, and set up
# the scheduled task (daily / weekly / monthly).
#
# Launch: DockerCompact.exe (installed), DockerCompact-UI.cmd, or
#   powershell -NoProfile -ExecutionPolicy Bypass -File DockerCompact-UI.ps1
#
# All user-visible text lives in DockerCompact-Lang.json (UTF-8).

[CmdletBinding()]
param(
    # Build the window, feed it sample progress and exit (smoke test).
    [switch]$SelfTest,
    # With -SelfTest: save a PNG of the window to this path.
    [string]$Screenshot,
    # With -SelfTest -Screenshot: capture the schedule dialog instead.
    [switch]$ShowSchedule,
    # Force a UI language for this session.
    [ValidateSet("en", "vi")]
    [string]$Lang
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "DockerCompact-Common.ps1")

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing


# ------------------------------------------------------------
# Settings + language
# ------------------------------------------------------------
$Strings = Read-DcStrings
$settings = Get-DcSettings
if ($settings.VhdxPath) { $script:DcVhdxPath = $settings.VhdxPath }

$app = @{
    Lang       = "en"
    Process    = $null
    OutTask    = $null
    ErrTask    = $null
    OutEof     = $false
    ErrEof     = $false
    Run        = $null
    Watch      = $null
    StepStart  = @{}
    Rows       = @{}
    Current    = $null
    Tick       = 0
    LastError  = ""
    CompactPct = 0
    Status     = $null
    Sub        = $null
    LastSnap   = $null
    LastBefore = $null
}

$LangCodes = @("en", "vi")
$app.Lang = if ($Lang) { $Lang }
            elseif ($settings.Language -in $LangCodes) { $settings.Language }
            elseif ((Get-UICulture).Name -like "vi*") { "vi" }
            else { "en" }

# T "key" [format args...]
function T([string]$Key) {
    $p = $Strings.($app.Lang).PSObject.Properties[$Key]
    if (-not $p) { $p = $Strings.en.PSObject.Properties[$Key] }
    $v = if ($p) { [string]$p.Value } else { $Key }
    if ($args.Count) { return ($v -f $args) }
    return $v
}


# ------------------------------------------------------------
# Elevation: DiskPart and wsl --shutdown need Administrator.
# ------------------------------------------------------------
if (-not (Test-IsAdministrator) -and -not $SelfTest) {
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList (
            '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}"' -f $PSCommandPath
        ) | Out-Null
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show(
            "$(T 'app.needAdmin')`n`n$($_.Exception.Message)",
            "Docker VHDX Compact", "OK", "Warning") | Out-Null
    }
    exit
}

if (-not ("DockerCompact.Dpi" -as [type])) {
    Add-Type -Namespace DockerCompact -Name Dpi -MemberDefinition @"
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
"@
}
[void][DockerCompact.Dpi]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()


# ------------------------------------------------------------
# Look & feel
# ------------------------------------------------------------
$C = @{
    Accent   = [Drawing.Color]::FromArgb(29, 99, 237)
    Bg       = [Drawing.Color]::FromArgb(245, 247, 250)
    Card     = [Drawing.Color]::White
    Text     = [Drawing.Color]::FromArgb(32, 33, 36)
    Muted    = [Drawing.Color]::FromArgb(110, 115, 125)
    HeadSub  = [Drawing.Color]::FromArgb(220, 230, 255)
    HeadBad  = [Drawing.Color]::FromArgb(255, 205, 195)
    Running  = [Drawing.Color]::FromArgb(0, 103, 192)
    RunBg    = [Drawing.Color]::FromArgb(229, 241, 255)
    Done     = [Drawing.Color]::FromArgb(16, 124, 16)
    Skipped  = [Drawing.Color]::FromArgb(140, 140, 140)
    Warn     = [Drawing.Color]::FromArgb(202, 80, 16)
    Failed   = [Drawing.Color]::FromArgb(196, 43, 28)
    FailBg   = [Drawing.Color]::FromArgb(253, 231, 233)
    LogBg    = [Drawing.Color]::FromArgb(30, 30, 30)
    LogText  = [Drawing.Color]::FromArgb(212, 212, 212)
    LogDim   = [Drawing.Color]::FromArgb(150, 150, 150)
    LogRed   = [Drawing.Color]::FromArgb(244, 135, 113)
    LogGreen = [Drawing.Color]::FromArgb(106, 200, 120)
    LogBlue  = [Drawing.Color]::FromArgb(110, 180, 255)
    LogAmber = [Drawing.Color]::FromArgb(220, 180, 90)
}

$Glyph = @{
    pending = [string][char]0x25CB   # circle
    done    = [string][char]0x2714   # check
    skipped = [string][char]0x2013   # dash
    warn    = [string][char]0x26A0   # warning sign
    failed  = [string][char]0x2716   # cross
    notrun  = [string][char]0x25CB
}
$Spinner = @([char]0x25D0, [char]0x25D3, [char]0x25D1, [char]0x25D2) | ForEach-Object { [string]$_ }

$fontUi    = New-Object Drawing.Font("Segoe UI", 9.5)
$fontBold  = New-Object Drawing.Font("Segoe UI Semibold", 9.5)
$fontTitle = New-Object Drawing.Font("Segoe UI Semibold", 16)
$fontSub   = New-Object Drawing.Font("Segoe UI", 9)
$fontStat  = New-Object Drawing.Font("Segoe UI Semibold", 15)
$fontCap   = New-Object Drawing.Font("Segoe UI Semibold", 8)
$fontMono  = New-Object Drawing.Font("Consolas", 9.5)

$appIcon = $null
if ($script:DcIconPath) {
    try { $appIcon = New-Object Drawing.Icon($script:DcIconPath) } catch { }
}


# ------------------------------------------------------------
# Form + layout
# ------------------------------------------------------------
$form = New-Object Windows.Forms.Form
$form.SuspendLayout()
$form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
$form.AutoScaleMode = "Dpi"
$form.Text = "Docker VHDX Compact"
$form.Size = New-Object Drawing.Size(1100, 770)
$form.MinimumSize = New-Object Drawing.Size(940, 640)
$form.StartPosition = "CenterScreen"
$form.BackColor = $C.Bg
$form.Font = $fontUi
$form.ForeColor = $C.Text
if ($appIcon) { $form.Icon = $appIcon }

$root = New-Object Windows.Forms.TableLayoutPanel
$root.Dock = "Fill"
$root.ColumnCount = 1
$root.RowCount = 5
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 78)))   # header
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 96)))   # stats
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 70)))   # progress
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle("Percent", 100)))   # steps + log
[void]$root.RowStyles.Add((New-Object Windows.Forms.RowStyle("Absolute", 104)))  # footer
$form.Controls.Add($root)

# --- Header -------------------------------------------------
$header = New-Object Windows.Forms.Panel
$header.Dock = "Fill"
$header.BackColor = $C.Accent
$header.Margin = New-Object Windows.Forms.Padding(0)

$picIcon = New-Object Windows.Forms.PictureBox
$picIcon.Location = New-Object Drawing.Point(16, 13)
$picIcon.Size = New-Object Drawing.Size(52, 52)
$picIcon.SizeMode = "Zoom"
$picIcon.BackColor = [Drawing.Color]::Transparent
if ($script:DcIconPath) {
    try { $picIcon.Image = (New-Object Drawing.Icon($script:DcIconPath, 128, 128)).ToBitmap() } catch { }
}
$header.Controls.Add($picIcon)

$lblTitle = New-Object Windows.Forms.Label
$lblTitle.Text = "Docker VHDX Compact"
$lblTitle.Font = $fontTitle
$lblTitle.ForeColor = [Drawing.Color]::White
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object Drawing.Point(76, 9)
$header.Controls.Add($lblTitle)

$lblSub = New-Object Windows.Forms.Label
$lblSub.Font = $fontSub
$lblSub.ForeColor = $C.HeadSub
$lblSub.AutoSize = $true
$lblSub.Location = New-Object Drawing.Point(78, 46)
$header.Controls.Add($lblSub)

function New-HeaderLink {
    $l = New-Object Windows.Forms.LinkLabel
    $l.Font = New-Object Drawing.Font("Segoe UI Semibold", 9)
    $l.AutoSize = $true
    $l.LinkColor = [Drawing.Color]::White
    $l.ActiveLinkColor = $C.HeadSub
    $l.VisitedLinkColor = [Drawing.Color]::White
    $l.LinkBehavior = "HoverUnderline"
    $l.Location = New-Object Drawing.Point(400, 46)
    $header.Controls.Add($l)
    return $l
}
$lnkChange = New-HeaderLink
$lnkDefault = New-HeaderLink

$langPanel = New-Object Windows.Forms.FlowLayoutPanel
$langPanel.Dock = "Right"
$langPanel.Width = 250
$langPanel.FlowDirection = "LeftToRight"
$langPanel.WrapContents = $false
$langPanel.Padding = New-Object Windows.Forms.Padding(0, 25, 0, 0)
$langPanel.BackColor = [Drawing.Color]::Transparent

$lblLang = New-Object Windows.Forms.Label
$lblLang.AutoSize = $true
$lblLang.ForeColor = $C.HeadSub
$lblLang.Font = $fontSub
$lblLang.Margin = New-Object Windows.Forms.Padding(0, 5, 6, 0)
$langPanel.Controls.Add($lblLang)

$cmbLang = New-Object Windows.Forms.ComboBox
$cmbLang.DropDownStyle = "DropDownList"
$cmbLang.Width = 130
foreach ($code in $LangCodes) { [void]$cmbLang.Items.Add([string]$Strings.$code.'lang.name') }
$cmbLang.SelectedIndex = [array]::IndexOf($LangCodes, $app.Lang)
$langPanel.Controls.Add($cmbLang)
$header.Controls.Add($langPanel)
$root.Controls.Add($header, 0, 0)

# --- Stat cards ---------------------------------------------
$stats = New-Object Windows.Forms.TableLayoutPanel
$stats.Dock = "Fill"
$stats.ColumnCount = 4
$stats.RowCount = 1
$stats.Padding = New-Object Windows.Forms.Padding(12, 10, 12, 4)
for ($i = 0; $i -lt 4; $i++) {
    [void]$stats.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle("Percent", 25)))
}

function New-StatCard {
    param([int]$Column)

    $card = New-Object Windows.Forms.Panel
    $card.Dock = "Fill"
    $card.BackColor = $C.Card
    $card.Margin = New-Object Windows.Forms.Padding(6, 0, 6, 0)

    $t = New-Object Windows.Forms.Label
    $t.Font = $fontCap
    $t.ForeColor = $C.Muted
    $t.AutoSize = $true
    $t.Location = New-Object Drawing.Point(12, 8)
    $card.Controls.Add($t)

    $v = New-Object Windows.Forms.Label
    $v.Text = "-"
    $v.Font = $fontStat
    $v.AutoSize = $true
    $v.Location = New-Object Drawing.Point(10, 26)
    $card.Controls.Add($v)

    $d = New-Object Windows.Forms.Label
    $d.Font = $fontSub
    $d.ForeColor = $C.Muted
    $d.AutoSize = $true
    $d.Location = New-Object Drawing.Point(12, 56)
    $card.Controls.Add($d)

    $stats.Controls.Add($card, $Column, 0)
    return @{ Title = $t; Value = $v; Detail = $d }
}

$cardSize   = New-StatCard 0
$cardOnDisk = New-StatCard 1
$cardFree   = New-StatCard 2
$cardResult = New-StatCard 3
$root.Controls.Add($stats, 0, 1)

# --- Progress -----------------------------------------------
$prog = New-Object Windows.Forms.Panel
$prog.Dock = "Fill"
$prog.Padding = New-Object Windows.Forms.Padding(18, 6, 18, 0)

$lblStatus = New-Object Windows.Forms.Label
$lblStatus.Font = $fontBold
$lblStatus.AutoSize = $false
$lblStatus.AutoEllipsis = $true
$lblStatus.Dock = "Top"
$lblStatus.Height = 24
$prog.Controls.Add($lblStatus)

$barOverall = New-Object Windows.Forms.ProgressBar
$barOverall.Dock = "Top"
$barOverall.Height = 14
$barOverall.Maximum = $script:DcSteps.Count * 100
$prog.Controls.Add($barOverall)
$barOverall.BringToFront()

$lblElapsed = New-Object Windows.Forms.Label
$lblElapsed.ForeColor = $C.Muted
$lblElapsed.Font = $fontSub
$lblElapsed.Dock = "Top"
$lblElapsed.Height = 22
$lblElapsed.TextAlign = "MiddleLeft"
$prog.Controls.Add($lblElapsed)
$lblElapsed.BringToFront()
$root.Controls.Add($prog, 0, 2)

# --- Steps + log --------------------------------------------
$split = New-Object Windows.Forms.SplitContainer
$split.Dock = "Fill"
$split.Margin = New-Object Windows.Forms.Padding(18, 4, 18, 4)
$split.SplitterWidth = 8
$split.BackColor = $C.Bg

$lv = New-Object Windows.Forms.ListView
$lv.Dock = "Fill"
$lv.View = "Details"
$lv.FullRowSelect = $true
$lv.HeaderStyle = "Nonclickable"
$lv.MultiSelect = $false
$lv.HideSelection = $true
$lv.BorderStyle = "FixedSingle"
$lv.Font = $fontUi
$lv.ShowItemToolTips = $true
[void]$lv.Columns.Add("", 34)
[void]$lv.Columns.Add("", 262)
[void]$lv.Columns.Add("", 90)
[void]$lv.Columns.Add("", 70)
[void]$lv.Columns.Add("", 200)
$il = New-Object Windows.Forms.ImageList     # taller rows
$il.ImageSize = New-Object Drawing.Size(1, 28)
$lv.SmallImageList = $il
$split.Panel1.Controls.Add($lv)

$log = New-Object Windows.Forms.RichTextBox
$log.Dock = "Fill"
$log.ReadOnly = $true
$log.BackColor = $C.LogBg
$log.ForeColor = $C.LogText
$log.Font = $fontMono
$log.BorderStyle = "None"
$log.WordWrap = $false
$log.DetectUrls = $false
$split.Panel2.Controls.Add($log)
$root.Controls.Add($split, 0, 3)

# --- Footer -------------------------------------------------
$footer = New-Object Windows.Forms.Panel
$footer.Dock = "Fill"
$footer.Padding = New-Object Windows.Forms.Padding(18, 4, 18, 10)

$chkPrune = New-Object Windows.Forms.CheckBox
$chkPrune.AutoSize = $true
$chkPrune.Location = New-Object Drawing.Point(20, 6)
$footer.Controls.Add($chkPrune)

$chkPruneAll = New-Object Windows.Forms.CheckBox
$chkPruneAll.AutoSize = $true
$chkPruneAll.Location = New-Object Drawing.Point(40, 28)
$chkPruneAll.Enabled = $false
$footer.Controls.Add($chkPruneAll)
$chkPrune.add_CheckedChanged({
    $chkPruneAll.Enabled = $chkPrune.Checked -and $chkPrune.Enabled
    if (-not $chkPrune.Checked) { $chkPruneAll.Checked = $false }
})

$chkKeep = New-Object Windows.Forms.CheckBox
$chkKeep.AutoSize = $true
$chkKeep.Location = New-Object Drawing.Point(20, 50)
$footer.Controls.Add($chkKeep)

$lblTask = New-Object Windows.Forms.Label
$lblTask.AutoSize = $true
$lblTask.ForeColor = $C.Muted
$lblTask.Font = $fontSub
$lblTask.Location = New-Object Drawing.Point(20, 78)
$footer.Controls.Add($lblTask)

$btnFlow = New-Object Windows.Forms.FlowLayoutPanel
$btnFlow.FlowDirection = "RightToLeft"
$btnFlow.Dock = "Right"
$btnFlow.Width = 548
$btnFlow.WrapContents = $false
$btnFlow.Padding = New-Object Windows.Forms.Padding(0, 14, 0, 0)
$footer.Controls.Add($btnFlow)

function New-Button {
    param([bool]$Primary = $false, [int]$Width = 120, $Parent = $btnFlow)

    $b = New-Object Windows.Forms.Button
    $b.Width = $Width
    $b.Height = 36
    $b.FlatStyle = "Flat"
    $b.Margin = New-Object Windows.Forms.Padding(8, 0, 0, 0)
    $b.Cursor = [Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $b.BackColor = $C.Accent
        $b.ForeColor = [Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
        $b.Font = $fontBold
    }
    else {
        $b.BackColor = $C.Card
        $b.FlatAppearance.BorderColor = [Drawing.Color]::FromArgb(200, 204, 212)
    }
    if ($Parent) { $Parent.Controls.Add($b) }
    return $b
}

$btnStart    = New-Button $true 160
$btnClose    = New-Button $false 90
$btnLogs     = New-Button $false 130
$btnSchedule = New-Button $false 130
$root.Controls.Add($footer, 0, 4)

$form.ResumeLayout($true)


# ------------------------------------------------------------
# Formatting helpers
# ------------------------------------------------------------
function Format-Gib($v) {
    if ($null -eq $v) { return (T 'card.na') }
    return ("{0:N2} GB" -f [double]$v)
}

function Format-Delta($v) {
    if ($null -eq $v) { return "" }
    $sign = if ($v -gt 0) { "+" } else { "" }
    return (T 'card.delta' ("{0}{1:N2}" -f $sign, [double]$v))
}

function Format-Span([TimeSpan]$t) {
    if ($t.TotalHours -ge 1) { return $t.ToString("h\:mm\:ss") }
    return $t.ToString("mm\:ss")
}

function Get-VhdxDrive {
    if ($script:DcVhdxPath.Length -ge 2 -and $script:DcVhdxPath[1] -eq ':') { return $script:DcVhdxPath.Substring(0, 2) }
    return "C:"
}

# Monday-first short day names for a list of English day names.
function Format-Days($days) {
    $short = $Strings.($app.Lang).'days.short'
    $names = foreach ($i in 1, 2, 3, 4, 5, 6, 0) {
        if ($script:DcWeekDays[$i] -in $days) { $short[$i] }
    }
    return ($names -join ", ")
}

function Format-Schedule($s) {
    $t = $s.Time
    $desc = switch ($s.Frequency) {
        "Daily" {
            if ($s.Interval -le 1) { T 'sched.daily' $t } else { T 'sched.everyNDays' $s.Interval $t }
        }
        "Weekly" {
            $d = Format-Days $s.Days
            if ($s.Interval -le 1) { T 'sched.weekly' $d $t } else { T 'sched.everyNWeeks' $s.Interval $d $t }
        }
        "Monthly" {
            if ("$($s.DayOfMonth)" -ieq "Last") { T 'sched.monthlyLast' $t } else { T 'sched.monthly' $s.DayOfMonth $t }
        }
        default { T 'sched.custom' }
    }
    if ($s.Prune -and $s.PruneAll) { $desc += (T 'sched.withDeepPrune') }
    elseif ($s.Prune) { $desc += (T 'sched.withPrune') }
    return $desc
}

function Format-TaskResult($code) {
    if ($null -eq $code) { return (T 'card.na') }
    $u = [uint32]([int64]$code -band 0xFFFFFFFF)
    switch ($u) {
        0          { return (T 'result.ok') }
        0x41303    { return (T 'result.notYet') }
        0x41301    { return (T 'result.running') }
        0x41306    { return ("{0} (0x{1:X})" -f (T 'result.terminated'), $u) }
        0xC000013A { return ("{0} (0x{1:X})" -f (T 'result.terminated'), $u) }
        default    { return ("0x{0:X}" -f $u) }
    }
}

function Add-Log {
    param([string]$Text, $Color = $null)

    $log.SelectionStart = $log.TextLength
    $log.SelectionLength = 0
    $log.SelectionColor = if ($Color) { $Color } else { $C.LogText }
    $log.AppendText($Text + "`r`n")
    $log.SelectionColor = $log.ForeColor
    $log.ScrollToCaret()
}

# Status line and the line under the progress bar remember their string
# key so they can be re-rendered when the language changes.
function Set-Status {
    param([string]$Key, [object[]]$FArgs = @(), $Color = $null, [string]$Glyph = "")
    $app.Status = @{ Key = $Key; FArgs = $FArgs; Color = $Color; Glyph = $Glyph }
    Show-Status
}

function Show-Status {
    $s = $app.Status
    if (-not $s) { return }
    $fa = @($s.FArgs)
    $text = T $s.Key @fa
    if ($s.Glyph) { $text = "$($s.Glyph) $text" }
    $lblStatus.Text = $text
    $lblStatus.ForeColor = if ($s.Color) { $s.Color } else { $C.Text }
}

function Set-Sub {
    param([string]$Key, [object[]]$FArgs = @())
    $app.Sub = if ($Key) { @{ Key = $Key; FArgs = $FArgs } } else { $null }
    Show-Sub
}

function Show-Sub {
    $s = $app.Sub
    if (-not $s) { $lblElapsed.Text = ""; return }
    $fa = @($s.FArgs)
    $lblElapsed.Text = T $s.Key @fa
}


# ------------------------------------------------------------
# Cards, path, task info
# ------------------------------------------------------------
function Update-Stats {
    param($Snapshot, $Before = $null)

    $app.LastSnap = $Snapshot
    $app.LastBefore = $Before
    if (-not $Snapshot) { return }

    $cardSize.Value.Text = Format-Gib $Snapshot.VhdxFileSizeGiB
    $cardOnDisk.Value.Text = Format-Gib $Snapshot.VhdxOnDiskGiB
    $cardFree.Value.Text = Format-Gib $Snapshot.CFreeGiB

    if ($Before) {
        $cardSize.Detail.Text = Format-Delta (Get-Delta $Before.VhdxFileSizeGiB $Snapshot.VhdxFileSizeGiB)
        $cardOnDisk.Detail.Text = Format-Delta (Get-Delta $Before.VhdxOnDiskGiB $Snapshot.VhdxOnDiskGiB)
        $cardFree.Detail.Text = Format-Delta (Get-Delta $Before.CFreeGiB $Snapshot.CFreeGiB)
    }
    else {
        $cardSize.Detail.Text = if ($Snapshot.VhdxLastWriteTime) { T 'card.modified' $Snapshot.VhdxLastWriteTime } else { "" }
        $cardOnDisk.Detail.Text = T 'card.ondiskHint'
        $cardFree.Detail.Text = ""
    }
}

function Update-LastResult {
    $cardResult.Value.Text = "-"
    $cardResult.Value.ForeColor = $C.Text
    $cardResult.Detail.Text = T 'card.noRuns'

    if (-not (Test-Path -LiteralPath $script:DcCsvLog)) { return }

    try {
        $last = Import-Csv -LiteralPath $script:DcCsvLog | Select-Object -Last 1
        if (-not $last) { return }

        $ok = $last.Status -eq "Success"
        $cardResult.Value.Text = if ($ok) { T 'result.success' } else { T 'result.failed' }
        $cardResult.Value.ForeColor = if ($ok) { $C.Done } else { $C.Failed }
        $src = if ($last.Source) { " ($($last.Source))" } else { "" }
        $cardResult.Detail.Text = "$($last.StartTime)$src"
    }
    catch { }
}

function Update-TaskInfo {
    $s = Get-DcSchedule
    if (-not $s) {
        $lblTask.Text = T 'task.none'
        return
    }

    $desc = Format-Schedule $s
    if ($s.State -eq "Disabled") { $desc += (T 'task.disabled') }
    $next = if ($s.NextRun) { $s.NextRun.ToString("yyyy-MM-dd HH:mm") } else { T 'card.na' }
    $lblTask.Text = T 'task.info' $desc $next (Format-TaskResult $s.LastResult)
}

function Update-PathLabel {
    $lblSub.Text = $script:DcVhdxPath
    $exists = Test-Path -LiteralPath $script:DcVhdxPath -PathType Leaf
    $lblSub.ForeColor = if ($exists) { $C.HeadSub } else { $C.HeadBad }

    $lnkChange.Left = $lblSub.Left + $lblSub.PreferredWidth + 12
    $lnkDefault.Left = $lnkChange.Left + $lnkChange.PreferredWidth + 10
    $lnkDefault.Visible = ($script:DcVhdxPath -ne $script:DcVhdxDefault)

    if (-not $app.Process) { $btnStart.Enabled = $exists }
    $cardFree.Title.Text = (T 'card.free' (Get-VhdxDrive)).ToUpper()
}

function Set-VhdxPath([string]$Path) {
    $script:DcVhdxPath = $Path
    $settings.VhdxPath = if ($Path -eq $script:DcVhdxDefault) { $null } else { $Path }
    Save-DcSettings $settings

    Update-PathLabel
    Update-Stats (Get-DiskSnapshot)
    Add-Log (T 'path.changed' $Path) $C.LogBlue

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Add-Log (T 'path.notFound' $Path) $C.LogRed
    }

    $sch = Get-DcSchedule
    if ($sch) {
        $taskPath = if ($sch.VhdxPath) { $sch.VhdxPath } else { $script:DcVhdxDefault }
        if ($taskPath -ne $Path) { Add-Log (T 'path.taskDiffers' $taskPath) $C.LogAmber }
    }
}


# ------------------------------------------------------------
# Step list
# ------------------------------------------------------------
function Get-StepTitle([string]$Id) {
    $p = $Strings.($app.Lang).PSObject.Properties["step.$Id"]
    if ($p) { return [string]$p.Value }
    return $Id
}

function Set-RowState {
    param([string]$Id, [string]$State, [string]$Message)

    $item = $app.Rows[$Id]
    if (-not $item) {
        # Unknown step from a newer engine: append it.
        $item = New-Object Windows.Forms.ListViewItem("")
        [void]$item.SubItems.Add($Id)
        [void]$item.SubItems.Add("")
        [void]$item.SubItems.Add("")
        [void]$item.SubItems.Add("")
        [void]$lv.Items.Add($item)
        $app.Rows[$Id] = $item
    }

    $item.Tag = $State
    $item.Text = if ($State -eq "running") { $Spinner[0] } else { $Glyph[$State] }
    $item.SubItems[2].Text = T "state.$State"
    if ($PSBoundParameters.ContainsKey("Message")) {
        $item.SubItems[4].Text = $Message
        $item.ToolTipText = $Message
    }

    $item.BackColor = $C.Card
    $item.ForeColor = $C.Text
    $item.Font = $fontUi

    switch ($State) {
        "pending" { $item.ForeColor = $C.Muted }
        "notrun"  { $item.ForeColor = $C.Skipped }
        "running" {
            $item.ForeColor = $C.Running; $item.BackColor = $C.RunBg; $item.Font = $fontBold
            if (-not $app.StepStart.ContainsKey($Id)) { $app.StepStart[$Id] = Get-Date }
            $app.Current = $Id
            $item.EnsureVisible()
        }
        "done"    { $item.ForeColor = $C.Done }
        "skipped" { $item.ForeColor = $C.Skipped }
        "warn"    { $item.ForeColor = $C.Warn }
        "failed"  { $item.ForeColor = $C.Failed; $item.BackColor = $C.FailBg; $item.Font = $fontBold }
    }

    if ($State -ne "running" -and $app.Current -eq $Id) { $app.Current = $null }

    if ($State -in @("done", "skipped", "warn", "failed") -and $app.StepStart.ContainsKey($Id)) {
        $item.SubItems[3].Text = Format-Span ((Get-Date) - $app.StepStart[$Id])
    }

    Update-OverallBar
}

function Update-OverallBar {
    $finished = 0
    $partial = 0
    foreach ($s in $script:DcSteps) {
        $it = $app.Rows[$s.Id]
        if (-not $it) { continue }
        if ($it.Tag -in @("done", "skipped", "warn", "failed", "notrun")) { $finished += 100 }
        elseif ($it.Tag -eq "running" -and $s.Id -eq "compact" -and $app.CompactPct) { $partial = [int]$app.CompactPct }
    }
    $barOverall.Value = [math]::Min($barOverall.Maximum, $finished + $partial)
}

function Reset-Steps {
    $lv.BeginUpdate()
    $lv.Items.Clear()
    $app.Rows = @{}
    $app.StepStart = @{}
    $app.Current = $null
    $app.CompactPct = 0
    foreach ($s in $script:DcSteps) {
        $item = New-Object Windows.Forms.ListViewItem($Glyph.pending)
        [void]$item.SubItems.Add("")
        [void]$item.SubItems.Add("")
        [void]$item.SubItems.Add("")
        [void]$item.SubItems.Add("")
        $item.ForeColor = $C.Muted
        $item.Tag = "pending"
        [void]$lv.Items.Add($item)
        $app.Rows[$s.Id] = $item
    }
    $lv.EndUpdate()
    Update-StepTexts
    $barOverall.Value = 0
}

function Update-StepTexts {
    $n = 1
    foreach ($s in $script:DcSteps) {
        $it = $app.Rows[$s.Id]
        if ($it) {
            $it.SubItems[1].Text = "$n. $(Get-StepTitle $s.Id)"
            $it.SubItems[2].Text = T "state.$($it.Tag)"
            if ($s.Id -eq "compact" -and $it.Tag -eq "running" -and $app.CompactPct) {
                $it.SubItems[4].Text = T 'run.pct' $app.CompactPct
            }
        }
        $n++
    }
}


# ------------------------------------------------------------
# Language
# ------------------------------------------------------------
function Set-UiTexts {
    $form.SuspendLayout()

    $lblLang.Text = T 'lang.label'
    $lnkChange.Text = T 'path.change'
    $lnkDefault.Text = T 'path.default'

    $cardSize.Title.Text = (T 'card.size').ToUpper()
    $cardOnDisk.Title.Text = (T 'card.ondisk').ToUpper()
    $cardResult.Title.Text = (T 'card.result').ToUpper()

    $lv.Columns[1].Text = T 'col.step'
    $lv.Columns[2].Text = T 'col.status'
    $lv.Columns[3].Text = T 'col.time'
    $lv.Columns[4].Text = T 'col.details'

    $chkPrune.Text = T 'chk.prune'
    $chkPruneAll.Text = T 'chk.pruneAll'
    $chkKeep.Text = T 'chk.keep'

    $btnStart.Text = T 'btn.start'
    $btnClose.Text = T 'btn.close'
    $btnLogs.Text = T 'btn.logs'
    $btnSchedule.Text = T 'btn.schedule'

    Update-StepTexts
    Update-Stats $app.LastSnap $app.LastBefore
    Update-LastResult
    Update-TaskInfo
    Update-PathLabel
    Show-Status
    Show-Sub

    $form.ResumeLayout($true)
}

$cmbLang.add_SelectedIndexChanged({
    $code = $LangCodes[$cmbLang.SelectedIndex]
    if ($code -eq $app.Lang) { return }
    $app.Lang = $code
    $settings.Language = $code
    Save-DcSettings $settings
    Set-UiTexts
})


# ------------------------------------------------------------
# Engine output
# ------------------------------------------------------------
function Set-Busy([bool]$Busy) {
    $btnStart.Enabled = (-not $Busy) -and (Test-Path -LiteralPath $script:DcVhdxPath -PathType Leaf)
    $btnSchedule.Enabled = -not $Busy
    $chkPrune.Enabled = -not $Busy
    $chkKeep.Enabled = -not $Busy
    $chkPruneAll.Enabled = (-not $Busy) -and $chkPrune.Checked
    $btnClose.Enabled = -not $Busy
    $lnkChange.Enabled = -not $Busy
    $lnkDefault.Enabled = -not $Busy
    $btnStart.BackColor = if ($Busy) { [Drawing.Color]::FromArgb(150, 170, 210) } else { $C.Accent }
}

function Invoke-EngineLine {
    param([string]$Line, [bool]$IsError = $false)

    if ($Line -match '^##STEP\|([^|]+)\|([^|]+)\|(.*)$') {
        $id = $Matches[1]; $st = $Matches[2]; $msg = $Matches[3]
        Set-RowState -Id $id -State $st -Message $msg

        $idx = [array]::IndexOf(@($script:DcSteps.Id), $id) + 1
        if ($st -eq "running") {
            $title = Get-StepTitle $id
            # Engine messages are English; show them only in the English UI.
            if ($msg -and $app.Lang -eq "en") { $title += " - $msg" }
            Set-Status 'run.step' @($idx, $script:DcSteps.Count, $title) $C.Running
        }
        if ($st -eq "failed") { $app.LastError = $msg }
        return
    }

    if ($Line -match '^##PCT\|([^|]+)\|(\d+)') {
        $pct = [math]::Min(100, [int]$Matches[2])
        if ($Matches[1] -eq "compact") { $app.CompactPct = $pct }
        $item = $app.Rows[$Matches[1]]
        if ($item) { $item.SubItems[4].Text = T 'run.pct' $pct }
        Update-OverallBar
        return
    }

    Write-RunLog $Line

    $color = $null
    if ($IsError -or $Line -match '^ERROR:|FAILED') { $color = $C.LogRed }
    elseif ($Line -match '^\[\d+/\d+\]\s+DONE') { $color = $C.LogGreen }
    elseif ($Line -match '^\[\d+/\d+\]\s+RUNNING') { $color = $C.LogBlue }
    elseif ($Line -match '^\[\d+/\d+\]\s+(WARN|SKIPPED)|^HINT:') { $color = $C.LogAmber }
    elseif ($Line -match '^\s{4}') { $color = $C.LogDim }
    Add-Log $Line $color
}


# ------------------------------------------------------------
# Run the engine as a child process and poll its output on the UI
# thread (no cross-thread calls, the window stays responsive).
# ------------------------------------------------------------
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 120

function Start-Compaction {
    $confirm = [Windows.Forms.MessageBox]::Show(
        (T 'run.confirm'), "Docker VHDX Compact", "YesNo", "Warning")
    if ($confirm -ne "Yes") { return }

    Reset-Steps
    $log.Clear()
    Set-Busy $true
    $app.LastError = ""
    $app.OutEof = $false
    $app.ErrEof = $false

    $prune = [bool]$chkPrune.Checked
    $app.Run = Start-CompactRunLog -Source "UI" -Prune $prune
    Update-Stats $app.Run.Before

    $engineArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProgressMarkers -VhdxPath "{1}"' -f `
        $script:DcEnginePath, $script:DcVhdxPath
    if ($prune) { $engineArgs += " -Prune" }
    if ($prune -and $chkPruneAll.Checked) { $engineArgs += " -PruneAll" }
    if ($chkKeep.Checked) { $engineArgs += " -KeepDockerStopped" }

    Add-Log "> powershell.exe $engineArgs" $C.LogDim
    Write-RunLog "--- SCRIPT OUTPUT ---"

    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = $engineArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    $psi.WorkingDirectory = $script:DcRoot

    try {
        $app.Process = [Diagnostics.Process]::Start($psi)
    }
    catch {
        Add-Log (T 'run.startFailed' $_.Exception.Message) $C.LogRed
        Complete-Run -ExitCode $null -ErrorMessage $_.Exception.Message
        return
    }

    $app.OutTask = $app.Process.StandardOutput.ReadLineAsync()
    $app.ErrTask = $app.Process.StandardError.ReadLineAsync()
    $app.Watch = [Diagnostics.Stopwatch]::StartNew()
    Set-Status 'run.starting' @() $C.Running
    $timer.Start()
}

function Read-EngineOutput {
    $guard = 0
    while (-not $app.OutEof -and $app.OutTask.IsCompleted -and $guard -lt 200) {
        $line = $app.OutTask.Result
        if ($null -eq $line) { $app.OutEof = $true; break }
        Invoke-EngineLine $line
        $app.OutTask = $app.Process.StandardOutput.ReadLineAsync()
        $guard++
    }
    $guard = 0
    while (-not $app.ErrEof -and $app.ErrTask.IsCompleted -and $guard -lt 200) {
        $line = $app.ErrTask.Result
        if ($null -eq $line) { $app.ErrEof = $true; break }
        if (-not [string]::IsNullOrWhiteSpace($line)) { Invoke-EngineLine $line $true }
        $app.ErrTask = $app.Process.StandardError.ReadLineAsync()
        $guard++
    }
}

function Complete-Run {
    param($ExitCode, [string]$ErrorMessage = "")

    $timer.Stop()
    if ($app.Watch) { $app.Watch.Stop() }

    foreach ($s in $script:DcSteps) {
        $it = $app.Rows[$s.Id]
        if ($it -and $it.Tag -in @("pending", "running")) {
            $newState = if ($it.Tag -eq "running") { "failed" } else { "notrun" }
            Set-RowState -Id $s.Id -State $newState
        }
    }

    $ok = ($ExitCode -eq 0)
    $status = if ($ok) { "Success" } else { "Failed" }
    if (-not $ok -and -not $ErrorMessage) {
        $ErrorMessage = if ($app.LastError) { $app.LastError } else { T 'run.exitCode' $ExitCode }
    }

    $result = $null
    try {
        $result = Complete-CompactRunLog -Run $app.Run -Status $status -ExitCode $ExitCode -ErrorMessage $ErrorMessage
    }
    catch {
        Add-Log "History log: $($_.Exception.Message)" $C.LogAmber
    }

    $elapsed = if ($app.Watch) { Format-Span $app.Watch.Elapsed } else { "" }
    if ($result) { Update-Stats $result.After $result.Before }

    if ($ok) {
        $barOverall.Value = $barOverall.Maximum
        $gain = if ($result) { Get-Delta $result.After.VhdxOnDiskGiB $result.Before.VhdxOnDiskGiB } else { $null }
        if ($null -ne $gain -and $gain -lt 0.5) {
            Set-Status 'run.little' @($elapsed, ("{0:N2}" -f $gain)) $C.Warn $Glyph.warn
        }
        else {
            $suffix = if ($null -ne $gain) { T 'run.reclaimed' ("{0:N2}" -f $gain) } else { "" }
            Set-Status 'run.ok' @($elapsed) $C.Done $Glyph.done
            $lblStatus.Text += $suffix
        }
    }
    else {
        Set-Status 'run.failed' @($elapsed, $ErrorMessage) $C.Failed $Glyph.failed
    }

    Set-Sub 'run.logged' @($script:DcTxtLog)
    Update-LastResult
    Set-Busy $false

    if ($app.Process) { $app.Process.Dispose(); $app.Process = $null }
    [Media.SystemSounds]::Asterisk.Play()
}

$timer.add_Tick({
    try {
        if (-not $app.Process) { $timer.Stop(); return }

        Read-EngineOutput

        $app.Tick++
        if ($app.Current -and ($app.Tick % 3 -eq 0)) {
            $it = $app.Rows[$app.Current]
            if ($it) {
                $it.Text = $Spinner[[int]($app.Tick / 3) % $Spinner.Count]
                if ($app.StepStart.ContainsKey($app.Current)) {
                    $it.SubItems[3].Text = Format-Span ((Get-Date) - $app.StepStart[$app.Current])
                }
            }
        }
        if ($app.Watch) { Set-Sub 'run.elapsed' @(Format-Span $app.Watch.Elapsed) }

        if ($app.OutEof -and $app.ErrEof -and $app.Process.HasExited) {
            $app.Process.WaitForExit()
            Complete-Run -ExitCode $app.Process.ExitCode
        }
    }
    catch {
        $timer.Stop()
        Add-Log "UI error: $($_.Exception.Message)" $C.LogRed
        Set-Busy $false
    }
})


# ------------------------------------------------------------
# Schedule dialog
# ------------------------------------------------------------
function Invoke-Setup([string[]]$SetupArgs) {
    $all = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $script:DcSetupPath) + $SetupArgs
    $out = & powershell.exe @all 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    foreach ($l in $out) {
        if (-not [string]::IsNullOrWhiteSpace($l)) { Add-Log $l $(if ($code -ne 0) { $C.LogRed } else { $null }) }
    }
    return $code
}

function New-ScheduleDialog {
    $cur = Get-DcSchedule
    $d = @{ Current = $cur }

    $dlg = New-Object Windows.Forms.Form
    $dlg.SuspendLayout()
    $dlg.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
    $dlg.AutoScaleMode = "Dpi"
    $dlg.Text = T 'sched.title'
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false
    $dlg.StartPosition = "CenterParent"
    $dlg.ClientSize = New-Object Drawing.Size(600, 430)
    $dlg.BackColor = $C.Card
    $dlg.Font = $fontUi
    if ($appIcon) { $dlg.Icon = $appIcon }
    $d.Form = $dlg
    $dlg.Tag = $d

    function Add-Ctl($ctl, [int]$x, [int]$y) {
        $ctl.Location = New-Object Drawing.Point($x, $y)
        $dlg.Controls.Add($ctl)
        return $ctl
    }
    function New-Lbl([string]$text) {
        $l = New-Object Windows.Forms.Label
        $l.Text = $text
        $l.AutoSize = $true
        return $l
    }

    $col2 = 190

    [void](Add-Ctl (New-Lbl (T 'sched.repeat')) 24 27)
    $d.Freq = New-Object Windows.Forms.ComboBox
    $d.Freq.DropDownStyle = "DropDownList"
    $d.Freq.Width = 200
    foreach ($f in "Daily", "Weekly", "Monthly") { [void]$d.Freq.Items.Add((T "sched.freq.$f")) }
    [void](Add-Ctl $d.Freq $col2 24)

    # Daily / weekly interval
    $d.LblEvery = Add-Ctl (New-Lbl (T 'sched.every')) 24 69
    $d.Interval = New-Object Windows.Forms.NumericUpDown
    $d.Interval.Minimum = 1
    $d.Interval.Maximum = 365
    $d.Interval.Width = 70
    [void](Add-Ctl $d.Interval $col2 66)
    $d.LblUnit = Add-Ctl (New-Lbl "") ($col2 + 80) 69

    # Weekly days (Monday first)
    $d.Days = @{}
    $short = $Strings.($app.Lang).'days.short'
    $x = $col2
    foreach ($i in 1, 2, 3, 4, 5, 6, 0) {
        $cb = New-Object Windows.Forms.CheckBox
        $cb.Text = $short[$i]
        $cb.Width = 54
        $cb.Tag = $script:DcWeekDays[$i]
        [void](Add-Ctl $cb $x 104)
        $d.Days[$script:DcWeekDays[$i]] = $cb
        $x += 56
    }

    # Monthly
    $d.LblDom = Add-Ctl (New-Lbl (T 'sched.dayOfMonth')) 24 69
    $d.Dom = New-Object Windows.Forms.NumericUpDown
    $d.Dom.Minimum = 1
    $d.Dom.Maximum = 31
    $d.Dom.Width = 70
    [void](Add-Ctl $d.Dom $col2 66)
    $d.Last = New-Object Windows.Forms.CheckBox
    $d.Last.Text = T 'sched.lastDay'
    $d.Last.AutoSize = $true
    [void](Add-Ctl $d.Last ($col2 + 84) 68)
    $d.DomHint = Add-Ctl (New-Lbl (T 'sched.dom31')) $col2 104
    $d.DomHint.ForeColor = $C.Muted
    $d.DomHint.Font = $fontSub

    # Time
    [void](Add-Ctl (New-Lbl (T 'sched.time')) 24 151)
    $d.Time = New-Object Windows.Forms.DateTimePicker
    $d.Time.Format = "Custom"
    $d.Time.CustomFormat = "HH:mm"
    $d.Time.ShowUpDown = $true
    $d.Time.Width = 90
    [void](Add-Ctl $d.Time $col2 148)

    # Prune
    $d.Prune = New-Object Windows.Forms.CheckBox
    $d.Prune.Text = T 'chk.prune'
    $d.Prune.AutoSize = $true
    [void](Add-Ctl $d.Prune 24 194)
    $d.PruneAll = New-Object Windows.Forms.CheckBox
    $d.PruneAll.Text = T 'chk.pruneAll'
    $d.PruneAll.AutoSize = $true
    [void](Add-Ctl $d.PruneAll 44 220)

    # Preview + note
    $d.Preview = Add-Ctl (New-Lbl "") 24 262
    $d.Preview.Font = $fontBold
    $d.Preview.ForeColor = $C.Accent
    $d.Preview.MaximumSize = New-Object Drawing.Size(552, 0)

    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $d.Note = Add-Ctl (New-Lbl (T 'sched.note' $user $script:DcVhdxPath)) 24 300
    $d.Note.ForeColor = $C.Muted
    $d.Note.Font = $fontSub
    $d.Note.MaximumSize = New-Object Drawing.Size(552, 0)

    # Buttons
    $d.BtnSave = New-Button $true 110 $null
    $d.BtnSave.Text = T 'btn.save'
    [void](Add-Ctl $d.BtnSave 466 376)
    $d.BtnCancel = New-Button $false 100 $null
    $d.BtnCancel.Text = T 'btn.cancel'
    $d.BtnCancel.DialogResult = "Cancel"
    [void](Add-Ctl $d.BtnCancel 356 376)
    $d.BtnRemove = New-Button $false 140 $null
    $d.BtnRemove.Text = T 'btn.remove'
    $d.BtnRemove.ForeColor = $C.Failed
    $d.BtnRemove.Visible = [bool]$cur
    [void](Add-Ctl $d.BtnRemove 24 376)
    $dlg.CancelButton = $d.BtnCancel

    # --- behaviour ---
    $d.GetSpec = {
        param($d)
        $freq = @("Daily", "Weekly", "Monthly")[$d.Freq.SelectedIndex]
        [pscustomobject]@{
            Frequency  = $freq
            Interval   = [int]$d.Interval.Value
            Days       = @($d.Days.Values | Where-Object Checked | ForEach-Object { $_.Tag })
            DayOfMonth = if ($d.Last.Checked) { "Last" } else { [string][int]$d.Dom.Value }
            Time       = $d.Time.Value.ToString("HH:mm")
            Prune      = $d.Prune.Checked
            PruneAll   = $d.Prune.Checked -and $d.PruneAll.Checked
        }
    }

    $d.Refresh = {
        param($d)
        $spec = & $d.GetSpec $d
        $daily = $spec.Frequency -eq "Daily"
        $weekly = $spec.Frequency -eq "Weekly"
        $monthly = $spec.Frequency -eq "Monthly"

        $d.LblEvery.Visible = -not $monthly
        $d.Interval.Visible = -not $monthly
        $d.LblUnit.Visible = -not $monthly
        $d.LblUnit.Text = if ($weekly) { T 'sched.unit.Weekly' } else { T 'sched.unit.Daily' }
        foreach ($cb in $d.Days.Values) { $cb.Visible = $weekly }
        $d.LblDom.Visible = $monthly
        $d.Dom.Visible = $monthly
        $d.Last.Visible = $monthly
        $d.DomHint.Visible = $monthly -and -not $d.Last.Checked -and $d.Dom.Value -gt 28
        $d.Dom.Enabled = -not $d.Last.Checked
        $d.PruneAll.Enabled = $d.Prune.Checked
        if (-not $d.Prune.Checked) { $d.PruneAll.Checked = $false }

        $d.Preview.Text = T 'sched.preview' (Format-Schedule $spec)
    }

    # --- initial values ---
    $freqIndex = 1
    $d.Interval.Value = 1
    $d.Dom.Value = 1
    $timeText = "03:00"
    $selDays = @("Sunday")
    if ($cur -and $cur.Frequency -in @("Daily", "Weekly", "Monthly")) {
        $freqIndex = [array]::IndexOf(@("Daily", "Weekly", "Monthly"), $cur.Frequency)
        $d.Interval.Value = [math]::Max(1, [math]::Min(365, [int]$cur.Interval))
        if ($cur.Days.Count) { $selDays = $cur.Days }
        if ("$($cur.DayOfMonth)" -ieq "Last") { $d.Last.Checked = $true }
        elseif ($cur.DayOfMonth) { $d.Dom.Value = [int]$cur.DayOfMonth }
        $timeText = $cur.Time
        $d.Prune.Checked = $cur.Prune
        $d.PruneAll.Checked = $cur.PruneAll
    }
    elseif (-not $cur) {
        $d.Prune.Checked = $chkPrune.Checked
        $d.PruneAll.Checked = $chkPruneAll.Checked
    }
    foreach ($day in $selDays) { if ($d.Days[$day]) { $d.Days[$day].Checked = $true } }
    $d.Time.Value = [datetime]::Today.Add([TimeSpan]::Parse($timeText))
    $d.Freq.SelectedIndex = $freqIndex

    $onChange = { $x = $this.FindForm().Tag; & $x.Refresh $x }
    $d.Freq.add_SelectedIndexChanged($onChange)
    $d.Interval.add_ValueChanged($onChange)
    $d.Dom.add_ValueChanged($onChange)
    $d.Last.add_CheckedChanged($onChange)
    $d.Time.add_ValueChanged($onChange)
    $d.Prune.add_CheckedChanged($onChange)
    $d.PruneAll.add_CheckedChanged($onChange)
    foreach ($cb in $d.Days.Values) { $cb.add_CheckedChanged($onChange) }

    $d.BtnSave.add_Click({
        $d = $this.FindForm().Tag
        $dlg = $d.Form
        $spec = & $d.GetSpec $d
        if ($spec.Frequency -eq "Weekly" -and $spec.Days.Count -eq 0) {
            [Windows.Forms.MessageBox]::Show((T 'sched.noDays'), (T 'sched.title'), "OK", "Warning") | Out-Null
            return
        }

        $a = @("-Schedule", $spec.Frequency, "-At", $spec.Time)
        switch ($spec.Frequency) {
            "Daily"   { $a += @("-Interval", $spec.Interval) }
            "Weekly"  { $a += @("-Interval", $spec.Interval, "-DaysOfWeek", ($spec.Days -join ",")) }
            "Monthly" { $a += @("-DayOfMonth", $spec.DayOfMonth) }
        }
        if ($spec.Prune) { $a += "-PruneBeforeCompact" }
        if ($spec.PruneAll) { $a += "-PruneAll" }
        if ($script:DcVhdxPath -ne $script:DcVhdxDefault) { $a += @("-VhdxPath", $script:DcVhdxPath) }

        $dlg.UseWaitCursor = $true
        $log.Clear()
        $code = Invoke-Setup ([string[]]$a)
        $dlg.UseWaitCursor = $false

        if ($code -eq 0) {
            Set-Status 'sched.saved' @(Format-Schedule $spec) $C.Done $Glyph.done
            $dlg.DialogResult = "OK"
            $dlg.Close()
        }
        else {
            Set-Status 'sched.failed' @($code) $C.Failed $Glyph.failed
        }
    })

    $d.BtnRemove.add_Click({
        $dlg = $this.FindForm()
        $ans = [Windows.Forms.MessageBox]::Show((T 'sched.confirmRemove'), (T 'sched.title'), "YesNo", "Question")
        if ($ans -ne "Yes") { return }
        $log.Clear()
        $code = Invoke-Setup @("-Remove")
        if ($code -eq 0) { Set-Status 'sched.removed' @() $C.Done $Glyph.done }
        else { Set-Status 'sched.failed' @($code) $C.Failed $Glyph.failed }
        $dlg.DialogResult = "OK"
        $dlg.Close()
    })

    & $d.Refresh $d
    $dlg.ResumeLayout($true)
    return $d
}

function Show-ScheduleDialog {
    $d = New-ScheduleDialog
    [void]$d.Form.ShowDialog($form)
    $d.Form.Dispose()
    Update-TaskInfo
}


# ------------------------------------------------------------
# Buttons / links
# ------------------------------------------------------------
$btnStart.add_Click({ Start-Compaction })
$btnClose.add_Click({ $form.Close() })
$btnSchedule.add_Click({ Show-ScheduleDialog })

$btnLogs.add_Click({
    New-Item -ItemType Directory -Path $script:DcLogDir -Force | Out-Null
    Start-Process explorer.exe -ArgumentList "`"$script:DcLogDir`""
})

$lnkChange.add_LinkClicked({
    if ($app.Process) { return }
    $ofd = New-Object Windows.Forms.OpenFileDialog
    $ofd.Title = T 'path.dialogTitle'
    $ofd.Filter = "VHDX (*.vhdx)|*.vhdx|*.*|*.*"
    $ofd.CheckFileExists = $true
    $dir = Split-Path -Parent $script:DcVhdxPath
    if ($dir -and (Test-Path -LiteralPath $dir)) { $ofd.InitialDirectory = $dir }
    $ofd.FileName = Split-Path -Leaf $script:DcVhdxPath
    if ($ofd.ShowDialog($form) -eq "OK") { Set-VhdxPath $ofd.FileName }
    $ofd.Dispose()
})

$lnkDefault.add_LinkClicked({
    if ($app.Process) { return }
    Set-VhdxPath $script:DcVhdxDefault
})

$form.add_FormClosing({
    param($s, $e)
    if ($app.Process -and -not $app.Process.HasExited) {
        [Windows.Forms.MessageBox]::Show((T 'run.busyClose'), "Docker VHDX Compact", "OK", "Warning") | Out-Null
        $e.Cancel = $true
    }
})

$form.add_Shown({
    $split.SplitterDistance = [int]($split.Width * 0.55)
    $lv.Columns[4].Width = -2
    Update-PathLabel
})


# ------------------------------------------------------------
# Initial state
# ------------------------------------------------------------
Reset-Steps
Update-Stats (Get-DiskSnapshot)
Set-Status 'status.ready'
Set-UiTexts
Add-Log (T 'log.ready')
Add-Log (T 'log.engine' $script:DcEnginePath)
Add-Log (T 'log.logs' $script:DcLogDir)
if (-not (Test-Path -LiteralPath $script:DcVhdxPath -PathType Leaf)) {
    Add-Log (T 'path.notFound' $script:DcVhdxPath) $C.LogRed
}


function Save-WindowShot($win, [string]$path) {
    $win.TopMost = $true
    [Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 400
    [Windows.Forms.Application]::DoEvents()
    # CopyFromScreen: DrawToBitmap cannot render RichTextBox.
    $bmp = New-Object Drawing.Bitmap($win.Width, $win.Height)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($win.Location, [Drawing.Point]::Empty, $win.Size)
    $g.Dispose()
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

if ($SelfTest) {
    # Exercise the marker parser and the dialog without touching Docker.
    foreach ($l in @(
        "##STEP|preflight|running|",
        "##STEP|preflight|done|VHDX 458.627 GiB (on disk 458.627 GiB)",
        "##STEP|prune|done|",
        "##STEP|trim|done|447.4 GiB of free space released to the VHDX",
        "##STEP|stop-docker|done|",
        "##STEP|wsl-shutdown|done|",
        "##STEP|release|done|VHDX is not in use",
        "##STEP|attach|done|",
        "##STEP|compact|running|Compacting (this can take several minutes)...",
        "##PCT|compact|40",
        "[8/10] RUNNING  Compacting (this can take several minutes)..."
    )) { Invoke-EngineLine $l }
    Set-Sub 'run.elapsed' @("02:13")

    $summary = ($script:DcSteps | ForEach-Object { "{0}={1}" -f $_.Id, $app.Rows[$_.Id].Tag }) -join ", "
    Write-Output "SELFTEST lang: $($app.Lang)"
    Write-Output "SELFTEST rows: $summary"
    Write-Output "SELFTEST overall: $($barOverall.Value)/$($barOverall.Maximum)"
    Write-Output "SELFTEST status: $($lblStatus.Text)"

    $dd = New-ScheduleDialog
    $dd.Freq.SelectedIndex = 0; $p0 = $dd.Preview.Text
    $dd.Freq.SelectedIndex = 2; $dd.Last.Checked = $true; $p2 = $dd.Preview.Text
    $dd.Freq.SelectedIndex = 1; $dd.Days["Monday"].Checked = $true; $dd.Interval.Value = 2; $dd.Prune.Checked = $true; $p1 = $dd.Preview.Text
    Write-Output "SELFTEST preview daily:   $p0"
    Write-Output "SELFTEST preview monthly: $p2"
    Write-Output "SELFTEST preview weekly:  $p1"

    if ($Screenshot) {
        $form.Show()
        $split.SplitterDistance = [int]($split.Width * 0.55)
        $lv.Columns[4].Width = -2
        Update-PathLabel
        if ($ShowSchedule) {
            $dd.Form.StartPosition = "Manual"
            $dd.Form.Location = New-Object Drawing.Point(($form.Left + 200), ($form.Top + 120))
            $dd.Form.Show($form)
            Save-WindowShot $dd.Form $Screenshot
            $dd.Form.Close()
        }
        else {
            Save-WindowShot $form $Screenshot
        }
        $form.Close()
    }
    $dd.Form.Dispose()
    exit 0
}

[void]$form.ShowDialog()
$timer.Dispose()
$form.Dispose()
