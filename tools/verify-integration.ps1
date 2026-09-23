[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClientApiKey,
    [string]$CpaApiKey,
    [switch]$SkipStreaming
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$EnvFile = Join-Path $ProjectRoot ".env.integration"
$CpaConfig = Join-Path $ProjectRoot "runtime\cpa\config.yaml"

function Read-LocalValue([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $line = Get-Content -LiteralPath $Path | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if ($line) { return $line.Substring($Name.Length + 1).Trim() }
    return $null
}

if ([string]::IsNullOrWhiteSpace($CpaApiKey)) {
    $CpaApiKey = Read-LocalValue $EnvFile "CPA_API_KEY"
}
if ([string]::IsNullOrWhiteSpace($CpaApiKey)) {
    $match = Select-String -LiteralPath $CpaConfig -Pattern '^\s*-\s*([^\s#]+)\s*$' | Select-Object -First 1
    if ($match) { $CpaApiKey = $match.Matches[0].Groups[1].Value }
}
if ([string]::IsNullOrWhiteSpace($CpaApiKey)) { throw "CpaApiKey is required or must exist in .env.integration/runtime/cpa/config.yaml" }

$passed = 0
$failed = 0

function Pass([string]$Name, [string]$Detail = "") {
    $script:passed++
    if ($Detail) { Write-Host "PASS $Name - $Detail" -ForegroundColor Green }
    else { Write-Host "PASS $Name" -ForegroundColor Green }
}

function Fail([string]$Name, [string]$Detail) {
    $script:failed++
    Write-Host "FAIL $Name - $Detail" -ForegroundColor Red
}

function Get-StatusCode([scriptblock]$Request) {
    try {
        $response = & $Request
        return [int]$response.StatusCode
    } catch {
        if ($_.Exception.Response) { return [int]$_.Exception.Response.StatusCode.value__ }
        return 0
    }
}

function Invoke-JsonRequest([string]$Uri, [hashtable]$Headers, [string]$Body) {
    return Invoke-RestMethod -Uri $Uri -Method Post -Headers $Headers -ContentType "application/json" -Body $Body
}

try {
    $health = Invoke-RestMethod -Uri "http://localhost:3000/api/status" -Method Get
    if ($health.success -eq $true) { Pass "new-api-health" } else { Fail "new-api-health" "success was not true" }
} catch { Fail "new-api-health" $_.Exception.Message }

try {
    $health = Invoke-RestMethod -Uri "http://localhost:18080/healthz" -Method Get
    if ($health.status -eq "ok") { Pass "mock-health" } else { Fail "mock-health" "status was not ok" }
} catch { Fail "mock-health" $_.Exception.Message }

try {
    $headers = @{ Authorization = "Bearer $CpaApiKey" }
    $models = Invoke-RestMethod -Uri "http://localhost:8317/v1/models" -Headers $headers -Method Get
    $modelIds = @($models.data | ForEach-Object { $_.id })
    $requiredModels = @("mock-chat", "mock-error-429", "mock-error-500", "mock-retry-once", "mock-retry-always")
    $missingModels = @($requiredModels | Where-Object { $modelIds -notcontains $_ })
    if ($missingModels.Count -eq 0) { Pass "cpa-model-discovery" ($requiredModels -join ", ") } else { Fail "cpa-model-discovery" ("missing: " + ($missingModels -join ", ")) }
} catch { Fail "cpa-model-discovery" $_.Exception.Message }

$clientHeaders = @{ Authorization = "Bearer $ClientApiKey" }
$body = @{ model = "mock-chat"; messages = @(@{ role = "user"; content = "verification" }) } | ConvertTo-Json -Depth 8
try {
    $result = Invoke-JsonRequest "http://localhost:3000/v1/chat/completions" $clientHeaders $body
    if ($result.choices[0].message.content) { Pass "new-api-non-stream" "HTTP 200" } else { Fail "new-api-non-stream" "missing assistant content" }
} catch { Fail "new-api-non-stream" $_.Exception.Message }

Invoke-RestMethod -Uri "http://localhost:18080/debug/reset" -Method Post | Out-Null
$retryBaseline = Invoke-RestMethod -Uri "http://localhost:18080/debug/counters" -Method Get
$retryOnceBody = @{ model = "mock-retry-once"; messages = @(@{ role = "user"; content = "retry once verification" }) } | ConvertTo-Json -Depth 8
try {
    $retryOnceResult = Invoke-JsonRequest "http://localhost:3000/v1/chat/completions" $clientHeaders $retryOnceBody
    if ($retryOnceResult.choices[0].message.content) { Pass "new-api-retry-once" } else { Fail "new-api-retry-once" "missing assistant content" }
} catch { Fail "new-api-retry-once" $_.Exception.Message }

$retryAlwaysBody = @{ model = "mock-retry-always"; messages = @(@{ role = "user"; content = "retry always verification" }) } | ConvertTo-Json -Depth 8
$retryAlwaysStatus = Get-StatusCode { Invoke-WebRequest -Uri "http://localhost:3000/v1/chat/completions" -Method Post -Headers $clientHeaders -ContentType "application/json" -Body $retryAlwaysBody -UseBasicParsing }
if ($retryAlwaysStatus -eq 500) { Pass "new-api-retry-always" } else { Fail "new-api-retry-always" "expected 500, got $retryAlwaysStatus" }

$retryAfter = Invoke-RestMethod -Uri "http://localhost:18080/debug/counters" -Method Get
$onceDelta = [int]($retryAfter.counters.'mock-retry-once' - $retryBaseline.counters.'mock-retry-once')
$alwaysDelta = [int]($retryAfter.counters.'mock-retry-always' - $retryBaseline.counters.'mock-retry-always')
if ($onceDelta -ge 2) { Pass "cpa-retry-attempts-once" "attempts=$onceDelta" } else { Fail "cpa-retry-attempts-once" "expected at least 2 attempts, got $onceDelta" }
if ($alwaysDelta -ge 2) { Pass "cpa-retry-attempts-always" "attempts=$alwaysDelta" } else { Fail "cpa-retry-attempts-always" "expected at least 2 attempts, got $alwaysDelta" }

foreach ($fault in @(@{ Model = "mock-error-429"; Expected = 429 }, @{ Model = "mock-error-500"; Expected = 500 })) {
    try {
        $faultBody = @{ model = $fault.Model; messages = @(@{ role = "user"; content = "gateway fault verification" }) } | ConvertTo-Json -Depth 8
        $status = Get-StatusCode { Invoke-WebRequest -Uri "http://localhost:3000/v1/chat/completions" -Method Post -Headers $clientHeaders -ContentType "application/json" -Body $faultBody -UseBasicParsing }
        if ($status -eq $fault.Expected) { Pass "new-api-upstream-$($fault.Expected)" } else { Fail "new-api-upstream-$($fault.Expected)" "expected $($fault.Expected), got $status" }
    } catch { Fail "new-api-upstream-$($fault.Expected)" $_.Exception.Message }
}

if (-not $SkipStreaming) {
    try {
        $streamBody = '{"model":"mock-chat","messages":[{"role":"user","content":"stream verification"}],"stream":true}'
        $streamOutput = (& curl.exe -sS -N --max-time 30 -H "Authorization: Bearer $ClientApiKey" -H "Content-Type: application/json" -d $streamBody http://localhost:3000/v1/chat/completions 2>$null) -join "`n"
        if ($streamOutput -match 'data:' -and $streamOutput -match '\[DONE\]') { Pass "new-api-stream" } else { Fail "new-api-stream" "missing SSE data or DONE marker" }
    } catch { Fail "new-api-stream" $_.Exception.Message }
}

try {
    $unauthorizedStatus = Get-StatusCode { Invoke-WebRequest -Uri "http://localhost:3000/v1/chat/completions" -Method Post -ContentType "application/json" -Body $body -UseBasicParsing }
    if ($unauthorizedStatus -eq 401) { Pass "new-api-unauthorized" } else { Fail "new-api-unauthorized" "expected 401, got $unauthorizedStatus" }
} catch { Fail "new-api-unauthorized" $_.Exception.Message }

$mockHeaders = @{ Authorization = "Bearer mock-upstream-key" }
foreach ($model in @("mock-error-429", "mock-error-500")) {
    try {
        $errorBody = @{ model = $model; messages = @(@{ role = "user"; content = "error verification" }) } | ConvertTo-Json -Depth 8
        $status = Get-StatusCode { Invoke-WebRequest -Uri "http://localhost:18080/v1/chat/completions" -Method Post -Headers $mockHeaders -ContentType "application/json" -Body $errorBody -UseBasicParsing }
        $expected = if ($model -eq "mock-error-429") { 429 } else { 500 }
        if ($status -eq $expected) { Pass "mock-$expected" } else { Fail "mock-$expected" "expected $expected, got $status" }
    } catch { Fail "mock-$model" $_.Exception.Message }
}

Write-Host "`nVerification summary: $passed passed, $failed failed" -ForegroundColor Cyan
if ($failed -gt 0) { exit 1 }



