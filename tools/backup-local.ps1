[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$OutputDirectory,
    [switch]$ConfirmBackup
)

$ErrorActionPreference = "Stop"
if (-not $ConfirmBackup) {
    throw "备份会复制数据库、配置和认证文件，可能包含敏感信息。请显式传入 -ConfirmBackup。"
}

$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $ProjectRoot "docker-compose.integration.yml"
$EnvFile = Join-Path $ProjectRoot ".env.integration"
if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $ProjectRoot ("runtime\backups\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
}
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null

function Read-EnvValue([string]$Name) {
    $line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if (-not $line) { throw "Missing $Name in .env.integration" }
    return $line.Substring($Name.Length + 1).Trim()
}

$pgUser = Read-EnvValue "POSTGRES_USER"
$pgDb = Read-EnvValue "POSTGRES_DB"
$dumpPath = Join-Path $OutputDirectory "new-api.postgres.dump"
$manifestPath = Join-Path $OutputDirectory "manifest.txt"

Write-Host "Creating PostgreSQL dump..."
$dumpCommand = "docker compose --env-file `"$EnvFile`" -f `"$ComposeFile`" exec -T postgres pg_dump -U `"$pgUser`" -d `"$pgDb`" -Fc > `"$dumpPath`""
cmd.exe /d /c $dumpCommand
if ($LASTEXITCODE -ne 0) { throw "pg_dump failed" }

Copy-Item -LiteralPath (Join-Path $ProjectRoot "runtime\cpa\config.yaml") -Destination (Join-Path $OutputDirectory "cpa-config.yaml") -Force
if (Test-Path -LiteralPath (Join-Path $ProjectRoot "runtime\cpa\auths")) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "runtime\cpa\auths") -Destination (Join-Path $OutputDirectory "cpa-auths") -Recurse -Force
}
if (Test-Path -LiteralPath (Join-Path $ProjectRoot "runtime\new-api\data")) {
    Copy-Item -LiteralPath (Join-Path $ProjectRoot "runtime\new-api\data") -Destination (Join-Path $OutputDirectory "new-api-data") -Recurse -Force
}

@(
    "created_at=$(Get-Date -Format o)",
    "project_root=$ProjectRoot",
    "compose_file=$ComposeFile",
    "database=$pgDb",
    "includes_database_dump=true",
    "includes_cpa_config=true",
    "includes_cpa_auths=$(Test-Path (Join-Path $ProjectRoot 'runtime\cpa\auths'))"
) | Set-Content -LiteralPath $manifestPath -Encoding utf8

Write-Host "Backup created at: $OutputDirectory" -ForegroundColor Green
Write-Host "Treat this directory as sensitive; it may contain credentials." -ForegroundColor Yellow
