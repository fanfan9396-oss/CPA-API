[CmdletBinding()]
param(
    [string]$Drive = 'C',
    [double]$WarnFreeGB = 30,
    [double]$BlockFreeGB = 20,
    [double]$WarnCacheGB = 5,
    [double]$BlockCacheGB = 8,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
$results = [System.Collections.Generic.List[object]]::new()

function Add-Result([string]$Name, [string]$Status, [string]$Detail) {
    $results.Add([pscustomobject]@{ name = $Name; status = $Status; detail = $Detail })
    if (-not $Json) {
        $color = if ($Status -eq 'PASS') { 'Green' } elseif ($Status -eq 'WARN') { 'Yellow' } elseif ($Status -eq 'FAIL') { 'Red' } else { 'Cyan' }
        Write-Host ("{0} {1} - {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
    }
}

function Size-ToBytes([string]$Text) {
    if ($Text -match '^\s*([0-9]+(?:\.[0-9]+)?)\s*(B|KB|MB|GB|TB)') {
        $value = [double]$matches[1]
        switch ($matches[2]) {
            'B' { return $value }
            'KB' { return $value * 1KB }
            'MB' { return $value * 1MB }
            'GB' { return $value * 1GB }
            'TB' { return $value * 1TB }
        }
    }
    return 0
}

try {
    $driveInfo = Get-PSDrive -Name $Drive -ErrorAction Stop
    $freeGB = [math]::Round($driveInfo.Free / 1GB, 2)
    if ($freeGB -lt $BlockFreeGB) {
        Add-Result 'disk-free' 'FAIL' ("{0}: {1} GB free; large Docker builds blocked" -f $Drive, $freeGB)
    } elseif ($freeGB -lt $WarnFreeGB) {
        Add-Result 'disk-free' 'WARN' ("{0}: {1} GB free; controlled single build only" -f $Drive, $freeGB)
    } else {
        Add-Result 'disk-free' 'PASS' ("{0}: {1} GB free" -f $Drive, $freeGB)
    }
} catch {
    $freeGB = $null
    Add-Result 'disk-free' 'FAIL' $_.Exception.Message
}

try {
    $vhdx = Join-Path $env:LOCALAPPDATA 'Docker\wsl\disk\docker_data.vhdx'
    if (Test-Path -LiteralPath $vhdx) {
        $vhdxGB = [math]::Round((Get-Item -LiteralPath $vhdx).Length / 1GB, 2)
        Add-Result 'docker-vhdx' 'INFO' ("{0}: {1} GB; logical cleanup does not automatically shrink it" -f $vhdx, $vhdxGB)
    } else {
        $vhdxGB = $null
        Add-Result 'docker-vhdx' 'WARN' 'docker_data.vhdx not found at the default path'
    }
} catch {
    $vhdxGB = $null
    Add-Result 'docker-vhdx' 'WARN' $_.Exception.Message
}

try {
    docker info --format '{{.ServerVersion}}' *> $null
    if ($LASTEXITCODE -eq 0) {
        Add-Result 'docker-daemon' 'PASS' 'Docker daemon is reachable'
    } else {
        Add-Result 'docker-daemon' 'FAIL' 'Docker daemon is not reachable'
    }
} catch {
    Add-Result 'docker-daemon' 'FAIL' $_.Exception.Message
}

try {
    $rows = @(docker system df --format '{{json .}}' | ForEach-Object { $_ | ConvertFrom-Json })
    $cache = $rows | Where-Object Type -eq 'Build Cache' | Select-Object -First 1
    $cacheGB = if ($cache) { [math]::Round((Size-ToBytes $cache.Size) / 1GB, 2) } else { 0 }
    if ($cacheGB -gt $BlockCacheGB) {
        Add-Result 'build-cache' 'FAIL' ("{0} GB; large build blocked until cache is reviewed" -f $cacheGB)
    } elseif ($cacheGB -gt $WarnCacheGB) {
        Add-Result 'build-cache' 'WARN' ("{0} GB; review cleanup" -f $cacheGB)
    } else {
        Add-Result 'build-cache' 'PASS' ("{0} GB" -f $cacheGB)
    }
} catch {
    $cacheGB = $null
    Add-Result 'build-cache' 'FAIL' $_.Exception.Message
}

try {
    $containerIds = @(docker ps -q | Where-Object { $_ -and $_ -notmatch '^CONTAINER' })
    $activeIds = @{}
    foreach ($containerId in $containerIds) {
        $containerImageId = (docker inspect --format '{{.Image}}' $containerId 2>$null).Trim()
        if ($containerImageId) { $activeIds[$containerImageId] = $true }
    }
    $images = @(docker image ls --no-trunc --format '{{json .}}' | ForEach-Object { $_ | ConvertFrom-Json })
    $relayCandidates = @($images | Where-Object {
        $_.Repository -like 'relay-new-api-*' -and -not $activeIds.ContainsKey($_.ID)
    })
    Add-Result 'image-inventory' 'INFO' ("{0} images total; {1} relay-new-api images are not used by a running container" -f $images.Count, $relayCandidates.Count)
    if ($relayCandidates.Count -gt 0 -and -not $Json) {
        $relayCandidates | Sort-Object Repository, Tag | ForEach-Object {
            Write-Host ("CANDIDATE image={0} repo={1} tag={2} size={3}" -f $_.ID, $_.Repository, $_.Tag, $_.Size) -ForegroundColor Yellow
        }
    }
} catch {
    $relayCandidates = @()
    Add-Result 'image-inventory' 'FAIL' $_.Exception.Message
}

if ($Json) {
    [pscustomobject]@{
        results = @($results)
        free_gb = $freeGB
        cache_gb = $cacheGB
        vhdx_gb = $vhdxGB
        relay_image_candidates = @($relayCandidates)
    } | ConvertTo-Json -Depth 6
}

if (@($results | Where-Object status -eq 'FAIL').Count -gt 0) { exit 1 }
