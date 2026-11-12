# Starts the ProofHire worker using the .env file in this folder.
# Docker is optional: only interview code grading needs it.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

if (-not (Test-Path '.env')) {
    Write-Host 'No .env found. Create one with:' -ForegroundColor Yellow
    Write-Host '  SUPABASE_URL=https://<project>.supabase.co'
    Write-Host '  SUPABASE_SECRET_KEY=sb_secret_...'
    Write-Host '  EMAIL_PROVIDER=smtp'
    Write-Host '  SMTP_HOST=smtp.gmail.com'
    Write-Host '  SMTP_PORT=587'
    Write-Host '  SMTP_SECURITY=starttls'
    Write-Host '  SMTP_USERNAME=you@gmail.com'
    Write-Host '  SMTP_PASSWORD=<16-character app password, no spaces>'
    Write-Host '  EMAIL_FROM_ADDRESS=you@gmail.com'
    Write-Host '  EMAIL_FROM_NAME=ProofHire'
    Write-Host '  APP_BASE_URL=http://localhost:5173'
    exit 1
}

Get-Content '.env' | ForEach-Object {
    $line = $_.Trim()
    if (-not $line -or $line.StartsWith('#')) { return }
    $index = $line.IndexOf('=')
    if ($index -lt 1) { return }
    $name = $line.Substring(0, $index).Trim()
    $value = $line.Substring($index + 1).Trim().Trim('"').Trim("'")
    Set-Item -Path "Env:$name" -Value $value
}

foreach ($required in 'SUPABASE_URL', 'SUPABASE_SECRET_KEY') {
    if (-not [Environment]::GetEnvironmentVariable($required)) {
        Write-Host "Missing $required in .env" -ForegroundColor Red
        exit 1
    }
}

Write-Host 'Starting ProofHire workers (screening + email + interview evaluation).' -ForegroundColor Green
Write-Host 'Leave this window open. Ctrl+C stops it.' -ForegroundColor DarkGray
go run ./backend/cmd/worker
