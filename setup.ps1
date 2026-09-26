# Windows VM Post-Install Setup
# Safer: irm ... -OutFile setup.ps1; notepad .\setup.ps1; .\setup.ps1
# Quick:  irm https://raw.githubusercontent.com/anonyks/winsetup/main/setup.ps1 | iex

param(
    [switch]$SkipApps,
    [switch]$NoLaunch
)

# Windows PowerShell's Invoke-WebRequest renders a progress bar that can make
# downloads 10-100x slower than the actual network allows. Nothing here needs
# a visible progress bar, so disable it globally for every download below.
$ProgressPreference = 'SilentlyContinue'

$SetupUrl = "https://raw.githubusercontent.com/anonyks/winsetup/main/setup.ps1"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "Restarting setup as Administrator..." -ForegroundColor Yellow

    $switchArgs = @()
    if ($SkipApps) { $switchArgs += "-SkipApps" }
    if ($NoLaunch) { $switchArgs += "-NoLaunch" }

    if ($PSCommandPath) {
        $scriptPath = $PSCommandPath -replace "'", "''"
        $command = "& '$scriptPath' $($switchArgs -join ' ')"
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

# Resolves the real Desktop path even when it's redirected (OneDrive Known
# Folder Move is common on managed/corporate Windows images), instead of
# assuming the default under USERPROFILE.
$LogFile = Join-Path ([Environment]::GetFolderPath('Desktop')) "setup-log.txt"

function Log {
    param([string]$msg, [string]$color = "Gray")
    $timestamp = Get-Date -Format "HH:mm:ss"
    Add-Content -Path $LogFile -Value "[$timestamp] $msg"
    Write-Host $msg -ForegroundColor $color
}

function SetReg {
    param([string]$path, [string]$name, $value, [string]$type = "DWord", [string]$label, [switch]$Quiet)
    try {
        if (-not (Test-Path $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
        $current = (Get-ItemProperty -Path $path -Name $name -ErrorAction SilentlyContinue).$name
        if ($null -ne $current -and $current -eq $value) {
            Log "  already set: $label" "Gray"
            return $false
        } else {
            Set-ItemProperty -Path $path -Name $name -Value $value -Type $type -Force -ErrorAction Stop | Out-Null
            Log "  applied: $label" "Green"
            return $true
        }
    } catch {
        if ($Quiet) {
            Log "  skipped: $label (not writable on this build)" "Gray"
        } else {
            Log "  FAILED to set $label : $($_.Exception.Message)" "Yellow"
        }
        return $false
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
        
        # Try Windows PATH
        $pathVar = $env:PATH -split ";"
        foreach ($pathItem in $pathVar) {
            $fullPath = Join-Path $pathItem $searchPattern
            if (Test-Path $fullPath) { return $fullPath }
        }
    } catch {}
    
    return $null
}

function Find-PythonExe {
    # Check common paths first (real installations)
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
    
    # Last resort: check PATH (may be WindowsApps link, but better than nothing)
    $pythonCmd = Get-Command python -ErrorAction SilentlyContinue
    if ($pythonCmd) { return $pythonCmd.Source }
    
    return Find-AppPath "Python" "python.exe" $commonPaths
}

function Get-DownloadsFolder {
    # Respects a user-relocated Downloads folder instead of assuming the default path.
    try {
        $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"
        $path = (Get-ItemProperty -Path $key -Name "{374DE290-123F-4565-9164-39C4925E467B}" -ErrorAction Stop)."{374DE290-123F-4565-9164-39C4925E467B}"
        if ($path) { return $path }
    } catch {}
    return "$env:USERPROFILE\Downloads"
}

function Wait-ForBrowserDownload {
    param([string]$Extension, [datetime]$Since, [int]$TimeoutSec = 600)
    $downloads = Get-DownloadsFolder
    Log "  waiting for the file in $downloads (up to $([int]($TimeoutSec/60)) min)..." "Cyan"
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $lastSize = -1
    $lastPath = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $candidates = Get-ChildItem -Path $downloads -Filter "*$Extension" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $Since } | Sort-Object LastWriteTime -Descending
        if (-not $candidates) { continue }
        $f = $candidates[0]
        # Browsers keep a .crdownload/.tmp/.partial sibling until the save finishes.
        $stillSaving = Get-ChildItem -Path $downloads -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "$($f.BaseName)*" -and $_.Extension -in ".crdownload", ".tmp", ".partial" }
        if ($stillSaving) { continue }
        if ($f.FullName -eq $lastPath -and $f.Length -eq $lastSize -and $f.Length -gt 0) {
            return $f.FullName
        }
        $lastPath = $f.FullName
        $lastSize = $f.Length
    }
    return $null
}

