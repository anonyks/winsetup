# Windows VM Post-Install Setup
# Usage: irm https://raw.githubusercontent.com/anonyks/winsetup/main/setup.ps1 | iex

$SetupUrl = "https://raw.githubusercontent.com/anonyks/winsetup/main/setup.ps1"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Restarting setup as Administrator..." -ForegroundColor Yellow

    if ($PSCommandPath) {
        $scriptPath = $PSCommandPath -replace "'", "''"
        $command = "& '$scriptPath'"
    } else {
        $command = "irm $SetupUrl | iex"
    }

    $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath "powershell.exe" -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encodedCommand) -Verb RunAs
    exit
}

$osVersion = [System.Environment]::OSVersion.Version
$buildNumber = $osVersion.Build

# Windows 11 = build 22000+, Windows 10 = build 10000-21999
# winget requires Windows 10 build 19041 or later
if ($buildNumber -lt 19041) {
    Write-Host "ERROR: This script requires Windows 10 build 19041 or later (or Windows 11)" -ForegroundColor Red
    Write-Host "Your system: Windows build $buildNumber" -ForegroundColor Red
    Write-Host "Please upgrade Windows and try again." -ForegroundColor Red
    exit 1
}

$LogFile = "$env:USERPROFILE\Desktop\setup-log.txt"

function Log {
    param([string]$msg, [string]$color = "Gray")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$timestamp] $msg"
    Write-Host $msg -ForegroundColor $color
}

function SetReg {
    param([string]$path, [string]$name, $value, [string]$type = "DWord", [string]$label)
    try {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
        $current = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -ne $current -and $current -eq $value) {
            Log "  already set: $label" "Gray"
        } else {
            Set-ItemProperty -Path $path -Name $name -Value $value -Type $type -Force -ErrorAction Stop | Out-Null
            Log "  applied: $label" "Green"
        }
    } catch {
        Log "  FAILED to set $label (access denied or path unavailable)" "Yellow"
    }
}

function Kill-ProcessSafe {
    param([string]$processName, [int]$maxRetries = 3)
    $retries = 0
    while ($retries -lt $maxRetries) {
        try {
            $procs = Get-Process -Name $processName -ErrorAction SilentlyContinue
            if ($procs) {
                $procs | Stop-Process -Force -ErrorAction Stop
                return $true
            }
            return $false
        } catch {
            $retries++
            if ($retries -lt $maxRetries) {
                Start-Sleep -Milliseconds 500
            }
        }
    }
    return $false
}

function Find-StartMenuConfigPath {
    $packagesPath = "$env:LOCALAPPDATA\Packages"
    if (Test-Path $packagesPath) {
        $startMenuPkg = Get-ChildItem $packagesPath -Filter "*StartMenuExperience*" -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($startMenuPkg) {
            $configPath = Join-Path $startMenuPkg.FullName "LocalState\start2.bin"
            if (Test-Path $configPath) { return $configPath }
        }
    }
    return $null
}

function Find-TaskbarPinsPath {
    $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (Test-Path $taskbarPath) { return $taskbarPath }
    return $null
}

function Find-AppPath {
    param([string]$appName, [string]$searchPattern, [string[]]$commonPaths)
    
    try {
        # Try to find in common paths
        foreach ($path in $commonPaths) {
            if (Test-Path $path) {
                $found = Get-ChildItem $path -Include $searchPattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
                if ($found) { return $found }
            }
        }
        
        # Try Registry (Program Files uninstall entries)
        $regPaths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
            "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        )
        foreach ($regPath in $regPaths) {
            try {
                $apps = Get-ChildItem $regPath -ErrorAction SilentlyContinue
                foreach ($app in $apps) {
                    $displayName = $app.GetValue("DisplayName")
                    if ($displayName -like "*$appName*") {
                        $location = $app.GetValue("InstallLocation")
                        if ($location) {
                            $found = Get-ChildItem "$location" -Include $searchPattern -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
                            if ($found) { return $found }
                        }
                    }
                }
            } catch {}
        }
    } catch {}
    
    return $null
}

function Find-PythonExe {
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) { return $pythonCmd.Source }
    
    $commonPaths = @(
        "$env:LOCALAPPDATA\Programs\Python",
        "$env:ProgramFiles\Python*",
        "$env:ProgramFiles (x86)\Python*",
        "C:\Python*"
    )
    
    foreach ($path in $commonPaths) {
        if ($path -like "*\*") {
            $found = Get-Item $path -ErrorAction SilentlyContinue | Get-ChildItem -Include "python.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
            if ($found) { return $found }
        }
    }
    
    return Find-AppPath "Python" "python.exe" $commonPaths
}

