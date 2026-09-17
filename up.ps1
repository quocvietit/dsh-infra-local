# Start DSH compose and the Windows helper for Settings → Open configuration file.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

docker compose up -d --pull never

$running = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'host-open\.ps1' }
if ($running) {
  Write-Host "host-open.ps1 already running (pid $($running[0].ProcessId))"
} else {
  Start-Process -FilePath 'powershell.exe' -ArgumentList @(
    '-NoProfile', '-WindowStyle', 'Minimized', '-File', (Join-Path $PSScriptRoot 'host-open.ps1')
  )
  Write-Host 'started host-open.ps1 (minimized). Keep that window open while using DSH.'
}

Write-Host 'UI: http://127.0.0.1:3080  (token in: docker compose logs dsh)'
