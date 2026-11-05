<p align="center">
  <img src="assets/images/icon-no-background.png" alt="Docker VHDX Compact icon" width="128" height="128">
</p>

<h1 align="center">Docker VHDX Compact</h1>

<p align="center">
  <b>Reclaim disk space from Docker Desktop on Windows.</b><br>
  Trims and compacts the WSL2 <code>docker_data.vhdx</code>, with a GUI that shows every step live.
</p>

<p align="center">
  <a href="https://github.com/TokisakiNinoVn/Docker-VHDX-Compact/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/TokisakiNinoVn/Docker-VHDX-Compact?style=flat-square&color=1d63ed"></a>
  <a href="https://github.com/TokisakiNinoVn/Docker-VHDX-Compact/actions/workflows/release.yml"><img alt="Build" src="https://img.shields.io/github/actions/workflow/status/TokisakiNinoVn/Docker-VHDX-Compact/release.yml?style=flat-square&label=build"></a>
  <a href="https://github.com/TokisakiNinoVn/Docker-VHDX-Compact/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/TokisakiNinoVn/Docker-VHDX-Compact/total?style=flat-square&color=2ea44f"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/TokisakiNinoVn/Docker-VHDX-Compact?style=flat-square&color=blue"></a>
</p>

<p align="center">
  <img alt="Windows 10/11" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?style=flat-square&logo=windows&logoColor=white">
  <img alt="PowerShell 5.1" src="https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white">
  <img alt="Docker Desktop" src="https://img.shields.io/badge/Docker%20Desktop-WSL2-2496ED?style=flat-square&logo=docker&logoColor=white">
  <img alt="WinForms" src="https://img.shields.io/badge/UI-WinForms-512BD4?style=flat-square&logo=dotnet&logoColor=white">
  <img alt="Inno Setup 6" src="https://img.shields.io/badge/Installer-Inno%20Setup%206-264DE4?style=flat-square">
  <img alt="GitHub Actions" src="https://img.shields.io/badge/CI-GitHub%20Actions-2088FF?style=flat-square&logo=githubactions&logoColor=white">
</p>

<p align="center">
  <a href="https://github.com/TokisakiNinoVn/Docker-VHDX-Compact/releases/latest"><b>Download</b></a> ·
  <a href="#features">Features</a> ·
  <a href="#install-with-the-setup-program">Install</a> ·
  <a href="#use-the-gui">Usage</a> ·
  <a href="#tech-stack">Tech stack</a> ·
  <a href="docs/VIE.md">Tiếng Việt</a>
</p>

## Features

Docker Desktop's WSL2 disk (`docker_data.vhdx`) grows as you pull images and build, but it never shrinks on its own, even after you delete data. This tool gives that space back to Windows:

- **Live GUI**: every step shown as pending / running / done / skipped / failed, with overall and compaction progress, elapsed time, the live output, and before/after sizes.
- **Actually shrinks the disk**: runs `fstrim` inside Docker's distro first, so space freed in Linux reaches the VHDX before DiskPart compacts it.
- **Optional prune**: `docker system prune` + `docker builder prune`, or a deep prune of all unused images and build cache (volumes are kept).
- **English / Vietnamese** interface, switchable in the top-right corner.
- **Custom VHDX path** for when Docker's disk is not in the default location.
- **Scheduled task**: daily, weekly or monthly, at the time you choose, unattended.
- **TXT + CSV logs** for every run (GUI and task).
- **Installer** with Start Menu shortcuts, built and released by GitHub Actions.

> [!IMPORTANT]
> Compaction closes Docker Desktop and runs `wsl --shutdown`, so running containers and all WSL distros are stopped. Run it when that is safe.

## Screenshots

Real runs with **Prune** ticked:

![A 458.6 GB VHDX compacted to 11.2 GB in 2:14](assets/images/image-preview-3.png)

*458.63 GB → 11.22 GB; 447.42 GB of free space gained on `C:`, in 2 min 14 s.*

![A 534.6 GB VHDX compacted to 6.8 GB in 1:03](assets/images/image-preview-4.png)