function Install-WinGet {
    Log "winget not found. Installing..." "Yellow"

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        Log "  installing NuGet provider" "Gray"
        Install-PackageProvider -Name NuGet -Force -ErrorAction Stop | Out-Null

        Log "  trusting PSGallery" "Gray"
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue

        Log "  installing Microsoft.WinGet.Client module" "Gray"
        Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery -ErrorAction Stop | Out-Null
        Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop

        Log "  repairing/registering winget" "Gray"
        Repair-WinGetPackageManager -AllUsers -ErrorAction Stop | Out-Null
    } catch {
        Log "  PowerShell bootstrap failed: $($_.Exception.Message)" "Yellow"
        Log "  trying direct App Installer package" "Gray"

        $installer = "$env:TEMP\AppInstaller.msixbundle"
        Invoke-WebRequest -Uri "https://aka.ms/getwinget" -OutFile $installer -UseBasicParsing -ErrorAction Stop
        Add-AppxPackage -Path $installer -ErrorAction Stop
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Log "ERROR: winget install failed. Restart PowerShell or install App Installer manually, then re-run." "Red"
        exit 1
    }

    Log "winget installed successfully." "Green"
}

"=== Setup Log - $(Get-Date) ===" | Set-Content $LogFile

$apps = @(
    @{ id = "Brave.Brave";                    name = "Brave Browser" },
    @{ id = "Telegram.TelegramDesktop";       name = "Telegram" },
    @{ id = "Emurasoft.EmEditor";             name = "EmEditor"; version = "25.0.0" },
    @{ id = "Python.Python.3.10";             name = "Python 3.10" },
    @{ id = "Google.GoogleDrive";             name = "Google Drive" },
    @{ id = "RARLab.WinRAR";                  name = "WinRAR" },
    @{ id = "Notepad++.Notepad++";            name = "Notepad++" },
    @{ id = "Microsoft.VisualStudioCode";     name = "VS Code" }
)

# -------------------------------------------------------
# 1. winget check / update
# -------------------------------------------------------
Log "`n=== Windows Setup ===" "Cyan"

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Install-WinGet
}
Log "winget $(winget --version) detected." "Gray"
Write-Host "Checking for winget update..." -NoNewline
winget upgrade --id Microsoft.AppInstaller --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Log "updated to $(winget --version)" "Green"
} else {
    Log "already up to date" "Gray"
}

# -------------------------------------------------------
# 2. Install apps
# -------------------------------------------------------
Log "`nInstalling $($apps.Count) apps..." "Gray"

$installed  = @()
$alreadyHad = @()
$failed     = @()

foreach ($app in $apps) {
    $n = [array]::IndexOf($apps, $app) + 1
    Log "[$n/$($apps.Count)] $($app.name)" "Cyan"

    $versionArg = if ($app.version) { @("-v", $app.version) } else { @() }
    $out  = winget install --id $app.id -e --silent @versionArg --accept-package-agreements --accept-source-agreements 2>&1
    $code = $LASTEXITCODE
    $out | ForEach-Object { Add-Content -Path $LogFile -Value "    $_" }

    if ($code -eq 0) {
        Log "  -> installed" "Green"
        $installed += $app.name
    } elseif ($code -eq -1978335189) {
        Log "  -> already installed" "Yellow"
        $alreadyHad += $app.name
    } else {
        Log "  -> FAILED (exit $code)" "Red"
        $failed += $app.name
    }
}

Log "`n--- App Summary ---" "Cyan"
Log "Installed   : $($installed.Count)  $(if ($installed.Count)  { "($($installed  -join ', '))" })" "Green"
Log "Already had : $($alreadyHad.Count) $(if ($alreadyHad.Count) { "($($alreadyHad -join ', '))" })" "Yellow"
if ($failed.Count -gt 0) {
    Log "Failed      : $($failed.Count)  ($($failed -join ', '))" "Red"
} else {
    Log "Failed      : 0" "Gray"
}

# -------------------------------------------------------
# 3. Python env vars
# -------------------------------------------------------
Log "`n=== Setting Python environment variables ===" "Cyan"

$pythonExe = Find-PythonExe

if ($pythonExe -and (Test-Path $pythonExe)) {
    $pythonDir     = Split-Path $pythonExe
    $pythonScripts = Join-Path $pythonDir "Scripts"
    [System.Environment]::SetEnvironmentVariable("PYTHON_HOME", $pythonDir, "User")
    $curPath  = [System.Environment]::GetEnvironmentVariable("PATH", "User")
    $addPaths = @($pythonDir, $pythonScripts) | Where-Object { $curPath -notlike "*$_*" }
    if ($addPaths) {
        [System.Environment]::SetEnvironmentVariable("PATH", ($curPath + ";" + ($addPaths -join ";")), "User")
    }
    Log "  PYTHON_HOME = $pythonDir" "Green"
    Log "  PATH updated with Python and Scripts" "Green"
} else {
    Log "  Python not found, skipping env vars" "Yellow"
}

