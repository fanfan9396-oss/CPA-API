[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [datetime]$Start,
    [Parameter(Mandatory = $true)]
    [datetime]$End,
    [string]$ProviderCostCsv,
    [string]$DatabaseUrl = $env:RECONCILIATION_SQL_DSN,
    [string]$PsqlPath = 'psql'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($DatabaseUrl)) {
    throw 'Set RECONCILIATION_SQL_DSN or pass -DatabaseUrl. Do not put credentials in this script.'
}
if ($End -le $Start) { throw 'End must be later than Start.' }

$startEpoch = [DateTimeOffset]$Start.ToUniversalTime()
$endEpoch = [DateTimeOffset]$End.ToUniversalTime()
$start = $startEpoch.ToUnixTimeSeconds()
$end = $endEpoch.ToUnixTimeSeconds()

function Invoke-Scalar([string]$Sql) {
    $result = & $PsqlPath $DatabaseUrl --tuples-only --no-align --field-separator '|' --command $Sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $($result -join ' ')" }
    return ($result -join '').Trim()
}

function Convert-Decimal([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return [decimal]0 }
    return [decimal]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture)
}

$topup = Invoke-Scalar @"
SELECT COALESCE(SUM(money),0)::text || '|' || COALESCE(SUM(credited_quota),0)::text || '|' || COUNT(*)::text
FROM top_ups
WHERE status = 'success' AND complete_time >= $start AND complete_time < $end;
"@
$usage = Invoke-Scalar @"
SELECT COUNT(*)::text || '|' || COALESCE(SUM(quota),0)::text || '|' || COALESCE(SUM(prompt_tokens + completion_tokens),0)::text
FROM logs
WHERE type = 2 AND created_at >= $start AND created_at < $end;
"@
$topupFields = $topup -split '\|'
$usageFields = $usage -split '\|'

$providerCostUsd = $null
$providerCostStatus = 'unreconciled'
if ($ProviderCostCsv) {
    if (-not (Test-Path -LiteralPath $ProviderCostCsv)) { throw "Provider cost CSV not found: $ProviderCostCsv" }
    $rows = Import-Csv -LiteralPath $ProviderCostCsv
    $providerCostUsd = [decimal]0
    foreach ($row in $rows) {
        if (-not $row.date -or -not $row.provider -or -not $row.cost_usd) { throw 'Provider CSV requires date, provider, cost_usd columns.' }
        $date = [datetime]::Parse($row.date).ToUniversalTime()
        if ($date -ge $Start.ToUniversalTime() -and $date -lt $End.ToUniversalTime()) {
            $providerCostUsd += Convert-Decimal $row.cost_usd
        }
    }
    $providerCostStatus = 'provided_external_csv'
}

$report = [ordered]@{
    period_start_utc = $startEpoch.ToString('o')
    period_end_utc = $endEpoch.ToString('o')
    revenue_cny = Convert-Decimal $topupFields[0]
    wallet_credited_quota_units = [int64]$topupFields[1]
    successful_topup_count = [int64]$topupFields[2]
    wallet_consumed_quota_units = [int64]$usageFields[1]
    consume_request_count = [int64]$usageFields[0]
    usage_token_count = [int64]$usageFields[2]
    provider_cost_usd = $providerCostUsd
    provider_cost_status = $providerCostStatus
    reconciliation_status = if ($providerCostStatus -eq 'unreconciled') { 'partial_unreconciled' } else { 'reported' }
    note = 'Wallet quota and provider cost are different ledgers; missing provider bill is never inferred from Wallet usage.'
}
$report | ConvertTo-Json -Depth 4
