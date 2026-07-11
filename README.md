# winsetup

One-shot PowerShell setup for a fresh Windows install.

## What it does

- Installs Brave, Telegram, EmEditor, Python 3.10, Google Drive, WinRAR, Notepad++, and VS Code.
- Sets up Python so `python` and `pip` work from any terminal.
- Disables startup/background noise from OneDrive, Phone Link, Teams, Edge, and Copilot.
- Cleans desktop shortcuts, Start pins, and taskbar clutter.
- Enables dark theme, file extensions, fewer ads/suggestions, and lower telemetry.
- Launches Brave, VS Code, Telegram, and Google Drive when new apps were installed.

---

## Run it (recommended)

Download, skim, then run:

```powershell
irm https://raw.githubusercontent.com/anonyks/winsetup/main/setup.ps1 -OutFile setup.ps1
notepad .\setup.ps1
.\setup.ps1
```

Accept the Administrator prompt when it appears.

### One-liner (less safe)

```powershell
irm https://raw.githubusercontent.com/anonyks/winsetup/main/setup.ps1 | iex
```

### Switches

```powershell
.\setup.ps1 -SkipApps    # tweaks only, no winget installs
.\setup.ps1 -NoLaunch    # install/tweak but don't open apps
```

A log is saved on your Desktop as `setup-log.txt`.

---

## Notes

- Requires Windows 10/11 and an internet connection.
- Installs `winget` if missing (PSGallery trust is temporary during bootstrap).
- Some settings apply after Explorer restarts or you sign in again.
- Already-installed apps are skipped; re-runs won't re-launch apps unless something new installed.
