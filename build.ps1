# build.ps1 - builds dist\DockerCompact.exe (launcher) and, when Inno Setup
# is installed, dist\DockerCompact-Setup-<version>.exe.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1 -Version 1.1.0
#
# Used both locally and by .github/workflows/release.yml.

[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = "0.0.0",

    # Only build the launcher exe.
    [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$dist = Join-Path $root "dist"
$icon = Join-Path $root "assets\images\icon-no-background.ico"
New-Item -ItemType Directory -Path $dist -Force | Out-Null

# --- 1. Check scripts and strings ---------------------------------------
$bad = 0
foreach ($f in Get-ChildItem (Join-Path $root "*.ps1")) {
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    foreach ($e in $errors) {
        Write-Host "$($f.Name):$($e.Extent.StartLineNumber): $($e.Message)" -ForegroundColor Red
        $bad++
    }
}
if ($bad) { throw "PowerShell syntax errors found." }

$lang = [IO.File]::ReadAllText((Join-Path $root "DockerCompact-Lang.json"), [Text.Encoding]::UTF8) | ConvertFrom-Json
$en = @($lang.en.PSObject.Properties.Name)
$vi = @($lang.vi.PSObject.Properties.Name)
$diff = Compare-Object $en $vi
if ($diff) { throw "DockerCompact-Lang.json: en/vi keys differ: $(($diff | ForEach-Object InputObject) -join ', ')" }
Write-Host "Scripts parse; $($en.Count) UI strings in en + vi."

# --- 2. Launcher exe -----------------------------------------------------
$csc = @(
    (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $csc) { throw "csc.exe (.NET Framework 4) not found." }

$versionCs = Join-Path $env:TEMP "DockerCompact-BuildInfo.cs"
"static class BuildInfo { public const string Version = `"$Version.0`"; }" |
    Set-Content -LiteralPath $versionCs -Encoding ASCII

$exe = Join-Path $dist "DockerCompact.exe"
& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
    "/win32icon:$icon" "/out:$exe" `
    /reference:System.Windows.Forms.dll `
    (Join-Path $root "launcher\DockerCompact.cs") $versionCs
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
Remove-Item -LiteralPath $versionCs -Force -ErrorAction SilentlyContinue
Write-Host "Built $exe"

if ($SkipInstaller) { return }

# --- 3. Installer --------------------------------------------------------
$iscc = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

if (-not $iscc) {
    Write-Warning "Inno Setup 6 (ISCC.exe) not found - skipped the installer. Install it from https://jrsoftware.org/isdl.php or use -SkipInstaller."
    return
}

& $iscc /Q "/DAppVersion=$Version" (Join-Path $root "installer\DockerCompact.iss")
if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }

Get-ChildItem $dist -Filter "DockerCompact-Setup-$Version.exe" | ForEach-Object {
    $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    "$h  $($_.Name)" | Set-Content -LiteralPath "$($_.FullName).sha256" -Encoding ASCII
    Write-Host "Built $($_.FullName)"
    Write-Host "SHA256 $h"
}
