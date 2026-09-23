[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ClientApiKey,
    [int]$Seconds = 2
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $ProjectRoot "docker-compose.integration.yml"
$EnvFile = Join-Path $ProjectRoot ".env.integration"
$Body = '{"model":"mock-timeout","messages":[{"role":"user","content":"timeout verification"}]}'

try {
    $env:RELAY_RESPONSE_HEADER_TIMEOUT = [string]$Seconds
    docker compose --env-file $EnvFile -f $ComposeFile up -d new-api | Out-Host
    Start-Sleep -Seconds 5
    $response = (& curl.exe -sS -i --max-time 12 -H "Authorization: Bearer $ClientApiKey" -H "Content-Type: application/json" -d $Body http://localhost:3000/v1/chat/completions 2>$null) -join "`n"
    if ($response -match "HTTP/1\.1 500" -and $response -match "do_request_failed") {
        Write-Host "PASS timeout-chain - New API returned controlled timeout error" -ForegroundColor Green
    } else {
        Write-Host "FAIL timeout-chain - expected HTTP 500 with do_request_failed" -ForegroundColor Red
        Write-Output $response
        exit 1
    }
} finally {
    Remove-Item Env:RELAY_RESPONSE_HEADER_TIMEOUT -ErrorAction SilentlyContinue
    docker compose --env-file $EnvFile -f $ComposeFile up -d new-api | Out-Host
}
