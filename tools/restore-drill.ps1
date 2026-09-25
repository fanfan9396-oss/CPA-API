[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BackupDirectory,
    [switch]$KeepDatabase
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$ComposeFile = Join-Path $ProjectRoot "docker-compose.integration.yml"
$EnvFile = Join-Path $ProjectRoot ".env.integration"
$BackupDirectory = [IO.Path]::GetFullPath($BackupDirectory)
$AllowedBackupRoot = [IO.Path]::GetFullPath((Join-Path $ProjectRoot "runtime\backups"))
$relativeBackupPath = [IO.Path]::GetRelativePath($AllowedBackupRoot, $BackupDirectory)
if ($relativeBackupPath -eq "." -or $relativeBackupPath.StartsWith(".." + [IO.Path]::DirectorySeparatorChar) -or [IO.Path]::IsPathRooted($relativeBackupPath)) {
    throw "BackupDirectory must be a child directory of runtime/backups"
}
if ($relativeBackupPath -notmatch '^[A-Za-z0-9._-]+$') {
    throw "Backup directory name may contain only letters, digits, dot, underscore, and hyphen"
}
$DumpPath = Join-Path $BackupDirectory "new-api.postgres.dump"
$RedisDumpPath = Join-Path $BackupDirectory "redis.rdb"

if (-not (Test-Path -LiteralPath $EnvFile)) { throw "Missing $EnvFile" }
if (-not (Test-Path -LiteralPath $DumpPath)) { throw "Missing PostgreSQL dump: $DumpPath" }
if (-not (Test-Path -LiteralPath $RedisDumpPath)) { throw "Missing Redis RDB snapshot: $RedisDumpPath" }

function Read-EnvValue([string]$Name) {
    $line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match "^$Name=" } | Select-Object -First 1
    if (-not $line) { throw "Missing $Name in .env.integration" }
    return $line.Substring($Name.Length + 1).Trim()
}

$pgUser = Read-EnvValue "POSTGRES_USER"
$pgDb = Read-EnvValue "POSTGRES_DB"
$stamp = Get-Date -Format "yyyyMMddHHmmss"
$restoreDb = "relay_restore_drill_$stamp"

function Invoke-ComposePsql([string]$Database, [string]$Sql) {
    & docker compose --env-file $EnvFile -f $ComposeFile exec -T postgres psql -U $pgUser -d $Database -v ON_ERROR_STOP=1 -c $Sql
    if ($LASTEXITCODE -ne 0) { throw "psql command failed for database $Database" }
}

$created = $false
try {
    Write-Host "Creating isolated restore database $restoreDb..."
    Invoke-ComposePsql "postgres" "CREATE DATABASE $restoreDb OWNER $pgUser;"
    $created = $true

    Write-Host "Restoring $DumpPath..."
    $restoreCommand = "docker compose --env-file `"$EnvFile`" -f `"$ComposeFile`" exec -T postgres pg_restore -U `"$pgUser`" -d `"$restoreDb`" --exit-on-error < `"$DumpPath`""
    cmd.exe /d /c $restoreCommand
    if ($LASTEXITCODE -ne 0) { throw "pg_restore failed" }

    $tableCount = (& docker compose --env-file $EnvFile -f $ComposeFile exec -T postgres psql -U $pgUser -d $restoreDb -At -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';").Trim()
    if ($LASTEXITCODE -ne 0) { throw "table count query failed" }
    $userCount = (& docker compose --env-file $EnvFile -f $ComposeFile exec -T postgres psql -U $pgUser -d $restoreDb -At -c "SELECT CASE WHEN to_regclass('public.users') IS NULL THEN 'n/a' ELSE (SELECT count(*)::text FROM users) END;").Trim()
    if ($LASTEXITCODE -ne 0) { throw "users query failed" }

    Write-Host "Validating Redis RDB snapshot..."
    & docker run --rm --mount "type=bind,source=$BackupDirectory,target=/backup,readonly" redis:7 redis-check-rdb /backup/redis.rdb
    if ($LASTEXITCODE -ne 0) { throw "Redis RDB validation failed" }

    Write-Host "PASS restore-drill - public_tables=$tableCount users=$userCount redis_rdb=valid" -ForegroundColor Green
    if ($KeepDatabase) {
        Write-Host "Temporary database kept: $restoreDb" -ForegroundColor Yellow
        $created = $false
    }
} finally {
    if ($created) {
        Write-Host "Removing isolated restore database $restoreDb..."
        Invoke-ComposePsql "postgres" "DROP DATABASE $restoreDb;"
    }
}