*534.58 GB → 6.81 GB; 527.81 GB gained on `C:`, in 1 min 03 s.*

## Files

```text
C:\Scripts\
├── DockerCompact-UI.cmd          # double-click to open the GUI (portable use)
├── DockerCompact-UI.ps1          # the GUI (Windows Forms)
├── DockerCompact-Lang.json       # GUI text in English and Vietnamese
├── docker-compact.ps1            # the engine: does the actual compaction
├── DockerCompact-AutoSetup.ps1   # installs the weekly task / runs it with logging
├── DockerCompact-Common.ps1      # shared paths, snapshots and logging
├── launcher\DockerCompact.cs     # source of DockerCompact.exe (app icon + launcher)
├── installer\DockerCompact.iss   # Inno Setup script (Setup.exe)
├── build.ps1                     # builds DockerCompact.exe and Setup.exe
├── VERSION                       # release version, read by build.ps1 and the workflow
├── assets\images\                # app icon and screenshots
├── .github\workflows\release.yml # builds Setup.exe and publishes a Release
└── logs\                         # created automatically
    ├── docker-compact.log
    └── docker-compact-history-v2.csv
```

The scripts find each other through their own folder, so the whole set can live anywhere as long as the files stay together. The scheduled task points at wherever `DockerCompact-AutoSetup.ps1` was when you installed it.

## Install with the setup program

Download `DockerCompact-Setup-<version>.exe` from the repository's **Releases** page and run it (it asks for Administrator). It:

- installs the app to `C:\Program Files\DockerCompact`, which only administrators can change;
- adds Start Menu (and optionally desktop) shortcuts to `DockerCompact.exe`, which carries the app icon;
- optionally registers a weekly task (Sunday 03:00) for the user running the setup. Change it later with **Schedule...** in the app;
- writes logs to `C:\ProgramData\DockerCompact\logs`.

Silent install for many machines: `DockerCompact-Setup-1.0.0.exe /VERYSILENT /TASKS="weeklytask"`. Uninstalling removes the scheduled task and keeps the logs.

The weekly task runs as the account that registered it, and the VHDX lives in that user's `%LOCALAPPDATA%`. So on each machine, register the task as the person who uses Docker, from the setup program or with the app's **Schedule...** button.

### Building a release

Work happens on the `dev` branch; `main` only receives releases. `.github/workflows/release.yml` runs `build.ps1` on GitHub Actions **only when a pull request from `dev` is merged into `main`**:

1. On `dev`, set the new version in the `VERSION` file (e.g. `1.1.1`), commit and push.
2. Open a pull request `dev` → `main` and merge it.

The workflow then checks the scripts' syntax and the UI strings, compiles `DockerCompact.exe` with the app icon, builds `dist\DockerCompact-Setup-<VERSION>.exe` plus a `.sha256` file, creates the tag `v<VERSION>` on the merge commit, and publishes both files to a GitHub Release. If that tag already exists, the build stops so an old release is never overwritten: bump `VERSION` and merge again. Pushes to either branch, and pull requests that are closed without merging, build nothing. Running the workflow by hand (**Actions → Build installer → Run workflow**) only produces a downloadable artifact.

