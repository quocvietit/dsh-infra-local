# Opens workspace files on the Windows host when the Linux container asks.
# Polls data/.host-open-queue (sandbox network is isolated; HTTP to the host cannot work).
# Keep this script running while using DSH Web (Settings → Open configuration file).

$ErrorActionPreference = 'Continue'
$queue = Join-Path $PSScriptRoot 'data\.host-open-queue'
Write-Host "dsh-host-open polling $queue"

function Open-HostPath {
  param([string]$Path, [string]$Action)
  if (-not $Path) { return }
  $normalized = $Path -replace '/', '\'
  if (-not (Test-Path -LiteralPath $normalized)) {
    Write-Host "dsh-host-open: path not found: $normalized"
    return
  }
  if ($Action -eq 'reveal') {
    Start-Process explorer.exe -ArgumentList @('/select,', $normalized)
    Write-Host "dsh-host-open: revealed $normalized"
    return
  }
  $ext = [System.IO.Path]::GetExtension($normalized).ToLowerInvariant()
  if ($ext -in @('.yaml', '.yml', '.json', '.txt', '.md', '.env', '.toml')) {
    Start-Process notepad.exe -ArgumentList @($normalized)
    Write-Host "dsh-host-open: notepad $normalized"
    return
  }
  try {
    Invoke-Item -LiteralPath $normalized
    Write-Host "dsh-host-open: opened $normalized"
  } catch {
    Start-Process notepad.exe -ArgumentList @($normalized)
    Write-Host "dsh-host-open: notepad fallback $normalized"
  }
}

function Drain-Queue {
  if (-not (Test-Path -LiteralPath $queue)) { return }
  try {
    $raw = Get-Content -LiteralPath $queue -Raw -ErrorAction Stop
    Remove-Item -LiteralPath $queue -Force -ErrorAction SilentlyContinue
    if (-not $raw) { return }
    foreach ($line in ($raw -split '\r?\n')) {
      if (-not $line.Trim()) { continue }
      try {
        $body = $line | ConvertFrom-Json
        Open-HostPath -Path ([string]$body.path) -Action ([string]$body.action)
      } catch {
        Write-Host "dsh-host-open: bad queue line: $line"
      }
    }
  } catch {
    # File may be mid-write from the container.
  }
}

Drain-Queue
while ($true) {
  Drain-Queue
  Start-Sleep -Milliseconds 400
}
