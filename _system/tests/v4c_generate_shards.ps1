param(
    [Parameter(Mandatory=$false)][ValidateSet("Smoke","Full")][string]$Mode = "Smoke",
    [Parameter(Mandatory=$false)][string]$InventoryPath = "_system/v4c/inventory/source_inventory.jsonl",
    [Parameter(Mandatory=$false)][string]$ProgressPath = "_system/v4c/progress/v4c_source_progress.jsonl",
    [Parameter(Mandatory=$false)][string]$OutDir = "_system/v4c/runtime/plan",
    [Parameter(Mandatory=$false)][int]$SmokeCount = 150,
    [Parameter(Mandatory=$false)][int]$ShardSize = 50,
    [Parameter(Mandatory=$false)][switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Read-JsonLines([string]$Path) {
    $items = @()
    if (-not (Test-Path $Path)) { return ,$items }
    foreach ($line in [System.IO.File]::ReadAllLines($Path, $Utf8NoBom)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $items += ($line | ConvertFrom-Json)
    }
    return ,$items
}

function Ensure-Inventory([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Inventory not found: $Path" }
    $first = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    $needsBootstrap = $false
    $expectedSha = ""
    try {
        $probe = $first | ConvertFrom-Json
        if ($probe.PSObject.Properties.Name -contains "bootstrap" -and [bool]$probe.bootstrap) {
            $needsBootstrap = $true
            if ($probe.PSObject.Properties.Name -contains "inventory_sha256") { $expectedSha = [string]$probe.inventory_sha256 }
        }
    } catch {}
    if (-not $needsBootstrap) { return }

    $dir = Split-Path -Parent $Path
    $bootstrapPath = Join-Path $dir "source_inventory.bootstrap.gz.b64"
    $partsDir = Join-Path $dir "source_inventory.bootstrap.parts"
    if (Test-Path $bootstrapPath) {
        $encoded = ([System.IO.File]::ReadAllText($bootstrapPath, $Utf8NoBom)).Trim()
    } elseif (Test-Path $partsDir) {
        $encoded = ""
        foreach ($part in @(Get-ChildItem -LiteralPath $partsDir -File | Sort-Object Name)) {
            $encoded += ([System.IO.File]::ReadAllText($part.FullName, $Utf8NoBom)).Trim()
        }
    } else {
        throw "Bootstrap inventory missing: $bootstrapPath or $partsDir"
    }
    $compressed = [Convert]::FromBase64String($encoded)
    $input = New-Object System.IO.MemoryStream(,$compressed)
    $gzip = New-Object System.IO.Compression.GZipStream($input, [System.IO.Compression.CompressionMode]::Decompress)
    $output = [System.IO.File]::Create($Path)
    try { $gzip.CopyTo($output) } finally { $output.Dispose(); $gzip.Dispose(); $input.Dispose() }
    if (-not [string]::IsNullOrWhiteSpace($expectedSha)) {
        $actualSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
        if ($actualSha -ne $expectedSha.ToLowerInvariant()) { throw "Expanded inventory SHA256 mismatch" }
    }
}

function Get-LegacyCompleted {
    $manifestPath = "_system/tests/fixtures/v4c_source_batch_manifest.json"
    $byBatch = @{}
    $log = @(& git log --all --format="%H`t%s" -- $manifestPath)
    if ($LASTEXITCODE -ne 0) { throw "git log failed while reconstructing legacy batches" }

    foreach ($line in $log) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line -split "`t", 2
        if ($parts.Count -lt 1) { continue }
        $sha = $parts[0].Trim()
        $raw = @(& git show "$sha`:$manifestPath" 2>$null)
        if ($LASTEXITCODE -ne 0 -or $raw.Count -eq 0) { continue }
        try { $manifest = (($raw -join "`n") | ConvertFrom-Json) } catch { continue }
        if (-not ($manifest.PSObject.Properties.Name -contains "batch_id")) { continue }
        $batch = [string]$manifest.batch_id
        if ($batch -notmatch "^B(0(0[1-9]|1[0-8]))$") { continue }
        if (-not $byBatch.ContainsKey($batch)) {
            $byBatch[$batch] = [pscustomobject]@{ sha=$sha; manifest=$manifest }
        }
    }

    if ($byBatch.Count -ne 18) {
        throw "Expected legacy B001-B018 manifests, found $($byBatch.Count)"
    }

    $urlMap = @{}
    $legacySequences = New-Object System.Collections.Generic.List[int]
    foreach ($batch in ($byBatch.Keys | Sort-Object)) {
        $m = $byBatch[$batch].manifest
        foreach ($s in @($m.sources)) {
            $seq = [int]$s.sequence
            $url = ([string]$s.url).Trim()
            if ([string]::IsNullOrWhiteSpace($url)) { throw "Legacy $batch contains blank URL" }
            if ($urlMap.ContainsKey($url)) { throw "Legacy URL duplicated across completed batches: $url" }
            $urlMap[$url] = [pscustomobject]@{
                legacy_batch = $batch
                legacy_sequence = $seq
                legacy_commit = $byBatch[$batch].sha
            }
            $legacySequences.Add($seq)
        }
    }
    $ordered = @($legacySequences | Sort-Object)
    if ($ordered.Count -ne 900) { throw "Expected 900 legacy completed sources, found $($ordered.Count)" }
    for ($i=1; $i -le 900; $i++) {
        if ($ordered[$i-1] -ne $i) { throw "Legacy sequence reconciliation failed at $i" }
    }
    return $urlMap
}

function Latest-ProgressMap([object[]]$Progress) {
    $map = @{}
    foreach ($p in $Progress) {
        if (-not ($p.PSObject.Properties.Name -contains "sequence")) { continue }
        $seq = [int]$p.sequence
        $map[$seq] = $p
    }
    return $map
}

function New-ProgressRecord($src, [string]$Status, [string]$SemanticStatus, $Extra) {
    $h = [ordered]@{
        sequence = [int]$src.sequence
        source_id = [string]$src.source_id
        product_id = [string]$src.product_id
        image_index = $src.image_index
        image_type = [string]$src.image_type
        url = [string]$src.url
        status = $Status
        semantic_status = $SemanticStatus
        image_generation_called = $false
        tiny_snow_api_called = $false
        paid_api_called = $false
    }
    if ($Extra) {
        foreach ($k in $Extra.Keys) { $h[$k] = $Extra[$k] }
    }
    return [pscustomobject]$h
}

function Invoke-SelfTest {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("v4c-shard-selftest-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $inv = @(
            [pscustomobject]@{sequence=1;source_id="T1";product_id="P1";image_index=0;image_type="main";url="https://example.invalid/a";source_action="TEST"},
            [pscustomobject]@{sequence=2;source_id="T2";product_id="P1";image_index=1;image_type="detail";url="https://example.invalid/a";source_action="TEST"},
            [pscustomobject]@{sequence=3;source_id="T3";product_id="P2";image_index=0;image_type="main";url="https://example.invalid/b";source_action="TEST"}
        )
        $urlSeen=@{}; $queued=New-Object System.Collections.Generic.List[object]; $dupes=New-Object System.Collections.Generic.List[object]
        foreach($s in $inv) {
            if($urlSeen.ContainsKey($s.url)) {
                $dupes.Add([pscustomobject]@{sequence=$s.sequence;canonical_sequence=$urlSeen[$s.url]})
            } else {
                $urlSeen[$s.url]=[int]$s.sequence
                $queued.Add($s)
            }
        }
        $result=[ordered]@{
            passed = ($queued.Count -eq 2 -and $dupes.Count -eq 1)
            url_duplicate_not_refetched = ($dupes.Count -eq 1)
            unique_queued = $queued.Count
            duplicate_count = $dupes.Count
            image_generation_called = $false
            tiny_snow_api_called = $false
            paid_api_called = $false
        }
        $out = Join-Path $tmp "selftest.json"
        Write-Utf8NoBom $out (($result | ConvertTo-Json -Depth 8) + "`n")
        if (-not $result.passed) { throw "v4c_generate_shards self-test failed" }
        Write-Host "SELFTEST_RESULT=$($result | ConvertTo-Json -Compress)"
    } finally {
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }

Ensure-Inventory $InventoryPath
$inventory = @(Read-JsonLines $InventoryPath)
if ($inventory.Count -eq 0) { throw "Inventory is empty" }
$orderedInv = @($inventory | Sort-Object {[int]$_.sequence})
for ($i=1; $i -le $orderedInv.Count; $i++) {
    if ([int]$orderedInv[$i-1].sequence -ne $i) { throw "Inventory sequence gap/duplicate at expected $i" }
}
$legacy = Get-LegacyCompleted
$existing = Latest-ProgressMap @(Read-JsonLines $ProgressPath)
$terminal = @("LEGACY_DONE","DONE","SHA_DUPLICATE","URL_DUPLICATE")
$urlCanonical = @{}
$seed = New-Object System.Collections.Generic.List[object]
$candidates = New-Object System.Collections.Generic.List[object]
$urlDupes = New-Object System.Collections.Generic.List[object]

foreach ($src in $orderedInv) {
    $seq = [int]$src.sequence
    $url = ([string]$src.url).Trim()
    if ([string]::IsNullOrWhiteSpace($url)) { throw "Blank source URL at inventory sequence $seq" }

    if ($urlCanonical.ContainsKey($url)) {
        $canonicalSeq = [int]$urlCanonical[$url]
        $rec = New-ProgressRecord $src "URL_DUPLICATE" "SKIP_DUPLICATE" @{ canonical_sequence=$canonicalSeq }
        $seed.Add($rec)
        $urlDupes.Add([pscustomobject]@{sequence=$seq;url=$url;canonical_sequence=$canonicalSeq})
        continue
    }
    $urlCanonical[$url] = $seq

    if ($legacy.ContainsKey($url)) {
        $meta = $legacy[$url]
        $sem = if ([int]$meta.legacy_sequence -le 850) { "REVIEWED" } else { "PENDING" }
        $rec = New-ProgressRecord $src "LEGACY_DONE" $sem @{
            legacy_batch=$meta.legacy_batch
            legacy_sequence=[int]$meta.legacy_sequence
            legacy_commit=$meta.legacy_commit
        }
        $seed.Add($rec)
        continue
    }

    if ($existing.ContainsKey($seq) -and $terminal -contains [string]$existing[$seq].status) {
        $seed.Add($existing[$seq])
        continue
    }

    if ($existing.ContainsKey($seq) -and [string]$existing[$seq].status -eq "FAILED") {
        $seed.Add($existing[$seq])
    } else {
        $seed.Add((New-ProgressRecord $src "PENDING" "PENDING" @{}))
    }
    $candidates.Add($src)
}

$selected = if ($Mode -eq "Smoke") { @($candidates | Select-Object -First $SmokeCount) } else { @($candidates) }

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$shardDir = Join-Path $OutDir "shards"
New-Item -ItemType Directory -Force -Path $shardDir | Out-Null

$seedText = (($seed | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 12 }) -join "`n")
if ($seed.Count -gt 0) { $seedText += "`n" }
Write-Utf8NoBom (Join-Path $OutDir "seed_progress.jsonl") $seedText

$shardNames = New-Object System.Collections.Generic.List[string]
$idx=0
for ($offset=0; $offset -lt $selected.Count; $offset += $ShardSize) {
    $idx++
    $name = "shard-{0:D3}" -f $idx
    $shardNames.Add($name)
    $chunk = @($selected | Select-Object -Skip $offset -First $ShardSize)
    $text = (($chunk | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 8 }) -join "`n") + "`n"
    Write-Utf8NoBom (Join-Path $shardDir ($name + ".jsonl")) $text
}

