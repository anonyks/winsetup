# winsetup

One-shot PowerShell setup for a fresh Windows install.

## What it does

- Installs Brave, Telegram, EmEditor, Python 3.10, Google Drive, WinRAR, Notepad++, and VS Code.
- Sets up Python so `python` and `pip` work from any terminal.
- Disables startup/background noise from OneDrive, Phone Link, Teams, Edge, and Copilot.
- Cleans desktop shortcuts, Start pins, and taskbar clutter.
- Enables dark theme, file extensions, fewer ads/suggestions, lower telemetry, and Brave as default browser.
- Launches Brave, VS Code, Telegram, and Google Drive when done.

---

## Run it

Open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/anonyks/winsetup/main/setup.ps1 | iex
```

Accept the Administrator prompt when it appears.

A log is saved on your Desktop as `setup-log.txt`.

---

## Notes

- Requires Windows 10/11 and an internet connection.
- Installs `winget` if missing.
- Some settings apply after Explorer restarts or you sign in again.
- Already-installed apps are skipped.
