# Starts the ProofHire worker using the .env file in this folder.
# Docker is optional: only interview code grading needs it.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$envFiles = @('.env', '.env.backend', '.env.local', 'backend/.env') |
    Where-Object { Test-Path $_ }

if (-not $envFiles) {
    if (Test-Path '.env.txt') {
        Write-Host 'Found .env.txt instead of .env.' -ForegroundColor Yellow
        Write-Host 'Notepad adds .txt to untitled files. Rename it with:' -ForegroundColor Yellow
        Write-Host '  Rename-Item .env.txt .env' -ForegroundColor Cyan
        exit 1
    }
    Write-Host 'No env file found. Copy the example and fill it in:' -ForegroundColor Yellow
    Write-Host '  Copy-Item .env.example .env' -ForegroundColor Cyan
    Write-Host '  Copy-Item .env.backend.example .env.backend' -ForegroundColor Cyan
    Write-Host 'Later files win: .env, .env.backend, .env.local, backend/.env.' -ForegroundColor DarkGray
    exit 1
}

foreach ($envFile in $envFiles) {
    Write-Host "Loading $envFile" -ForegroundColor DarkGray
    Get-Content $envFile | ForEach-Object {
        $line = $_.Trim()
        if (-not $line -or $line.StartsWith('#')) { return }
        $index = $line.IndexOf('=')
        if ($index -lt 1) { return }
        $name = $line.Substring(0, $index).Trim()
        $value = $line.Substring($index + 1).Trim().Trim('"').Trim("'")
        Set-Item -Path "Env:$name" -Value $value
    }
}

foreach ($required in 'SUPABASE_URL', 'SUPABASE_SECRET_KEY') {
    if (-not [Environment]::GetEnvironmentVariable($required)) {
        Write-Host "Missing $required in the env files" -ForegroundColor Red
        exit 1
    }
}

Write-Host 'Starting ProofHire workers (screening + email + interview evaluation).' -ForegroundColor Green
Write-Host 'Leave this window open. Ctrl+C stops it.' -ForegroundColor DarkGray
go run ./backend/cmd/worker