function Get-FileRobust {
    # Tries a fast direct download with a real wall-clock cap (Invoke-WebRequest's
    # own -TimeoutSec only covers the initial connect, not a slow-but-progressing
    # transfer, so a background job + Wait-Job is what actually enforces this).
    # Falls back to opening the URL in the default browser and watching Downloads
    # for the saved file when the direct route is too big or too slow.
    param([string]$Uri, [string]$OutFile, [int]$FastTimeoutSec = 45, [int]$BrowserTimeoutSec = 600)

    $since = Get-Date
    $job = Start-Job -ScriptBlock {
        param($u, $o)
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $u -OutFile $o -UseBasicParsing
    } -ArgumentList $Uri, $OutFile

    $done = Wait-Job -Job $job -Timeout $FastTimeoutSec
    $ok = $done -and $job.State -eq 'Completed' -and (Test-Path $OutFile) -and (Get-Item $OutFile).Length -gt 0
    Stop-Job -Job $job -ErrorAction SilentlyContinue
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    if ($ok) { return $true }
    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }

    Log "  direct download too slow, opening it in your browser instead - save the file, it'll be picked up automatically" "Yellow"
    Start-Process $Uri
    $ext = [IO.Path]::GetExtension(([Uri]$Uri).Segments[-1])
    if (-not $ext) { $ext = [IO.Path]::GetExtension($OutFile) }
    $found = Wait-ForBrowserDownload -Extension $ext -Since $since -TimeoutSec $BrowserTimeoutSec
    if (-not $found) {
        Log "  no browser download detected within $([int]($BrowserTimeoutSec/60)) min" "Red"
        return $false
    }
    Move-Item -Path $found -Destination $OutFile -Force
    Log "  picked up from Downloads: $([IO.Path]::GetFileName($found))" "Green"
    return $true
}

