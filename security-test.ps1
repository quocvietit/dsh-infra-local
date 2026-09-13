$ErrorActionPreference = "Continue"

Write-Host ""
Write-Host "========================================"
Write-Host " DeepSeek Harness Security Test"
Write-Host "========================================"
Write-Host ""

$Passed = 0
$Failed = 0

function Pass($Message) {
    $script:Passed++
    Write-Host "[PASS] $Message" -ForegroundColor Green
}

function Fail($Message) {
    $script:Failed++
    Write-Host "[FAIL] $Message" -ForegroundColor Red
}

function Info($Message) {
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

# ------------------------------------------------------------
# 1. Check containers
# ------------------------------------------------------------

Info "Checking containers..."

$dshRunning = docker inspect `
    -f '{{.State.Running}}' `
    deepseek-harness 2>$null

$proxyRunning = docker inspect `
    -f '{{.State.Running}}' `
    dsh-egress-proxy 2>$null

if ($dshRunning -eq "true") {
    Pass "DeepSeek Harness container is running"
}
else {
    Fail "DeepSeek Harness container is NOT running"
}

if ($proxyRunning -eq "true") {
    Pass "Egress proxy container is running"
}
else {
    Fail "Egress proxy container is NOT running"
}

Write-Host ""

# ------------------------------------------------------------
# 2. Check DSH networks
# ------------------------------------------------------------

Info "Checking DSH network isolation..."

$networkJson = docker inspect `
    deepseek-harness `
    --format '{{json .NetworkSettings.Networks}}'

Write-Host $networkJson

if ($networkJson -match "sandbox") {
    Pass "DSH is connected to sandbox network"
}
else {
    Fail "DSH is NOT connected to sandbox network"
}

if ($networkJson -match '"internet"') {
    Fail "DSH is directly connected to INTERNET network"
}
else {
    Pass "DSH is NOT directly connected to internet network"
}

Write-Host ""

# ------------------------------------------------------------
# 3. Allowed domain
# Change this to a domain that exists in allow-domains.txt
# ------------------------------------------------------------

$AllowedDomain = "github.com"

Info "Testing allowed domain: $AllowedDomain"

docker compose exec -T dsh `
    curl -sS -I `
    --connect-timeout 10 `
    "https://$AllowedDomain" `
    *> $null

if ($LASTEXITCODE -eq 0) {
    Pass "Allowed domain reachable through proxy: $AllowedDomain"
}
else {
    Fail "Allowed domain could NOT be reached: $AllowedDomain"
}

Write-Host ""

# ------------------------------------------------------------
# 4. Blocked domain
# Make sure this domain is NOT in allow-domains.txt
# ------------------------------------------------------------

$BlockedDomain = "google.com"

Info "Testing blocked domain through proxy: $BlockedDomain"

$result = docker compose exec -T dsh `
    curl -sS -I `
    --connect-timeout 10 `
    "https://$BlockedDomain" 2>&1

$resultText = $result -join "`n"

if (
    $resultText -match "403" -or
    $resultText -match "Access Denied" -or
    $resultText -match "ERR_ACCESS_DENIED"
) {
    Pass "Proxy blocked non-allowlisted domain: $BlockedDomain"
}
else {
    Fail "Blocked domain may be reachable: $BlockedDomain"
    Write-Host $resultText
}

Write-Host ""

# ------------------------------------------------------------
# 5. Proxy bypass test
# ------------------------------------------------------------

Info "Testing direct Internet bypass..."

docker compose exec -T dsh `
    curl `
    --noproxy "*" `
    --connect-timeout 5 `
    -sS `
    "https://$BlockedDomain" `
    *> $null

if ($LASTEXITCODE -ne 0) {
    Pass "Direct Internet bypass is blocked"
}
else {
    Fail "CRITICAL: Direct Internet bypass succeeded"
}

Write-Host ""

# ------------------------------------------------------------
# 6. Direct IP test
# ------------------------------------------------------------

$PublicIP = "1.1.1.1"

Info "Testing direct public IP connection: $PublicIP"

docker compose exec -T dsh `
    curl `
    --noproxy "*" `
    --connect-timeout 5 `
    -sS `
    "https://$PublicIP" `
    *> $null

if ($LASTEXITCODE -ne 0) {
    Pass "Direct public IP connection is blocked"
}
else {
    Fail "CRITICAL: DSH can connect directly to public IP"
}

Write-Host ""

# ------------------------------------------------------------
# 7. Node direct Internet test
# ------------------------------------------------------------

Info "Testing direct Internet using Node.js..."

$nodeResult = docker compose exec -T dsh `
    node -e "
const https = require('https');

const req = https.get(
  'https://google.com',
  { timeout: 5000 },
  res => {
    console.log('CONNECTED:' + res.statusCode);
    process.exit(10);
  }
);

req.on('timeout', () => {
  req.destroy();
});

req.on('error', err => {
  console.log('BLOCKED:' + err.message);
  process.exit(0);
});
" 2>&1

if ($LASTEXITCODE -eq 0 -and ($nodeResult -join "`n") -match "BLOCKED") {
    Pass "Node.js direct Internet connection is blocked"
}
else {
    Fail "CRITICAL: Node.js may have direct Internet access"
    Write-Host ($nodeResult -join "`n")
}

Write-Host ""

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

Write-Host "========================================"
Write-Host " Security Test Result"
Write-Host "========================================"

Write-Host "Passed : $Passed"
Write-Host "Failed : $Failed"

Write-Host ""

if ($Failed -eq 0) {

    Write-Host "SECURITY TEST PASSED" -ForegroundColor Green
    Write-Host ""
    Write-Host "Expected network model:"
    Write-Host ""
    Write-Host "DSH -> Squid -> Allowlist -> Internet"
    Write-Host "DSH -X-> Direct Internet"
    Write-Host "DSH -X-> Direct Public IP"
    Write-Host ""

    exit 0
}
else {

    Write-Host "SECURITY TEST FAILED" -ForegroundColor Red
    Write-Host ""
    Write-Host "Do NOT use the agent with sensitive source code until failures are fixed."

    exit 1
}