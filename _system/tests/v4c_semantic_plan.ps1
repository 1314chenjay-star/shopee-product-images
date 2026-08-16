param(
    [ValidateSet('Smoke','Full')]
    [string]$Mode = 'Smoke',
    [string]$QueuePath = '_system/v4c/results/semantic_evidence_queue.jsonl',
    [string]$SmokeManifestPath = '_system/v4c/semantic/smoke/semantic_smoke_manifest.jsonl',
    [string]$ContextPath = '_system/v4c/semantic/product_context.jsonl',
    [string]$SeedProgressPath = '',
    [string]$OutDir = 'artifacts/semantic-plan',
    [int]$ShardCount = 4
)
$ErrorActionPreference = 'Stop'

function Read-Jsonl([string]$Path) {
    if (-not (Test-Path $Path)) { throw "JSONL not found: $Path" }
    $items = @()
    Get-Content $Path -Encoding UTF8 | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) { $items += ($_ | ConvertFrom-Json) }
    }
    return $items
}
function Write-Jsonl([string]$Path, $Items) {
    $dir = Split-Path -Parent $Path
    if ($dir) { New-Item -ItemType Directory -Force $dir | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding($false)
    $lines = @()
    foreach ($item in @($Items)) { $lines += ($item | ConvertTo-Json -Depth 20 -Compress) }
    [System.IO.File]::WriteAllLines($Path, $lines, $enc)
}

$queue = @(Read-Jsonl $QueuePath)
$context = @(Read-Jsonl $ContextPath)
if ($queue.Count -ne 1544) { throw "V4-C1 semantic queue must stay at 1544; got $($queue.Count)" }
$ctxByProduct = @{}
foreach ($c in $context) { $ctxByProduct[[string]$c.product_id] = $c }
if ($ctxByProduct.Count -lt 214) { throw "Expected 214 pending-product context records; got $($ctxByProduct.Count)" }

$seenSeq = @{}
foreach ($q in $queue) {
    $seq = [int]$q.sequence
    if ($seenSeq.ContainsKey($seq)) { throw "Duplicate pending sequence in queue: $seq" }
    $seenSeq[$seq] = $true
    if ([string]::IsNullOrWhiteSpace([string]$q.sha256)) { throw "Pending sequence without SHA256: $seq" }
    if (-not $ctxByProduct.ContainsKey([string]$q.product_id)) { throw "Pending sequence missing product context: $seq" }
}

New-Item -ItemType Directory -Force $OutDir | Out-Null

if ($Mode -eq 'Smoke') {
    $smoke = @(Read-Jsonl $SmokeManifestPath)
    if ($smoke.Count -lt 100 -or $smoke.Count -gt 200) { throw "Smoke must contain 100-200 images; got $($smoke.Count)" }
    if ($smoke.Count -ne 160) { throw "V4-C2 smoke is locked to 160 images; got $($smoke.Count)" }
    $smokeSeq = @{}
    $families = @{}
    $subcats = @{}
    $products = @{}
    foreach ($s in $smoke) {
        $seq = [int]$s.sequence
        if ($smokeSeq.ContainsKey($seq)) { throw "Duplicate smoke sequence: $seq" }
        $smokeSeq[$seq] = $true
        if (-not $seenSeq.ContainsKey($seq)) { throw "Smoke sequence is not V4-C1 PENDING: $seq" }
        if ([string]$s.sha256 -ne [string](@($queue | Where-Object { [int]$_.sequence -eq $seq })[0].sha256)) { throw "Smoke SHA mismatch at sequence $seq" }
        $families[[string]$s.family] = $true
        $subcats[([string]$s.family + '/' + [string]$s.subcategory)] = $true
        $products[[string]$s.product_id] = $true
    }
    if (-not $smokeSeq.ContainsKey(7)) { throw 'Smoke must include canonical sequence 7 for SHA reuse probe 13 -> 7' }
    foreach ($required in @('sports','apparel','shoes','bags')) {
        if (-not $families.ContainsKey($required)) { throw "Smoke missing family: $required" }
    }
    if ($subcats.Count -lt 13) { throw "Smoke subcategory coverage too small: $($subcats.Count)" }
    if ($products.Count -lt 100) { throw "Smoke unique product coverage too small: $($products.Count)" }
    Write-Jsonl (Join-Path $OutDir 'smoke_manifest.jsonl') $smoke
    $summary = [ordered]@{
        mode = 'Smoke'; queue_count = $queue.Count; smoke_count = $smoke.Count; unique_products = $products.Count
        family_count = $families.Count; subcategory_count = $subcats.Count; forced_canonical_sequence = 7; duplicate_probe_sequence = 13
        image_generation_called = $false; tiny_snow_api_called = $false; paid_api_called = $false; source_pipeline_redownload = $false
    }
    $summary | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutDir 'plan_summary.json') -Encoding UTF8
    Write-Host "SEMANTIC_SMOKE_COUNT=$($smoke.Count)"
    Write-Host "SEMANTIC_SMOKE_UNIQUE_PRODUCTS=$($products.Count)"
    Write-Host "SEMANTIC_SMOKE_FAMILIES=$($families.Count)"
    Write-Host "SEMANTIC_SMOKE_SUBCATEGORIES=$($subcats.Count)"
    return
}

if ([string]::IsNullOrWhiteSpace($SeedProgressPath) -or -not (Test-Path $SeedProgressPath)) { throw 'Full mode requires SeedProgressPath from successful smoke checkpoint.' }
$seed = @(Read-Jsonl $SeedProgressPath)
$terminal = @{}
foreach ($r in $seed) { if ([string]$r.semantic_status -in @('DONE','REUSED','BLOCKED')) { $terminal[[int]$r.sequence] = $true } }
$remaining = @()
foreach ($q in $queue) { if (-not $terminal.ContainsKey([int]$q.sequence)) { $remaining += $q } }
$expected = 1544 - 160
if ($remaining.Count -ne $expected) { throw "Expected $expected remaining after smoke; got $($remaining.Count)" }
if ($ShardCount -lt 1) { throw 'ShardCount must be >= 1' }
$shardDir = Join-Path $OutDir 'shards'
New-Item -ItemType Directory -Force $shardDir | Out-Null
$matrix = @()
for ($i = 0; $i -lt $ShardCount; $i++) {
    $name = ('semantic-{0:d3}' -f ($i + 1)); $items = @()
    for ($j = $i; $j -lt $remaining.Count; $j += $ShardCount) { $items += $remaining[$j] }
    Write-Jsonl (Join-Path $shardDir ($name + '.jsonl')) $items
    $matrix += [ordered]@{ shard = $name; count = $items.Count }
}
$matrixObj = [ordered]@{ include = $matrix }
$enc = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $OutDir 'matrix.json'), ($matrixObj | ConvertTo-Json -Depth 10 -Compress), $enc)
$summary = [ordered]@{
    mode = 'Full'; queue_count = $queue.Count; smoke_terminal_count = $terminal.Count; remaining_count = $remaining.Count; shard_count = $ShardCount
    image_generation_called = $false; tiny_snow_api_called = $false; paid_api_called = $false; source_pipeline_redownload = $false
}
$summary | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $OutDir 'plan_summary.json') -Encoding UTF8
Write-Host "SEMANTIC_FULL_REMAINING=$($remaining.Count)"
Write-Host "SEMANTIC_FULL_SHARDS=$ShardCount"
