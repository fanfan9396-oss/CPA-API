[CmdletBinding()]
param(
    [string]$BaseUrl = 'https://api.20280810.xyz'
)

$ErrorActionPreference = 'Stop'
$BaseUrl = $BaseUrl.TrimEnd('/')
$checks = [System.Collections.Generic.List[object]]::new()

function Pass([string]$Name, [string]$Detail) { $checks.Add([pscustomobject]@{name=$Name; status='PASS'; detail=$Detail}); Write-Host "PASS $Name - $Detail" -ForegroundColor Green }
function Warn([string]$Name, [string]$Detail) { $checks.Add([pscustomobject]@{name=$Name; status='WARN'; detail=$Detail}); Write-Host "WARN $Name - $Detail" -ForegroundColor Yellow }
function Fail([string]$Name, [string]$Detail) { $checks.Add([pscustomobject]@{name=$Name; status='FAIL'; detail=$Detail}); Write-Host "FAIL $Name - $Detail" -ForegroundColor Red }

function Get-Json([string]$Uri) {
    return Invoke-RestMethod -Uri $Uri -Method Get -TimeoutSec 15
}

try {
    $status = Get-Json "$BaseUrl/api/status"
    if ($status.success -ne $true) { throw 'status endpoint returned success=false' }
    Pass 'https-status' 'status endpoint returned success=true'

    $data = $status.data
    if ($data.server_address -eq $BaseUrl) { Pass 'server-address' $data.server_address } else { Fail 'server-address' "expected $BaseUrl, got $($data.server_address)" }
    if ($data.quota_display_type -eq 'USD' -and $data.display_in_currency -eq $true) { Pass 'quota-display' 'Wallet/quota display is USD' } else { Fail 'quota-display' 'expected USD quota display' }
    if ([decimal]$data.price -eq 1 -and [decimal]$data.usd_exchange_rate -eq 7.3) { Pass 'pricing-rule' 'Price=1, USDExchangeRate=7.3' } else { Fail 'pricing-rule' "price=$($data.price), usd_exchange_rate=$($data.usd_exchange_rate)" }
} catch { Fail 'https-status' $_.Exception.Message }

try {
    $callback = Invoke-WebRequest -UseBasicParsing -Uri "$BaseUrl/api/user/epay/notify" -TimeoutSec 15
    $body = if ($callback.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($callback.Content) } else { [string]$callback.Content }
    if ($callback.StatusCode -eq 200 -and $body.Trim() -eq 'fail') { Pass 'payment-callback-reachability' 'unsigned empty callback is rejected with HTTP 200 fail' } else { Fail 'payment-callback-reachability' "HTTP=$($callback.StatusCode) body=$($body.Trim())" }
} catch { Fail 'payment-callback-reachability' $_.Exception.Message }

Warn 'real-payment' 'not executed; requires ZPAY Alipay channel enabled and explicit live ¥1 authorization'
Warn 'merchant-config' 'pid/key/PayAddress are not inspected or printed by this script'

$failures = @($checks | Where-Object status -eq 'FAIL').Count
$warnings = @($checks | Where-Object status -eq 'WARN').Count
Write-Host "`nPayment preflight summary: failures=$failures warnings=$warnings" -ForegroundColor Cyan
if ($failures -gt 0) { exit 1 }

