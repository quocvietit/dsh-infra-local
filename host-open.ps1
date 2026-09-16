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
  if ($Action -eq 'reveal' -and (Test-Path -LiteralPath $normalized)) {
    Start-Process explorer.exe -ArgumentList @('/select,', $normalized)
    return
  }
  if (Test-Path -LiteralPath $normalized) {
    try {
      Invoke-Item -LiteralPath $normalized
      return
    } catch {
      Start-Process notepad.exe -ArgumentList @($normalized)
      return
    }
  }
  Write-Host "dsh-host-open: path not found: $normalized"
}

while ($true) {
  if (Test-Path -LiteralPath $queue) {
    try {
      $raw = Get-Content -LiteralPath $queue -Raw -ErrorAction Stop
      Remove-Item -LiteralPath $queue -Force -ErrorAction SilentlyContinue
      if ($raw) {
        foreach ($line in ($raw -split '\r?\n')) {
          if (-not $line.Trim()) { continue }
          $body = $line | ConvertFrom-Json
          Open-HostPath -Path ([string]$body.path) -Action ([string]$body.action)
        }
      }
    } catch {
      Start-Sleep -Milliseconds 400
    }
  }
  Start-Sleep -Milliseconds 400
}
