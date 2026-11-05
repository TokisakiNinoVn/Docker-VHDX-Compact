; Inno Setup script for Docker VHDX Compact.
; Build with build.ps1 (compiles dist\DockerCompact.exe first), or:
;   ISCC.exe /DAppVersion=1.2.3 installer\DockerCompact.iss
; Output: dist\DockerCompact-Setup-<version>.exe

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName "Docker VHDX Compact"
#define AppExe "DockerCompact.exe"
#define PsExe "{sys}\WindowsPowerShell\v1.0\powershell.exe"

[Setup]
AppId={{6F1C2A57-3D8E-4B9A-9E2F-5C7D1A4B8E30}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Tokisaki Nino
AppPublisherURL=https://github.com/TokisakiNinoVn/Docker-VHDX-Compact
VersionInfoVersion={#AppVersion}
DefaultDirName={autopf}\DockerCompact
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
; Program Files is admin-only, so nobody else can swap the scripts that
; the elevated GUI and the scheduled task run.
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=..\dist
OutputBaseFilename=DockerCompact-Setup-{#AppVersion}
SetupIconFile=..\assets\images\icon-no-background.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
LicenseFile=..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern

; The installer wizard is English (Inno Setup ships no official Vietnamese
; translation); the app itself has an English / Vietnamese switch.
[CustomMessages]
DesktopIcon=Create a &desktop shortcut
Shortcuts=Shortcuts:
WeeklyTask=Run compaction &weekly (Sunday 03:00, as the current user)
WeeklyPrune=Also &prune unused Docker objects before each run
ScheduledTask=Scheduled task (can be changed later with "Schedule..." in the app):
Registering=Registering the scheduled task...
OpenApp=Open {#AppName}
Logs=Logs

[Tasks]
Name: "desktopicon"; Description: "{cm:DesktopIcon}"; GroupDescription: "{cm:Shortcuts}"
Name: "weeklytask"; Description: "{cm:WeeklyTask}"; GroupDescription: "{cm:ScheduledTask}"
Name: "weeklytask\prune"; Description: "{cm:WeeklyPrune}"; GroupDescription: "{cm:ScheduledTask}"; Flags: unchecked

[Files]
Source: "..\dist\DockerCompact.exe";                DestDir: "{app}"; Flags: ignoreversion
Source: "..\assets\images\icon-no-background.ico"; DestDir: "{app}"; DestName: "DockerCompact.ico"; Flags: ignoreversion
Source: "..\DockerCompact-UI.ps1";                  DestDir: "{app}"; Flags: ignoreversion
Source: "..\DockerCompact-Lang.json";               DestDir: "{app}"; Flags: ignoreversion
Source: "..\docker-compact.ps1";                    DestDir: "{app}"; Flags: ignoreversion
Source: "..\DockerCompact-AutoSetup.ps1";           DestDir: "{app}"; Flags: ignoreversion
Source: "..\DockerCompact-Common.ps1";              DestDir: "{app}"; Flags: ignoreversion
Source: "..\DockerCompact-UI.cmd";                  DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";                             DestDir: "{app}"; Flags: ignoreversion
Source: "..\docs\VIE.md";                           DestDir: "{app}"; DestName: "README.vi.md"; Flags: ignoreversion
Source: "..\LICENSE";                               DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Comment: "Compact the Docker Desktop WSL2 disk"
Name: "{group}\{cm:Logs}"; Filename: "{commonappdata}\DockerCompact\logs"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; WorkingDir: "{app}"; Comment: "Compact the Docker Desktop WSL2 disk"; Tasks: desktopicon

[Dirs]
Name: "{commonappdata}\DockerCompact\logs"

[Run]
Filename: "{#PsExe}"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\DockerCompact-AutoSetup.ps1"""; \
  StatusMsg: "{cm:Registering}"; Flags: runhidden waituntilterminated; \
  Tasks: weeklytask and not weeklytask\prune
Filename: "{#PsExe}"; \
  Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""{app}\DockerCompact-AutoSetup.ps1"" -PruneBeforeCompact"; \
  StatusMsg: "{cm:Registering}"; Flags: runhidden waituntilterminated; \
  Tasks: weeklytask\prune
Filename: "{app}\{#AppExe}"; Description: "{cm:OpenApp}"; Flags: postinstall nowait skipifsilent

[UninstallRun]
Filename: "{#PsExe}"; \
  Parameters: "-NoProfile -Command ""Unregister-ScheduledTask -TaskName DockerCompact -Confirm:$false -ErrorAction SilentlyContinue"""; \
  Flags: runhidden waituntilterminated; RunOnceId: "RemoveDockerCompactTask"

; Logs in %ProgramData%\DockerCompact\logs and per-user settings in
; %APPDATA%\DockerCompact are kept on uninstall.
