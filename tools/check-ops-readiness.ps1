[CmdletBinding()]
param(
    [string]$BackupRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) 'runtime\backups'),
    [int]$MaxBackupAgeHours = 48,
    [switch]$RequireFreshBackup,
    [switch]$SkipCompose,
    [switch]$SkipBackupFreshness,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $ProjectRoot 'docker-compose.integration.yml'
$EnvFile = Join-Path $ProjectRoot '.env.integration'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result([string]$Name, [string]$Status, [string]$Detail = '') {
    $results.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail })
}

function Pass([string]$Name, [string]$Detail = '') {
    Add-Result $Name 'PASS' $Detail
    if (-not $Json) { Write-Host "PASS $Name$(if ($Detail) { " - $Detail" })" -ForegroundColor Green }
}

function Warn([string]$Name, [string]$Detail) {
    Add-Result $Name 'WARN' $Detail
    if (-not $Json) { Write-Host "WARN $Name - $Detail" -ForegroundColor Yellow }
}

function Fail([string]$Name, [string]$Detail) {
    Add-Result $Name 'FAIL' $Detail
    if (-not $Json) { Write-Host "FAIL $Name - $Detail" -ForegroundColor Red }
}

function Read-EnvValue([string]$Name) {
    if (-not (Test-Path -LiteralPath $EnvFile)) { return $null }
    $line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if ($line) { return $line.Substring($Name.Length + 1).Trim() }
    return $null
}

function Invoke-Health([string]$Name, [string]$Uri, [int]$ExpectedStatus = 200) {
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -TimeoutSec 10
        if ($response.StatusCode -eq $ExpectedStatus) {
            Pass $Name "HTTP $($response.StatusCode)"
        } else {
            Fail $Name "expected HTTP $ExpectedStatus, got $($response.StatusCode)"
        }
    } catch {
        Fail $Name $_.Exception.Message
    }
}

if (-not (Test-Path -LiteralPath $ProjectRoot)) { throw "Project root does not exist" }

if (-not $SkipCompose) {
    try {
        if (-not (Test-Path -LiteralPath $EnvFile)) { throw "missing .env.integration" }
        if (-not (Test-Path -LiteralPath $ComposeFile)) { throw "missing docker-compose.integration.yml" }
        & docker compose --env-file $EnvFile -f $ComposeFile config --quiet
        if ($LASTEXITCODE -eq 0) { Pass 'compose-config' } else { Fail 'compose-config' 'docker compose config failed' }
    } catch { Fail 'compose-config' $_.Exception.Message }

    try {
        $jsonLines = & docker compose --env-file $EnvFile -f $ComposeFile ps --format json 2>$null
        $services = @($jsonLines | ConvertFrom-Json)
        foreach ($expected in @('cpa', 'mock-upstream', 'new-api', 'postgres', 'redis')) {
            $service = $services | Where-Object { $_.Service -eq $expected } | Select-Object -First 1
            if (-not $service) { Fail "service-$expected" 'service is not listed'; continue }
            if ($service.State -ne 'running') { Fail "service-$expected" "state=$($service.State)"; continue }
            if ($service.Health -and $service.Health -ne 'healthy') { Fail "service-$expected" "health=$($service.Health)"; continue }
            Pass "service-$expected" 'running'
        }
    } catch { Fail 'compose-services' $_.Exception.Message }
}

Invoke-Health 'new-api-health' 'http://127.0.0.1:3000/api/status'
Invoke-Health 'cpa-health' 'http://127.0.0.1:8317/'
Invoke-Health 'mock-health' 'http://127.0.0.1:18080/healthz'


try {
    $callback = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:3000/api/user/epay/notify' -TimeoutSec 10
    $callbackText = if ($callback.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($callback.Content) } else { [string]$callback.Content }
    if ($callback.StatusCode -eq 200 -and $callbackText.Trim() -eq 'fail') {
        Pass 'local-payment-callback' 'HTTP 200 fail for unsigned empty request'
    } elseif ($callback.StatusCode -eq 200) {
        Warn 'local-payment-callback' 'HTTP 200 response was not the expected unsigned-request fail marker'
    } else {
        Fail 'local-payment-callback' "expected HTTP 200, got $($callback.StatusCode)"
    }
} catch { Fail 'local-payment-callback' $_.Exception.Message }
foreach ($port in @(3000, 8317, 18080)) {
    try {
        $open = Test-NetConnection -ComputerName 127.0.0.1 -Port $port -InformationLevel Quiet -WarningAction SilentlyContinue
        if ($open) { Pass "loopback-port-$port" 'reachable on 127.0.0.1' } else { Fail "loopback-port-$port" 'not reachable' }
    } catch { Fail "loopback-port-$port" $_.Exception.Message }
}

if (-not $SkipBackupFreshness) {
    try {
        $backupRootFull = [IO.Path]::GetFullPath($BackupRoot)
        if (-not (Test-Path -LiteralPath $backupRootFull)) {
            if ($RequireFreshBackup) { Fail 'backup-freshness' "backup root missing: $backupRootFull" } else { Warn 'backup-freshness' "backup root missing: $backupRootFull" }
        } else {
            $latest = Get-ChildItem -LiteralPath $backupRootFull -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $latest) {
                if ($RequireFreshBackup) { Fail 'backup-freshness' 'no backup directory found' } else { Warn 'backup-freshness' 'no backup directory found' }
            } else {
                $ageHours = ((Get-Date) - $latest.LastWriteTime).TotalHours
                $requiredFiles = @('manifest.txt', 'new-api.postgres.dump', 'redis.rdb', 'cpa-config.yaml')
                $missing = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $latest.FullName $_)) })
                if ($missing.Count -gt 0) {
                    Fail 'backup-contents' ("missing required backup artifacts: " + ($missing -join ', '))
                } elseif ($ageHours -le $MaxBackupAgeHours) {
                    Pass 'backup-freshness' ("latest backup age {0:N1}h" -f $ageHours)
                } elseif ($RequireFreshBackup) {
                    Fail 'backup-freshness' ("latest backup age {0:N1}h exceeds {1}h" -f $ageHours, $MaxBackupAgeHours)
                } else {
                    Warn 'backup-freshness' ("latest backup age {0:N1}h exceeds {1}h" -f $ageHours, $MaxBackupAgeHours)
                }
            }
        }
    } catch { Fail 'backup-freshness' $_.Exception.Message }
}

try {
    $ignored = @('.env.integration', 'runtime/cpa/config.yaml', 'runtime/backups', 'dev-docs')
    foreach ($path in $ignored) {
        & git -C $ProjectRoot check-ignore -q -- $path
        if ($LASTEXITCODE -eq 0) { Pass "ignored-$path" } else { Warn "ignored-$path" 'path is not ignored; review before staging' }
    }
} catch { Fail 'git-ignore-boundary' $_.Exception.Message }

if ($Json) {
    [pscustomobject]@{
        project_root = $ProjectRoot
        backup_root = [IO.Path]::GetFullPath($BackupRoot)
        max_backup_age_hours = $MaxBackupAgeHours
        results = @($results)
        failures = @($results | Where-Object status -eq 'FAIL').Count
        warnings = @($results | Where-Object status -eq 'WARN').Count
    } | ConvertTo-Json -Depth 5
} else {
    $failures = @($results | Where-Object status -eq 'FAIL').Count
    $warnings = @($results | Where-Object status -eq 'WARN').Count
    Write-Host "`nOps readiness summary: failures=$failures warnings=$warnings" -ForegroundColor Cyan
}

if (@($results | Where-Object status -eq 'FAIL').Count -gt 0) { exit 1 }
