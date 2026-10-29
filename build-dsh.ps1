# ============================================================
# build-dsh.ps1
#
# Build DeepSeek Harness inside Docker
# Then create the final runtime image.
#
# Requirements:
#   - Git
#   - Docker Desktop
#
# Output:
#   ds-web:<IMAGE_VERSION>
# ============================================================

$ErrorActionPreference = "Stop"


# ============================================================
# CONFIGURATION
# ============================================================

$IMAGE_NAME = "dsh-web"

# Change version here
$IMAGE_VERSION = "1.3.0"

$PROJECT_ROOT = $PSScriptRoot

$DSH_SOURCE = Join-Path `
    $PROJECT_ROOT `
    "deepseek-harness"

$DOCKERFILE = Join-Path `
    $PROJECT_ROOT `
    "Dockerfile"

$FULL_IMAGE = "${IMAGE_NAME}:${IMAGE_VERSION}"


# ============================================================
# FUNCTION
# ============================================================

function Command-Exists {
    param(
        [string]$Command
    )

    return $null -ne (
        Get-Command `
            $Command `
            -ErrorAction SilentlyContinue
    )
}


# ============================================================
# HEADER
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " DeepSeek Harness Docker Builder" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Project root : $PROJECT_ROOT"
Write-Host "DSH source   : $DSH_SOURCE"
Write-Host "Dockerfile   : $DOCKERFILE"
Write-Host "Image        : $FULL_IMAGE"
Write-Host ""


# ============================================================
# VALIDATE VERSION
# ============================================================

if ([string]::IsNullOrWhiteSpace($IMAGE_VERSION)) {
    throw "IMAGE_VERSION is empty."
}

if ($IMAGE_VERSION -notmatch '^\d+\.\d+\.\d+$') {
    throw "IMAGE_VERSION must use semantic version format, e.g. 1.2.5"
}


# ============================================================
# CHECK DSH SOURCE
# ============================================================

Write-Host "Checking DSH source..." -ForegroundColor Yellow

if (-not (Test-Path $DSH_SOURCE)) {
    throw "DSH source directory not found: $DSH_SOURCE"
}

$packageJson = Join-Path `
    $DSH_SOURCE `
    "package.json"

if (-not (Test-Path $packageJson)) {
    throw "DSH package.json not found: $packageJson"
}

$lockFile = Join-Path `
    $DSH_SOURCE `
    "pnpm-lock.yaml"

if (-not (Test-Path $lockFile)) {
    throw "DSH pnpm-lock.yaml not found: $lockFile"
}

Write-Host "DSH source : OK" -ForegroundColor Green


# ============================================================
# CHECK GIT
# ============================================================

Write-Host ""
Write-Host "Checking Git..." -ForegroundColor Yellow

if (-not (Command-Exists "git")) {
    throw "Git is not installed or not available in PATH."
}

$gitVersion = git --version

Write-Host "$gitVersion : OK" -ForegroundColor Green


# ============================================================
# CHECK DOCKER
# ============================================================

Write-Host ""
Write-Host "Checking Docker..." -ForegroundColor Yellow

if (-not (Command-Exists "docker")) {
    throw "Docker is not installed or not available in PATH."
}

# Do not use "docker info".
# Docker Desktop can print warnings to stderr and PowerShell
# can treat them as NativeCommandError.

$dockerVersion = docker version --format "{{.Server.Version}}" 2>$null

if ($LASTEXITCODE -ne 0) {
    throw "Docker daemon is not running. Start Docker Desktop first."
}

Write-Host "Docker Engine $dockerVersion : OK" -ForegroundColor Green


# ============================================================
# CHECK DOCKERFILE
# ============================================================

Write-Host ""
Write-Host "Checking Dockerfile..." -ForegroundColor Yellow

if (-not (Test-Path $DOCKERFILE)) {
    throw "Dockerfile not found: $DOCKERFILE"
}

Write-Host "Dockerfile : OK" -ForegroundColor Green


# ============================================================
# BUILD
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Building DSH inside Docker" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Image: $FULL_IMAGE" -ForegroundColor Yellow
Write-Host ""