To build locally, install [Inno Setup 6](https://jrsoftware.org/isdl.php) and run (the version comes from `VERSION`; `-Version 1.2.3` overrides it):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\build.ps1
```

Without Inno Setup, `-SkipInstaller` builds only `dist\DockerCompact.exe`. The installer wizard itself is in English, because Inno Setup ships no official Vietnamese translation.

The installer is not code-signed, so SmartScreen shows "Windows protected your PC" (choose **More info → Run anyway**). Sign it with a code-signing certificate to remove the warning.

## Tech stack

| Part | Technology |
|------|------------|
| GUI | Windows Forms on Windows PowerShell 5.1 (no extra runtime to install) |
| Compaction engine | PowerShell + DiskPart (`attach vdisk readonly`, `compact vdisk`) |
| Freeing space inside the disk | `fstrim` in the `docker-desktop` WSL2 distro, `docker system` / `builder prune` |
| Launcher | C# `DockerCompact.exe`, compiled with the .NET Framework `csc.exe`; carries the app icon and asks for UAC |
| Scheduling | Windows Task Scheduler (task XML with daily / weekly / monthly triggers) |
| Localization | UTF-8 JSON string table (English, Vietnamese) |
| Installer | Inno Setup 6 |
| CI/CD | GitHub Actions on `windows-latest`: builds and publishes a Release when `dev` is merged into `main` |

## Requirements

- Windows 10/11, Windows PowerShell 5.1.
- Docker Desktop with the WSL2 backend (per-user install in `%LOCALAPPDATA%\Programs\DockerDesktop` or machine-wide in `%ProgramFiles%\Docker\Docker`).
- The VHDX, by default `%LOCALAPPDATA%\Docker\wsl\disk\docker_data.vhdx`. Pick another location with **Change...** in the GUI.
- Administrator rights (DiskPart and `wsl --shutdown`). The GUI asks for them through UAC.
- English Windows display language: success is detected from DiskPart's English messages.

## Use the GUI

Open **Docker VHDX Compact** from the Start Menu (installed), double-click `DockerCompact-UI.cmd` (portable), or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Scripts\DockerCompact-UI.ps1"
```

1. Optional: tick **Prune unused Docker objects first** (`docker system prune -f` + `docker builder prune -f`).
2. Optional: also tick **Deep prune** to remove all unused images and all build cache (volumes are kept).
3. Optional: tick **Don't start Docker Desktop afterwards** to leave Docker stopped if it was not running before.
4. Click **Start compaction** and confirm.

The window lists the steps:

| # | Step | What happens |
|---|------|--------------|
| 1 | Check prerequisites | Administrator, VHDX and Docker Desktop present; records sizes |
| 2 | Prune unused Docker objects | Only when ticked; otherwise *Skipped* |
| 3 | Trim free space (fstrim) | `fstrim` on `/mnt/docker-desktop-disk` inside the `docker-desktop` distro, so freed space reaches the VHDX |
| 4 | Close Docker Desktop | Graceful close, then force-stops leftover Docker processes |
| 5 | Shut down WSL | `wsl --shutdown` |
| 6 | Release VHDX file lock | Waits until nothing holds the file; detaches a stale DiskPart attachment if needed |
| 7 | Attach VHDX (read-only) | DiskPart `attach vdisk readonly` |
| 8 | Compact VHDX | DiskPart `compact vdisk`, with live percentage |
| 9 | Detach VHDX | DiskPart `detach vdisk` |
| 10 | Start Docker Desktop | Relaunches Docker Desktop |

### Why the VHDX may not shrink

Docker Desktop mounts its data disk (ext4) **without** the `discard` option. When you delete images or build cache, Linux frees the space inside the filesystem but never tells the VHDX, so `compact vdisk` alone finds nothing to reclaim. Step 3 runs `fstrim` to release those blocks, and **it needs Docker Desktop to be running** when you start. If Docker is not running, the step shows a warning.

The VHDX can only shrink down to the data Docker still keeps. Preflight prints `docker system df` and the space used inside the disk, plus the most that can be reclaimed. If that number is small, free data first: tick **Deep prune** (`docker system prune -a` + `docker builder prune -a`: all unused images and all build cache; volumes are kept), or remove what you no longer need yourself.

If a step fails it is marked red with the reason, later steps show *Not run*, and the script still tries to detach the VHDX and restart Docker. The window cannot be closed while a run is in progress, so DiskPart is never interrupted halfway.

The cards at the top show the VHDX file size, the space it actually uses on disk, free space on `C:`, and the last recorded result. After a run they show the change compared with before.

- **Language** (top right): English or Tiếng Việt. The choice is remembered per user in `%APPDATA%\DockerCompact\settings.json`. Lines coming from the engine and DiskPart in the log stay in English.
- **Change...** next to the VHDX path picks another `docker_data.vhdx` (for example when Docker's disk image location was moved to another drive). **Use default** goes back to the default path. The free-space card follows the drive of the chosen VHDX.
- **Schedule...** sets up the scheduled task: daily (every N days), weekly (every N weeks, on chosen days) or monthly (a day of the month, or the last day), at the time you pick, optionally with prune. It shows a preview such as *every week on Sun at 03:00*, and **Remove schedule** deletes the task. The task uses the VHDX path selected in the app.
- **Open logs** opens the `logs` folder.

## Weekly scheduled task

From the GUI, click **Schedule...**, or from an Administrator PowerShell:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force; & "C:\Scripts\DockerCompact-AutoSetup.ps1"
```

Without options this means every Sunday at 03:00. Other examples:

```powershell
& "C:\Scripts\DockerCompact-AutoSetup.ps1" -Schedule Daily -At 02:30
& "C:\Scripts\DockerCompact-AutoSetup.ps1" -Schedule Daily -Interval 3 -At 01:00
& "C:\Scripts\DockerCompact-AutoSetup.ps1" -Schedule Weekly -DaysOfWeek "Monday,Friday" -At 22:00
& "C:\Scripts\DockerCompact-AutoSetup.ps1" -Schedule Monthly -DayOfMonth Last -At 03:00
& "C:\Scripts\DockerCompact-AutoSetup.ps1" -Remove
```

More options: `-PruneBeforeCompact`, `-PruneAll` (with prune), `-VhdxPath "D:\Docker\disk\docker_data.vhdx"`. A monthly day that a month does not have (e.g. 31) is skipped that month.

The task runs as your account with highest privileges, using the Interactive logon type, so you need to be signed in. A missed run starts as soon as possible, and the task also runs on battery power.

```powershell
Get-ScheduledTaskInfo -TaskName "DockerCompact" | Format-List LastRunTime, LastTaskResult, NextRunTime
Start-ScheduledTask -TaskName "DockerCompact"      # run now (stops Docker!)
Disable-ScheduledTask -TaskName "DockerCompact"
Enable-ScheduledTask -TaskName "DockerCompact"
Unregister-ScheduledTask -TaskName "DockerCompact" -Confirm
```

## Command line

The engine can also be run directly from an Administrator PowerShell. It prints numbered steps:

```powershell
& "C:\Scripts\docker-compact.ps1"            # compact only
& "C:\Scripts\docker-compact.ps1" -Prune     # prune first
```

`-Prune -PruneAll` also removes all unused images and all build cache. `-VhdxPath` points at a VHDX outside the default location. `-KeepDockerStopped` leaves Docker Desktop stopped if it was not running. `-ProgressMarkers` adds the machine-readable `##STEP|id|state|message` and `##PCT|id|percent` lines that the GUI reads.

The script exits with code `0` only when compaction and detach were both confirmed, and `1` otherwise.

## Logs

- `logs\docker-compact.log`: every run's start/end, before/after snapshot, full script output and status.
- `logs\docker-compact-history-v2.csv`: one row per run with `Source` (UI/Task), `Status`, duration, VHDX file size, VHDX on-disk size, Get-VHD allocated/virtual size (when the Hyper-V module is installed), `C:` free space, and the deltas.

```powershell
Get-Content "C:\Scripts\logs\docker-compact.log" -Tail 80
Import-Csv "C:\Scripts\logs\docker-compact-history-v2.csv" | Format-Table StartTime, Source, Status, DurationSeconds, VhdxOnDiskBeforeGiB, VhdxOnDiskAfterGiB, CFreeDeltaGiB -AutoSize
```

## Notes

- `LastTaskResult = 0` only means the script exited with `0`; check the CSV for the space actually reclaimed.
- If the VHDX is not sparse, the file size and the on-disk size are the same. Compaction only reclaims space that the Linux filesystem inside has freed *and trimmed*, so pruning first and keeping Docker running when you start the compaction reclaims the most.
- The scripts never delete, reset, unregister or reformat the VHDX.

## License

[MIT](LICENSE)