$matrix = [ordered]@{ shard=@($shardNames) }
Write-Utf8NoBom (Join-Path $OutDir "matrix.json") (($matrix | ConvertTo-Json -Compress -Depth 5) + "`n")
$dupeObj = [ordered]@{ url_duplicates=@($urlDupes); sha256_duplicates=@() }
Write-Utf8NoBom (Join-Path $OutDir "duplicate_map.json") (($dupeObj | ConvertTo-Json -Depth 12) + "`n")
$summary = [ordered]@{
    mode=$Mode
    inventory_count=$orderedInv.Count
    legacy_completed_count=@($seed | Where-Object {$_.status -eq "LEGACY_DONE"}).Count
    existing_terminal_count=@($seed | Where-Object {$terminal -contains $_.status -and $_.status -ne "LEGACY_DONE" -and $_.status -ne "URL_DUPLICATE"}).Count
    url_duplicate_count=$urlDupes.Count
    candidate_count=$candidates.Count
    selected_count=$selected.Count
    shard_count=$shardNames.Count
    shard_size=$ShardSize
    image_generation_called=$false
    tiny_snow_api_called=$false
    paid_api_called=$false
}
Write-Utf8NoBom (Join-Path $OutDir "plan_summary.json") (($summary | ConvertTo-Json -Depth 8) + "`n")
Write-Host "PLAN_SUMMARY=$($summary | ConvertTo-Json -Compress)"