function Install-AppInstallerDependencies {
    # Newer App Installer releases depend on specific VCLibs/WindowsAppRuntime
    # framework versions that older/fresh Windows images don't have yet - and
    # which exact frameworks/versions has changed release to release (hit
    # WindowsAppRuntime first, then an outdated VCLibs). Rather than chase each
    # one individually, install Microsoft's own per-release dependency bundle,
    # which is guaranteed to match whatever AppInstaller version was just
    # downloaded since it comes from the same GitHub release.
    Log "    installing App Installer dependencies (VCLibs / WindowsAppRuntime)..." "Gray"
    $zipPath = "$env:TEMP\AppInstallerDeps_$(Get-Random).zip"
    $extractPath = "$env:TEMP\AppInstallerDeps_$(Get-Random)"
    if (-not (Get-FileRobust -Uri "https://github.com/microsoft/winget-cli/releases/latest/download/DesktopAppInstaller_Dependencies.zip" -OutFile $zipPath -FastTimeoutSec 90)) {
        return $false
    }
    try {
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force -ErrorAction Stop
        $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
            "ARM64" { "arm64" }
            "x86"   { "x86" }
            default { "x64" }
        }
        $depFiles = Get-ChildItem -Path (Join-Path $extractPath $arch) -Filter "*.appx" -ErrorAction Stop
        $anyOk = $false
        foreach ($dep in $depFiles) {
            try {
                Add-AppxPackage -Path $dep.FullName -ErrorAction Stop
                Log "    installed dependency: $($dep.Name)" "Green"
                $anyOk = $true
            } catch {
                Log "    dependency install failed ($($dep.Name)): $($_.Exception.Message)" "Yellow"
            }
        }
        return $anyOk
    } catch {
        Log "    dependency extraction failed: $($_.Exception.Message)" "Yellow"
        return $false
    } finally {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Remove-Item $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Install-WinGet {
    Log "winget not found. Installing..." "Yellow"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Direct AppInstaller download/install: the PSGallery/NuGet-provider/
    # Repair-WinGetPackageManager route is slower (a package provider prompt,
    # a full module download, then a repair call that often fails anyway) and
    # still falls back to this exact same download when it doesn't work out.
    $urls = @(
        "https://aka.ms/getwinget",
        "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    )

    foreach ($url in $urls) {
        try {
            $installer = "$env:TEMP\AppInstaller_$(Get-Random).msixbundle"
            Log "  downloading App Installer from $url" "Gray"
            if (-not (Get-FileRobust -Uri $url -OutFile $installer)) {
                throw "download failed (direct and browser fallback both unsuccessful)"
            }

            Log "  installing AppInstaller..." "Gray"
            try {
                Add-AppxPackage -Path $installer -ErrorAction Stop
            } catch {
                # Match the HRESULT (0x80073CF3), not the English description text -
                # Windows keeps the hex code untranslated on every display language,
                # but the surrounding prose is localized and won't match on non-English builds.
                if ($_.Exception.Message -match "0x80073CF3") {
                    Log "  missing/outdated framework dependency, installing dependencies and retrying..." "Yellow"
                    if (Install-AppInstallerDependencies) {
                        Add-AppxPackage -Path $installer -ErrorAction Stop
                    } else {
                        throw
                    }
                } else {
                    throw
                }
            }
            Remove-Item $installer -Force -ErrorAction SilentlyContinue

            if (Get-Command winget -ErrorAction SilentlyContinue) {
                Log "winget installed successfully." "Green"
                return
            }
        } catch {
            Log "    failed via $url : $($_.Exception.Message)" "Yellow"
        }
    }

    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Log "ERROR: winget installation failed. Cannot proceed without package manager." "Red"
        exit 1
    }
}

"=== Setup Log - $(Get-Date) ===" | Set-Content $LogFile

$apps = @(
    @{ id = "Brave.Brave";                    name = "Brave Browser" },
    @{ id = "Telegram.TelegramDesktop";       name = "Telegram" },
    @{ id = "Emurasoft.EmEditor";             name = "EmEditor" },
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

function Get-WingetVersion {
    # Validate the output: right after AppInstaller installs/updates, the
    # execution alias can briefly misbehave and print the help text (with
    # "Unrecognized command: <path>") instead of a version number.
    $out = (& winget --version 2>&1 | Out-String).Trim()
    if ($out -match '^v?\d+(\.\d+)+') { return $out }
    return $null
}

function Wait-WingetReady {
    param([int]$TimeoutSec = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        $v = Get-WingetVersion
        if ($v) { return $v }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    return $null
}

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Install-WinGet
}
$wingetBefore = Wait-WingetReady
if ($wingetBefore) {
    Log "winget $wingetBefore detected." "Gray"
} else {
    Log "winget is installed but not responding yet, continuing anyway" "Yellow"
}
Write-Host "Checking for winget update..." -NoNewline
winget upgrade --id Microsoft.AppInstaller --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
$wingetAfter = Wait-WingetReady
if ($wingetAfter -and $wingetAfter -ne $wingetBefore) {
    Log "updated to $wingetAfter" "Green"
} else {
    Log "already up to date" "Gray"
}

# -------------------------------------------------------
# 2. Install apps
# -------------------------------------------------------
function Invoke-InstallBatch {
    # Runs winget installs as background jobs, at most $Throttle at a time.
    # A per-job timeout keeps one hung installer from stalling the whole run
    # (stopping the job abandons it; the installer process itself may linger).
    param([object[]]$Apps, [int]$Throttle = 4, [int]$JobTimeoutSec = 900)

    # --source winget skips the msstore lookup: faster, and avoids msstore
    # source failures that are common on fresh VMs.
    $installBlock = {
        param($id, $version)
        $ProgressPreference = 'SilentlyContinue'
        $versionArg = if ($version) { @("-v", $version) } else { @() }
        $out = winget install --id $id -e --source winget --silent @versionArg --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
        [pscustomobject]@{ Code = $LASTEXITCODE; Output = ($out | Out-String); TimedOut = $false }
    }

    $results = @{}
    $pending = New-Object System.Collections.Queue
    foreach ($a in $Apps) { $pending.Enqueue($a) }
    $running = @()

    while ($pending.Count -gt 0 -or $running.Count -gt 0) {
        while ($pending.Count -gt 0 -and $running.Count -lt $Throttle) {
            $app = $pending.Dequeue()
            $job = Start-Job -ScriptBlock $installBlock -ArgumentList $app.id, $app.version
            $running += [pscustomobject]@{ Job = $job; App = $app; Started = Get-Date }
            Log "  started: $($app.name)" "Gray"
        }

        Start-Sleep -Milliseconds 500
        $stillRunning = @()
        foreach ($r in $running) {
            $timedOut = ((Get-Date) - $r.Started).TotalSeconds -gt $JobTimeoutSec
            if ($r.Job.State -eq 'Running' -and -not $timedOut) { $stillRunning += $r; continue }

            if ($r.Job.State -eq 'Running') { Stop-Job -Job $r.Job -ErrorAction SilentlyContinue }
            $res = @(Receive-Job -Job $r.Job -ErrorAction SilentlyContinue) |
                Where-Object { $_.PSObject.Properties['Code'] } | Select-Object -Last 1
            Remove-Job -Job $r.Job -Force -ErrorAction SilentlyContinue

            if ($timedOut) {
                $res = [pscustomobject]@{ Code = -1; Output = "timed out after ${JobTimeoutSec}s"; TimedOut = $true }
            } elseif (-not $res) {
                $res = [pscustomobject]@{ Code = -1; Output = "install job returned no result"; TimedOut = $false }
            }
            $results[$r.App.name] = $res
            Log "  finished: $($r.App.name) (exit $($res.Code))" "Gray"
        }
        $running = $stillRunning
    }
    return $results
}

function Install-Apps {
    param([object[]]$Apps)
    $okCodes = @(0, -1978335189)
    $results = Invoke-InstallBatch -Apps $Apps -Throttle 4

    # Retry failures once, one at a time: covers the Windows Installer
    # single-instance lock (two MSI installs at once) and transient network
    # errors. Timed-out installs aren't retried (they'd likely hang again).
    $retry = @($Apps | Where-Object { $okCodes -notcontains $results[$_.name].Code -and -not $results[$_.name].TimedOut })
    if ($retry.Count -gt 0) {
        Log "  retrying $($retry.Count) failed install(s) one at a time..." "Yellow"
        $second = Invoke-InstallBatch -Apps $retry -Throttle 1
        foreach ($name in $second.Keys) { $results[$name] = $second[$name] }
    }
    return $results
}

$installed  = @()
$alreadyHad = @()
$failed     = @()

if ($SkipApps) {
    Log "`nSkipping app installs (-SkipApps)" "Yellow"
} else {
    Log "`nInstalling $($apps.Count) apps..." "Gray"

    $results = Install-Apps -Apps $apps

    foreach ($app in $apps) {
        $n = [array]::IndexOf($apps, $app) + 1
        Log "[$n/$($apps.Count)] $($app.name)" "Cyan"

        $res  = $results[$app.name]
        $code = $res.Code
        foreach ($line in ($res.Output -split "`r?`n")) {
            if ($line.Trim()) { Add-Content -Path $LogFile -Value "    $line" }
        }

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
$startupNames = @("OneDrive", "PhoneLink", "Microsoft Teams", "com.squirrel.Teams.Teams", "msedge", "Microsoft Edge")

foreach ($name in $startupNames) {
    $val = (Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue).$name
    if ($val) {
        Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
        Log "  disabled startup: $name" "Green"
    }
}

$edgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
$null = SetReg $edgePolicyPath "StartupBoostEnabled"   0 "DWord" "Edge startup boost"
$null = SetReg $edgePolicyPath "BackgroundModeEnabled" 0 "DWord" "Edge background mode"

# Disable Edge autorun via registry
try {
    $edgeAutorun = @(
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    )
    foreach ($regPath in $edgeAutorun) {
        foreach ($edgeKey in @("msedge", "Microsoft Edge")) {
            try {
                $val = (Get-ItemProperty -Path $regPath -Name $edgeKey -ErrorAction SilentlyContinue).$edgeKey
                if ($val) {
                    Remove-ItemProperty -Path $regPath -Name $edgeKey -ErrorAction SilentlyContinue
                    Log "  disabled Edge autorun from: $regPath" "Green"
                }
            } catch {}
        }
    }
} catch {}

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
$explorerRestartNeeded = $false

# Show file extensions
if (SetReg $explorerKey "HideFileExt" 0 "DWord" "show file extensions") { $explorerRestartNeeded = $true }

# Collapse/hide File Explorer ribbon
if (SetReg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Ribbon" "Minimized" 1 "DWord" "collapse File Explorer ribbon") { $explorerRestartNeeded = $true }

# Desktop icons - show only Recycle Bin
$desktopIcons = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
if (SetReg $desktopIcons "{645FF040-5081-101B-9F08-00AA002F954E}" 0 "DWord" "Recycle Bin on desktop (visible)") { $explorerRestartNeeded = $true }
if (SetReg $desktopIcons "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" 1 "DWord" "This PC desktop icon (hidden)") { $explorerRestartNeeded = $true }
if (SetReg $desktopIcons "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" 1 "DWord" "User folder desktop icon (hidden)") { $explorerRestartNeeded = $true }
if (SetReg $desktopIcons "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}" 1 "DWord" "Network desktop icon (hidden)") { $explorerRestartNeeded = $true }
if (SetReg $desktopIcons "{018D5C66-4533-4307-9B53-224DE2ED1FE6}" 1 "DWord" "OneDrive desktop icon (hidden)") { $explorerRestartNeeded = $true }

# Unpin all Start menu groups/pins
$winBuild = [System.Environment]::OSVersion.Version.Build
try {
    if ($winBuild -ge 22000) {
        # Windows 11 - delete start2.bin, Windows recreates it clean on next login
        $start2 = Find-StartMenuConfigPath
        if ($start2) {
            $fileSize = (Get-Item $start2 -ErrorAction SilentlyContinue).Length
            # Only delete if file size is significant (not already cleared)
            if ($fileSize -gt 1000) {
                Remove-Item $start2 -Force -ErrorAction Stop
                Log "  cleared Start menu pins (Win11 - takes effect after re-login)" "Green"
            } else {
                Log "  Start menu already cleared" "Gray"
            }
        }
    } else {
        # Windows 10 - import a blank start layout
        $start10RegPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApps"
        $start10Check = Get-ChildItem $start10RegPath -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count
        
        if ($start10Check -gt 0) {
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
        } else {
            Log "  Start menu already cleared" "Gray"
        }
    }
    Log "  desktop: only Recycle Bin visible" "Green"
} catch {
    Log "  Start menu customization failed (may require reboot): $($_.Exception.Message)" "Yellow"
}

# Disable Start menu ads & suggestions
$cdm = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
$null = SetReg $cdm "SystemPaneSuggestionsEnabled"    0 "DWord" "Start menu suggestions"
$null = SetReg $cdm "SubscribedContent-338388Enabled" 0 "DWord" "Start menu tips"
$null = SetReg $cdm "SubscribedContent-338389Enabled" 0 "DWord" "Start menu highlights"
$null = SetReg $cdm "SubscribedContent-353698Enabled" 0 "DWord" "Timeline suggestions"

# Disable telemetry
$null = SetReg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" "AllowTelemetry" 0 "DWord" "telemetry"

# Dark theme
$themePath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize"
if (SetReg $themePath "AppsUseLightTheme"    0 "DWord" "dark theme (apps)") { $explorerRestartNeeded = $true }
if (SetReg $themePath "SystemUsesLightTheme" 0 "DWord" "dark theme (system)") { $explorerRestartNeeded = $true }

# Hide search bar
if (SetReg "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search" "SearchboxTaskbarMode" 0 "DWord" "taskbar search bar") { $explorerRestartNeeded = $true }

# Hide Copilot button
if (SetReg $explorerKey "ShowCopilotButton"   0 "DWord" "taskbar Copilot button") { $explorerRestartNeeded = $true }

# Hide Task View button
if (SetReg $explorerKey "ShowTaskViewButton"  0 "DWord" "taskbar Task View button") { $explorerRestartNeeded = $true }

# Hide News/Interests/Feeds. The policy line below is what actually disables it;
# this per-user toggle is a legacy add-on and is locked down on newer Windows 11
# builds (News & Interests was replaced by Widgets), so its failure is harmless.
$feedsPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds"
if (Test-Path $feedsPath) {
    if (SetReg $feedsPath "ShellFeedsTaskbarViewMode" 2 "DWord" "News & Interests feed" -Quiet) { $explorerRestartNeeded = $true }
} else {
    Log "  News & Interests path not found (may not apply to this system)" "Gray"
}
$null = SetReg "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" "EnableFeeds" 0 "DWord" "Windows Feeds policy"

# Remove pinned taskbar shortcuts (Edge, Store, Mail)
$taskbarPins = Find-TaskbarPinsPath
if ($taskbarPins) {
    @("Microsoft Edge.lnk", "Microsoft Store.lnk", "Mail.lnk") | ForEach-Object {
        $p = Join-Path $taskbarPins $_
        if (Test-Path $p) { Remove-Item $p -Force; Log "  removed taskbar pin: $_" "Green"; $explorerRestartNeeded = $true }
    }
}

# Restart Explorer only if changes were made
if ($explorerRestartNeeded) {
    Log "  restarting Explorer to apply changes..." "Gray"
    try {
        Stop-Process -Name explorer -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Start-Process explorer -ErrorAction Stop
        Start-Sleep -Seconds 3
        Log "  Explorer restarted and stabilized" "Green"
    } catch {
        Log "  Explorer restart failed (changes may apply on next login)" "Yellow"
    }
} else {
    Log "  no Explorer changes needed" "Gray"
}

# -------------------------------------------------------
Log "`n=== All done! Log saved to: $LogFile ===" "Cyan"

# Launch only newly installed apps (skip on re-runs / -NoLaunch)
$shouldLaunch = -not $NoLaunch -and -not $SkipApps -and $installed.Count -gt 0

if (-not $shouldLaunch) {
    if ($NoLaunch) {
        Log "`nSkipping app launch (-NoLaunch)" "Yellow"
    } elseif ($SkipApps) {
        Log "`nSkipping app launch (-SkipApps)" "Yellow"
    } else {
        Log "`nNo new apps installed — skipping launch" "Gray"
    }
} else {
    Log "`n=== Launching apps ===" "Cyan"

    $launch = @(
        @{ name = "Brave";        pathFinder = { Find-AppPath "Brave" "brave.exe" @("$env:LOCALAPPDATA\BraveSoftware", "$env:ProgramFiles\BraveSoftware") } },
        @{ name = "Telegram";     pathFinder = { Find-AppPath "Telegram" "Telegram.exe" @("$env:APPDATA\Telegram Desktop", "$env:ProgramFiles\Telegram Desktop") } },
        @{ name = "VS Code";      pathFinder = { Find-AppPath "Visual Studio Code" "code.exe" @("$env:LOCALAPPDATA\Programs\Microsoft VS Code", "$env:ProgramFiles\Microsoft VS Code") } },
        @{ name = "Google Drive"; pathFinder = { Find-AppPath "Google Drive" "GoogleDriveFS.exe" @("$env:ProgramFiles\Google\Drive File Stream", "$env:ProgramFiles (x86)\Google\Drive File Stream") } }
    )

    foreach ($app in $launch) {
        try {
            $appPath = & $app.pathFinder
            if ($appPath -and (Test-Path $appPath)) {
                try {
                    Start-Process $appPath -WindowStyle Hidden -ErrorAction Stop
                    Log "  launched: $($app.name)" "Green"
                } catch {
                    Log "  failed to launch: $($app.name) ($($_.Exception.Message))" "Yellow"
                }
            } else {
                Log "  not found, skipping: $($app.name)" "Yellow"
            }
        } catch {
            Log "  error finding path for $($app.name): $($_.Exception.Message)" "Yellow"
        }
    }

    # Wait for installers to drop desktop shortcuts, then clean
    Start-Sleep -Seconds 5
}

# Clean user desktop
$desktopPath = [System.Environment]::GetFolderPath("Desktop")
$shortcuts = @(Get-ChildItem $desktopPath -Filter "*.lnk" -ErrorAction SilentlyContinue) + @(Get-ChildItem $desktopPath -Filter "*.url" -ErrorAction SilentlyContinue)
if ($shortcuts.Count -gt 0) {
    $shortcuts | Remove-Item -Force -ErrorAction SilentlyContinue
    Log "`n  cleaned up desktop: removed $($shortcuts.Count) shortcut(s)" "Green"
} else {
    Log "`n  desktop is clean (no shortcuts)" "Gray"
}

# Clean Public Desktop (if accessible). Resolved dynamically instead of
# assuming C:\, since the OS drive letter isn't always C: (e.g. some Azure
# VM images).
$publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
if (Test-Path $publicDesktop) {
    $publicShortcuts = @(Get-ChildItem $publicDesktop -Filter "*.lnk" -ErrorAction SilentlyContinue) + @(Get-ChildItem $publicDesktop -Filter "*.url" -ErrorAction SilentlyContinue)
    if ($publicShortcuts.Count -gt 0) {
        $publicShortcuts | Remove-Item -Force -ErrorAction SilentlyContinue
        Log "  cleaned up Public Desktop: removed $($publicShortcuts.Count) shortcut(s)" "Green"
    }
}

# Remove all extra taskbar pins (keep only Brave, File Explorer, and PowerShell Admin)
$taskbarPath = Find-TaskbarPinsPath
if ($taskbarPath -and (Test-Path $taskbarPath)) {
    $taskbarPins = @(Get-ChildItem $taskbarPath -Filter "*.lnk" -ErrorAction SilentlyContinue)
    
    # First, remove all pins except Brave, File Explorer, PowerShell
    foreach ($pin in $taskbarPins) {
        $pinName = $pin.BaseName.ToLower()
        if ($pinName -notmatch "(brave|file explorer|explorer|powershell)") {
            Remove-Item $pin.FullName -Force -ErrorAction SilentlyContinue
            Log "  unpinned from taskbar: $($pin.BaseName)" "Gray"
        }
    }
    
    # Add PowerShell Admin to taskbar if not already pinned
    $psAdminPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    if (Test-Path $psAdminPath) {
        $psShortcutPath = Join-Path $taskbarPath "Windows PowerShell.lnk"
        if (-not (Test-Path $psShortcutPath)) {
            try {
                $shell = New-Object -ComObject WScript.Shell
                $shortcut = $shell.CreateShortcut($psShortcutPath)
                $shortcut.TargetPath = $psAdminPath
                $shortcut.Arguments = ""
                $shortcut.Description = "Windows PowerShell"
                $shortcut.Save()
                [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
                Log "  pinned to taskbar: Windows PowerShell" "Gray"
            } catch {
                # Silent fail if can't create
            }
        }
    }
}
