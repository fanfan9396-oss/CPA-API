[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Execute,
    [switch]$ConfirmCleanup,
    [string[]]$ImageId,
    [switch]$PruneBuildCache
)

$ErrorActionPreference = 'Stop'
if ($Execute -and -not $ConfirmCleanup) {
    throw '执行删除必须同时传入 -ConfirmCleanup；默认仅预览。'
}
if ($Execute -and (-not $ImageId -and -not $PruneBuildCache)) {
    throw '执行模式必须明确指定 -ImageId 或 -PruneBuildCache；不支持全量清理。'
}

$containerIds = @(docker ps -q | Where-Object { $_ -and $_ -notmatch '^CONTAINER' })
$activeIds = @{}
foreach ($containerId in $containerIds) {
    $containerImageId = (docker inspect --format '{{.Image}}' $containerId 2>$null).Trim()
    if ($containerImageId) { $activeIds[$containerImageId] = $true }
}
$images = @(docker image ls --no-trunc --format '{{json .}}' | ForEach-Object { $_ | ConvertFrom-Json })

$protectedPatterns = @(
    '^relay-stack-',
    '^postgres$',
    '^redis$',
    '^weishaw/sub2api$',
    '^aquasec/trivy$',
    '^curlimages/curl$',
    '^oven/bun$'
)

function Is-Protected([object]$Image) {
    if ($activeIds.ContainsKey($Image.ID)) { return $true }
    foreach ($pattern in $protectedPatterns) {
        if ($Image.Repository -match $pattern) { return $true }
    }
    if ($Image.Repository -match '^relay-new-api-(quality|quality-rebuild)$') { return $true }
    return $false
}

$selected = @()
if ($ImageId) {
    foreach ($id in $ImageId) {
        $matches = @($images | Where-Object { $_.ID -eq $id -or $_.ID -eq ('sha256:' + $id) })
        if ($matches.Count -ne 1) { throw "未找到唯一镜像 ID：$id" }
        $image = $matches[0]
        if (Is-Protected $image) {
            throw "镜像受保护或正在使用，拒绝删除：$($image.ID) $($image.Repository):$($image.Tag)"
        }
        $selected += $image
    }
}

Write-Host 'Docker 清理预览（默认不删除）' -ForegroundColor Cyan
if ($selected.Count -eq 0) {
    $candidates = @($images | Where-Object {
        $_.Repository -like 'relay-new-api-*' -and -not (Is-Protected $_)
    })
    if ($candidates.Count -eq 0) {
        Write-Host '没有发现可安全列出的 relay-new-api 历史镜像候选。' -ForegroundColor Green
    } else {
        $candidates | Sort-Object Repository, Tag | ForEach-Object {
            Write-Host ("CANDIDATE image={0} repo={1} tag={2} size={3}" -f $_.ID, $_.Repository, $_.Tag, $_.Size) -ForegroundColor Yellow
        }
    }
} else {
    $selected | ForEach-Object {
        Write-Host ("SELECTED image={0} repo={1} tag={2} size={3}" -f $_.ID, $_.Repository, $_.Tag, $_.Size) -ForegroundColor Yellow
    }
}
if ($PruneBuildCache) {
    Write-Host 'SELECTED build cache: unused BuildKit cache only' -ForegroundColor Yellow
}

if (-not $Execute) {
    Write-Host 'DRY-RUN：未删除任何镜像、缓存、容器或卷。' -ForegroundColor Cyan
    exit 0
}

foreach ($image in $selected) {
    if ($PSCmdlet.ShouldProcess("$($image.ID) $($image.Repository):$($image.Tag)", '删除明确指定的未使用镜像')) {
        docker image rm $image.ID
        if ($LASTEXITCODE -ne 0) { throw "删除镜像失败：$($image.ID)" }
    }
}

if ($PruneBuildCache) {
    if ($PSCmdlet.ShouldProcess('unused BuildKit cache', '清理未使用构建缓存')) {
        docker buildx prune --builder desktop-linux --all --force
        if ($LASTEXITCODE -ne 0) { throw '清理 BuildKit 缓存失败' }
    }
}

Write-Host '清理完成；必须重新运行 check-local-readiness.ps1 和 check-ops-readiness.ps1。' -ForegroundColor Green