# -------------------------------------------------------
# 4. Disable annoying startup apps
# -------------------------------------------------------
Log "`n=== Disabling startup apps ===" "Cyan"

$runKey       = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$startupNames = @("OneDrive", "PhoneLink", "Microsoft Teams", "com.squirrel.Teams.Teams")

foreach ($name in $startupNames) {
    $val = (Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue).$name
    if ($val) {
        Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
        Log "  disabled startup: $name" "Green"
    }
}

$edgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
SetReg $edgePolicyPath "StartupBoostEnabled"   0 "DWord" "Edge startup boost"
SetReg $edgePolicyPath "BackgroundModeEnabled" 0 "DWord" "Edge background mode"

$copilotPath = "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
SetReg $copilotPath "TurnOffWindowsCopilot" 1 "DWord" "Windows Copilot (policy)"

try {
    $oneDriveTasks = Get-ScheduledTask -TaskName "*OneDrive*" -ErrorAction SilentlyContinue
    if ($oneDriveTasks) {
        $oneDriveTasks | Disable-ScheduledTask -ErrorAction Stop | Out-Null
        Log "  disabled: OneDrive scheduled tasks" "Green"
    }
} catch {
    Log "  OneDrive tasks disable failed (may need admin or may already be disabled)" "Yellow"
}

# Kill Edge, OneDrive, Copilot if running
Log "`n=== Killing unwanted processes ===" "Cyan"
@("msedge", "OneDrive", "Copilot") | ForEach-Object {
    if (Kill-ProcessSafe $_) {
        Log "  killed: $_" "Green"
    } else {
        $procs = Get-Process -Name $_ -ErrorAction SilentlyContinue
        if (-not $procs) {
            Log "  not running: $_" "Gray"
        }
    }
}

# -------------------------------------------------------
# 5. Windows tweaks
# -------------------------------------------------------
Log "`n=== Applying Windows tweaks ===" "Cyan"

$explorerKey = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced"

# Set Brave as default browser
$bravePath = Find-AppPath "Brave" "brave.exe" @("$env:LOCALAPPDATA\BraveSoftware", "$env:ProgramFiles\BraveSoftware", "$env:ProgramFiles (x86)\BraveSoftware")

if ($bravePath) {
    try {
        $currentBrowser = (Get-ItemProperty "HKCU:\SOFTWARE\Microsoft\Windows\Shell\Associations\UrlAssociations\http\UserChoice" -ErrorAction SilentlyContinue).ProgId
        if ($currentBrowser -notlike "*Brave*") {
            Start-Process $bravePath "--make-default-browser" -Wait -ErrorAction SilentlyContinue
            Log "  set default browser: Brave" "Green"
        } else {
            Log "  default browser already Brave, skipping" "Gray"
        }
    } catch {
        Log "  default browser set failed (may require manual config)" "Yellow"
    }
} else {
    Log "  Brave not found, skipping default browser (install first)" "Yellow"
}

# Show file extensions
SetReg $explorerKey "HideFileExt" 0 "DWord" "show file extensions"

# Collapse/hide File Explorer ribbon
SetReg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Ribbon" "Minimized" 1 "DWord" "collapse File Explorer ribbon"

# Desktop icons - show only Recycle Bin
$desktopIcons = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
SetReg $desktopIcons "{645FF040-5081-101B-9F08-00AA002F954E}" 0 "DWord" "Recycle Bin on desktop (visible)"
SetReg $desktopIcons "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" 1 "DWord" "This PC desktop icon (hidden)"
SetReg $desktopIcons "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" 1 "DWord" "User folder desktop icon (hidden)"
SetReg $desktopIcons "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}" 1 "DWord" "Network desktop icon (hidden)"
SetReg $desktopIcons "{018D5C66-4533-4307-9B53-224DE2ED1FE6}" 1 "DWord" "OneDrive desktop icon (hidden)"
# Remove all shortcuts from desktop
$desktopPath = [System.Environment]::GetFolderPath("Desktop")
$shortcuts = Get-ChildItem $desktopPath -Include "*.lnk","*.url" -ErrorAction SilentlyContinue
if ($shortcuts) {
    $shortcuts | Remove-Item -Force -ErrorAction SilentlyContinue
    Log "  removed $($shortcuts.Count) desktop shortcut(s)" "Green"
}

