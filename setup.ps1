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
Write-Host "Installing $($apps.Count) apps via winget...`n" -ForegroundColor Gray

$failed = @()

foreach ($app in $apps) {
    Write-Host "-> $($app.name)..." -NoNewline
    $result = winget install --id $app.id -e --silent --accept-package-agreements --accept-source-agreements 2>&1
    if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq -1978335189) {
        Write-Host " done" -ForegroundColor Green
    } else {
        Write-Host " FAILED" -ForegroundColor Red
        $failed += $app.name
    }
}

Write-Host ""
if ($failed.Count -eq 0) {
    Write-Host "All apps installed successfully." -ForegroundColor Green
} else {
    Write-Host "Failed: $($failed -join ', ')" -ForegroundColor Red
}