docker build `
    --build-arg "DSH_COMMIT_HASH=0000000" `
    -t $FULL_IMAGE `
    -f $DOCKERFILE `
    $PROJECT_ROOT

if ($LASTEXITCODE -ne 0) {
    throw "Docker image build failed."
}

Write-Host ""
Write-Host "Docker build : OK" -ForegroundColor Green


# ============================================================
# VERIFY IMAGE
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Verifying image" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host ""


# ------------------------------------------------------------
# Node
# ------------------------------------------------------------

Write-Host "Checking Node.js..." -ForegroundColor Yellow

$nodeVersion = docker run --rm `
    --entrypoint node `
    $FULL_IMAGE `
    --version

if ($LASTEXITCODE -ne 0) {
    throw "Node.js verification failed."
}

Write-Host "Node.js $nodeVersion : OK" -ForegroundColor Green


# ------------------------------------------------------------
# Java 17
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking Java 17..." -ForegroundColor Yellow

$env:DOCKER_CLI_HINTS="false"
$null = docker run --rm `
    --entrypoint /usr/local/bin/use-java17 `
    $FULL_IMAGE `
    java -version 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Java 17 verification failed."
}

Write-Host "Java 17 : OK" -ForegroundColor Green


# ------------------------------------------------------------
# Java 21
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking Java 21..." -ForegroundColor Yellow

$null = docker run --rm `
    --entrypoint /usr/local/bin/use-java21 `
    $FULL_IMAGE `
    java -version 2>&1

if ($LASTEXITCODE -ne 0) {
    throw "Java 21 verification failed."
}

Write-Host "Java 21 : OK" -ForegroundColor Green


# ------------------------------------------------------------
# Maven
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking Maven..." -ForegroundColor Yellow

docker run --rm `
    --entrypoint mvn `
    $FULL_IMAGE `
    -version

if ($LASTEXITCODE -ne 0) {
    throw "Maven verification failed."
}

Write-Host "Maven : OK" -ForegroundColor Green


# ------------------------------------------------------------
# Chromium
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking Chromium..." -ForegroundColor Yellow

docker run --rm `
    --entrypoint chromium `
    $FULL_IMAGE `
    --version

if ($LASTEXITCODE -ne 0) {

    docker run --rm `
        --entrypoint chromium-browser `
        $FULL_IMAGE `
        --version

    if ($LASTEXITCODE -ne 0) {
        throw "Chromium verification failed."
    }
}

Write-Host "Chromium : OK" -ForegroundColor Green


# ------------------------------------------------------------
# CodeGraph
# ------------------------------------------------------------

Write-Host ""
Write-Host "Checking CodeGraph..." -ForegroundColor Yellow

docker run --rm `
    --entrypoint codegraph `
    $FULL_IMAGE `
    --version

if ($LASTEXITCODE -ne 0) {
    throw "CodeGraph verification failed."
}

Write-Host "CodeGraph : OK" -ForegroundColor Green


# ============================================================
# IMAGE SIZE
# ============================================================

Write-Host ""
Write-Host "Checking image size..." -ForegroundColor Yellow

$imageSize = docker image inspect `
    $FULL_IMAGE `
    --format "{{.Size}}"

if ($LASTEXITCODE -eq 0) {

    $imageSizeGB = [Math]::Round(
        [double]$imageSize / 1GB,
        2
    )

    Write-Host "Image size: ${imageSizeGB} GB"
}


# ============================================================
# FINAL
# ============================================================

Write-Host ""
Write-Host "============================================================" -ForegroundColor Green
Write-Host " BUILD SUCCESS" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
Write-Host ""

Write-Host "Image:" -ForegroundColor Cyan
Write-Host "  $FULL_IMAGE"

Write-Host ""
Write-Host "Run:" -ForegroundColor Cyan
Write-Host "  docker compose up -d"

Write-Host ""
Write-Host "Inspect:" -ForegroundColor Cyan
Write-Host "  docker image inspect $FULL_IMAGE"

Write-Host ""