# Unpin all Start menu groups/pins
$winBuild = [System.Environment]::OSVersion.Version.Build
try {
    if ($winBuild -ge 22000) {
        # Windows 11 - delete start2.bin, Windows recreates it clean on next login
        $start2 = Find-StartMenuConfigPath
        if ($start2) {
            Remove-Item $start2 -Force -ErrorAction Stop
            Log "  cleared Start menu pins (Win11 - takes effect after re-login)" "Green"
        }
    } else {
        # Windows 10 - import a blank start layout
        $xml = @"
<LayoutModificationTemplate xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" Version="1"
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification">
  <LayoutOptions StartTileGroupCellWidth="6" />
  <DefaultLayoutOverride>
    <StartLayoutCollection>
      <defaultlayout:StartLayout GroupCellWidth="6" />
    </StartLayoutCollection>
  </DefaultLayoutOverride>
</LayoutModificationTemplate>
"@
        $xmlPath = "$env:TEMP\StartLayout.xml"
        $xml | Set-Content $xmlPath -Encoding UTF8 -ErrorAction Stop
        Import-StartLayout -LayoutPath $xmlPath -MountPath "$env:SystemDrive\" -ErrorAction Stop
        Log "  cleared Start menu pins (Win10)" "Green"
    }
    Log "  desktop: only Recycle Bin visible" "Green"
} catch {
    Log "  Start menu customization failed (may require reboot): $($_.Exception.Message)" "Yellow"
}

# Disable Start menu ads & suggestions
$cdm = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
SetReg $cdm "SystemPaneSuggestionsEnabled"    0 "DWord" "Start menu suggestions"
SetReg $cdm "SubscribedContent-338388Enabled" 0 "DWord" "Start menu tips"
SetReg $cdm "SubscribedContent-338389Enabled" 0 "DWord" "Start menu highlights"
SetReg $cdm "SubscribedContent-353698Enabled" 0 "DWord" "Timeline suggestions"

# Disable telemetry
SetReg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0 "DWord" "telemetry"

# Dark theme
$themePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
SetReg $themePath "AppsUseLightTheme"    0 "DWord" "dark theme (apps)"
SetReg $themePath "SystemUsesLightTheme" 0 "DWord" "dark theme (system)"

# Hide search bar
SetReg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 0 "DWord" "taskbar search bar"

# Hide Copilot button
SetReg $explorerKey "ShowCopilotButton"   0 "DWord" "taskbar Copilot button"

# Hide Task View button
SetReg $explorerKey "ShowTaskViewButton"  0 "DWord" "taskbar Task View button"

# Hide News/Interests/Feeds
SetReg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds" "ShellFeedsTaskbarViewMode" 2 "DWord" "News & Interests feed"
SetReg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds" 0 "DWord" "Windows Feeds policy"

# Remove pinned taskbar shortcuts (Edge, Store, Mail)
$taskbarPins = Find-TaskbarPinsPath
if ($taskbarPins) {
    @("Microsoft Edge.lnk", "Microsoft Store.lnk", "Mail.lnk") | ForEach-Object {
        $p = Join-Path $taskbarPins $_
        if (Test-Path $p) { Remove-Item $p -Force; Log "  removed taskbar pin: $_" "Green" }
    }
}

# Restart Explorer to apply taskbar/theme changes
Log "  restarting Explorer to apply changes..." "Gray"
try {
    Stop-Process -Name explorer -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    Start-Process explorer -ErrorAction Stop
} catch {
    Log "  Explorer restart failed (changes may apply on next login)" "Yellow"
}

# -------------------------------------------------------
Log "`n=== All done! Log saved to: $LogFile ===" "Cyan"

# Launch apps
Log "`n=== Launching apps ===" "Cyan"

$launch = @(
    @{ name = "Brave";        pathFinder = { Find-AppPath "Brave" "brave.exe" @("$env:LOCALAPPDATA\BraveSoftware", "$env:ProgramFiles\BraveSoftware") } },
    @{ name = "VS Code";      pathFinder = { Find-AppPath "Visual Studio Code" "code.exe" @("$env:LOCALAPPDATA\Programs\Microsoft VS Code", "$env:ProgramFiles\Microsoft VS Code") } },
    @{ name = "Telegram";     pathFinder = { Find-AppPath "Telegram" "Telegram.exe" @("$env:APPDATA\Telegram Desktop", "$env:ProgramFiles\Telegram Desktop") } },
    @{ name = "Google Drive"; pathFinder = { Find-AppPath "Google Drive" "GoogleDriveFS.exe" @("$env:ProgramFiles\Google\Drive File Stream", "$env:ProgramFiles (x86)\Google\Drive File Stream") } }
)

foreach ($app in $launch) {
    $appPath = & $app.pathFinder
    if ($appPath -and (Test-Path $appPath)) {
        try {
            Start-Process $appPath -RedirectStandardOutput NUL -RedirectStandardError NUL -ErrorAction Stop
            Log "  launched: $($app.name)" "Green"
        } catch {
            Log "  failed to launch: $($app.name)" "Yellow"
        }
    } else {
        Log "  not found, skipping: $($app.name)" "Yellow"
    }
}
