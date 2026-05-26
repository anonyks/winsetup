# Windows VM Post-Install Setup
# Usage: irm https://raw.githubusercontent.com/anonyks/winsetup/main/setup.ps1 | iex

$apps = @(
    @{ id = "Brave.Brave";                    name = "Brave Browser" },
    @{ id = "Microsoft.VisualStudioCode";     name = "VS Code" },
    @{ id = "Telegram.TelegramDesktop";       name = "Telegram" },
    @{ id = "Emurasoft.EmEditor";             name = "EmEditor" },
    @{ id = "Python.Python.3.10";             name = "Python 3.10" },
    @{ id = "Google.Drive";                   name = "Google Drive" },
    @{ id = "RARLab.WinRAR";                  name = "WinRAR" }
)

Write-Host "`n=== Windows Setup ===" -ForegroundColor Cyan

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host "winget not found. Installing..." -ForegroundColor Yellow
    $installer = "$env:TEMP\AppInstaller.msixbundle"
    Invoke-WebRequest -Uri "https://aka.ms/getwinget" -OutFile $installer -UseBasicParsing
    Add-AppxPackage -Path $installer
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: winget install failed. Install 'App Installer' from the Microsoft Store manually and re-run." -ForegroundColor Red
        exit 1
    }
    Write-Host "winget installed successfully." -ForegroundColor Green
}
Write-Host "winget $(winget --version) detected." -ForegroundColor Gray
Write-Host "Checking for winget update..." -NoNewline
winget upgrade --id Microsoft.AppInstaller --silent --accept-package-agreements --accept-source-agreements 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host " updated to $(winget --version)" -ForegroundColor Green
} else {
    Write-Host " already up to date" -ForegroundColor Gray
}
Write-Host "Installing $($apps.Count) apps...`n" -ForegroundColor Gray

$installed  = @()
$alreadyHad = @()
$failed     = @()

foreach ($app in $apps) {
    Write-Host "[$([array]::IndexOf($apps, $app) + 1)/$($apps.Count)] $($app.name)..." -NoNewline

    $output = winget install --id $app.id -e --silent --accept-package-agreements --accept-source-agreements 2>&1
    $code   = $LASTEXITCODE

    if ($code -eq 0) {
        Write-Host " installed" -ForegroundColor Green
        $installed += $app.name
    } elseif ($code -eq -1978335189) {
        Write-Host " already installed" -ForegroundColor Yellow
        $alreadyHad += $app.name
    } else {
        Write-Host " FAILED (exit $code)" -ForegroundColor Red
        $failed += $app.name
    }
}

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "Installed   : $($installed.Count)  $(if ($installed.Count)  { "($($installed  -join ', '))" })" -ForegroundColor Green
Write-Host "Already had : $($alreadyHad.Count) $(if ($alreadyHad.Count) { "($($alreadyHad -join ', '))" })" -ForegroundColor Yellow
if ($failed.Count -gt 0) {
    Write-Host "Failed      : $($failed.Count)  ($($failed -join ', '))" -ForegroundColor Red
} else {
    Write-Host "Failed      : 0" -ForegroundColor Gray
}
