[CmdletBinding()]
param(
    [switch]$RequireInviteMode
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $ProjectRoot "docker-compose.integration.yml"
$EnvFile = Join-Path $ProjectRoot ".env.integration"
$composeArgs = @("compose", "--env-file", $EnvFile, "-f", $ComposeFile)
$technicalFailures = 0
$warnings = 0

function Pass([string]$Name, [string]$Detail = "") {
    if ($Detail) { Write-Host "PASS $Name - $Detail" -ForegroundColor Green }
    else { Write-Host "PASS $Name" -ForegroundColor Green }
}
function Warn([string]$Name, [string]$Detail) {
    $script:warnings++
    Write-Host "WARN $Name - $Detail" -ForegroundColor Yellow
}
function Fail([string]$Name, [string]$Detail) {
    $script:technicalFailures++
    Write-Host "FAIL $Name - $Detail" -ForegroundColor Red
}

if (-not (Test-Path -LiteralPath $EnvFile)) { throw "Missing $EnvFile" }
if (-not (Test-Path -LiteralPath $ComposeFile)) { throw "Missing $ComposeFile" }

try {
    & docker @composeArgs config --quiet
    if ($LASTEXITCODE -eq 0) { Pass "compose-config" } else { Fail "compose-config" "docker compose config failed" }
} catch { Fail "compose-config" $_.Exception.Message }

try {
    $json = & docker @composeArgs ps --format json 2>$null
    $services = @($json | ConvertFrom-Json)
    $expected = @("cpa", "mock-upstream", "new-api", "postgres", "redis")
    foreach ($name in $expected) {
        $service = $services | Where-Object { $_.Service -eq $name } | Select-Object -First 1
        if (-not $service) { Fail "service-$name" "service is not listed"; continue }
        if ($service.State -ne "running") { Fail "service-$name" "state=$($service.State)"; continue }
        if ($name -in @("postgres", "redis") -and $service.Health -and $service.Health -ne "healthy") {
            Fail "service-$name" "health=$($service.Health)"; continue
        }
        Pass "service-$name" "running"
    }
} catch { Fail "compose-services" $_.Exception.Message }

foreach ($probe in @(
    @{ Name = "new-api-health"; Uri = "http://127.0.0.1:3000/api/status" },
    @{ Name = "cpa-root"; Uri = "http://127.0.0.1:8317/" },
    @{ Name = "mock-health"; Uri = "http://127.0.0.1:18080/healthz" }
)) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $probe.Uri -TimeoutSec 10
        if ($response.StatusCode -eq 200) { Pass $probe.Name "HTTP 200" } else { Fail $probe.Name "HTTP $($response.StatusCode)" }
    } catch { Fail $probe.Name $_.Exception.Message }
}

try {
    $status = Invoke-RestMethod -Uri "http://127.0.0.1:3000/api/status" -TimeoutSec 10
    $register = [bool]$status.data.register_enabled
    $passwordRegister = [bool]$status.data.password_register_enabled
    $emailVerification = [bool]$status.data.email_verification
    $turnstile = [bool]$status.data.turnstile_check
    if ($RequireInviteMode -and ($register -or $passwordRegister)) {
        Fail "invite-mode" "registration remains enabled"
    } elseif ($register -or $passwordRegister) {
        Warn "invite-mode" "registration is enabled in local runtime; do not expose this stack to a team/public network"
    } else {
        Pass "invite-mode" "registration disabled"
    }
    if (-not $emailVerification) { Warn "email-verification" "disabled" } else { Pass "email-verification" "enabled" }
    if (-not $turnstile) { Warn "turnstile" "disabled" } else { Pass "turnstile" "enabled" }
} catch { Fail "registration-status" $_.Exception.Message }

try {
    $redisPasswordLine = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match '^REDIS_PASSWORD=' } | Select-Object -First 1
    if (-not $redisPasswordLine) { throw "REDIS_PASSWORD is missing" }
    $redisPassword = $redisPasswordLine.Substring(15).Trim()
    $persistence = (& docker exec relay-redis redis-cli -a $redisPassword --no-auth-warning CONFIG GET appendonly save 2>$null) -join " "
    if ($LASTEXITCODE -ne 0) { throw "redis-cli failed" }
    if ($persistence -match 'appendonly\s+no') {
        Warn "redis-persistence" "AOF disabled; current local stack only has RDB save rules and is not a production recovery decision"
    } else { Pass "redis-persistence" "AOF enabled or not reported disabled" }
} catch { Fail "redis-persistence" $_.Exception.Message }

try {
    $ignored = @(".env.integration", "runtime/cpa/config.yaml", "runtime/backups", "dev-docs")
    foreach ($path in $ignored) {
        & git check-ignore -q -- $path
        if ($LASTEXITCODE -eq 0) { Pass "ignored-$path" } else { Warn "ignored-$path" "path is not ignored; review before staging" }
    }
} catch { Fail "git-ignore-boundary" $_.Exception.Message }

Write-Host "`nLocal readiness summary: technical_failures=$technicalFailures warnings=$warnings" -ForegroundColor Cyan
if ($technicalFailures -gt 0) { exit 1 }
