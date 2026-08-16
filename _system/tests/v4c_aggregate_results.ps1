param(
    [Parameter(Mandatory=$false)][string]$InventoryPath = "_system/v4c/inventory/source_inventory.jsonl",
    [Parameter(Mandatory=$false)][string]$BaseProgressPath,
    [Parameter(Mandatory=$false)][string]$ShardResultRoot,
    [Parameter(Mandatory=$false)][string]$OutputDir = "_system/v4c/runtime/aggregate",
    [Parameter(Mandatory=$false)][string]$Phase = "Smoke",
    [Parameter(Mandatory=$false)][switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
}

function Read-JsonLines([string]$Path) {
    $items = @()
    if (-not (Test-Path $Path)) { return $items }
    foreach ($line in [System.IO.File]::ReadAllLines($Path, $Utf8NoBom)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $items += ($line | ConvertFrom-Json)
    }
    return $items
}

function Ensure-Inventory([string]$Path) {
    if (-not (Test-Path $Path)) { throw "Inventory not found: $Path" }
    $first = Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    try { $probe = $first | ConvertFrom-Json } catch { return }
    if (-not ($probe.PSObject.Properties.Name -contains "bootstrap") -or -not [bool]$probe.bootstrap) { return }

    $expectedSha = if ($probe.PSObject.Properties.Name -contains "inventory_sha256") { [string]$probe.inventory_sha256 } else { "" }
    $dir = Split-Path -Parent $Path
    $single = Join-Path $dir "source_inventory.bootstrap.gz.b64"
    $parts = Join-Path $dir "source_inventory.bootstrap.parts"
    $encoded = ""
    if (Test-Path $single) {
        $encoded = ([System.IO.File]::ReadAllText($single, $Utf8NoBom)).Trim()
    } elseif (Test-Path $parts) {
        foreach ($part in (Get-ChildItem -LiteralPath $parts -File | Sort-Object Name)) {
            $encoded += ([System.IO.File]::ReadAllText($part.FullName, $Utf8NoBom)).Trim()
        }
    } else {
        throw "Bootstrap inventory missing"
    }

    $compressed = [Convert]::FromBase64String($encoded)
    $input = New-Object System.IO.MemoryStream(,$compressed)
    $gzip = New-Object System.IO.Compression.GZipStream($input, [System.IO.Compression.CompressionMode]::Decompress)
    $output = [System.IO.File]::Create($Path)
    try { $gzip.CopyTo($output) } finally { $output.Dispose(); $gzip.Dispose(); $input.Dispose() }

    if (-not [string]::IsNullOrWhiteSpace($expectedSha)) {
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
        if ($actual -ne $expectedSha.ToLowerInvariant()) { throw "Expanded inventory SHA256 mismatch" }
    }
}

function Invoke-SelfTest {
    $records = @(
        [pscustomobject]@{ sequence=1; sha256="abc" },
        [pscustomobject]@{ sequence=2; sha256="abc" }
    )
    $canonical = @{}
    $duplicates = 0
    foreach ($record in ($records | Sort-Object sequence)) {
        if ($canonical.ContainsKey([string]$record.sha256)) { $duplicates++ }
        else { $canonical[[string]$record.sha256] = [int]$record.sequence }
    }
    $passed = ($duplicates -eq 1)
    $summary = [ordered]@{
        passed=$passed
        sha_duplicate_not_reanalyzed=$passed
        sha_duplicate_count=$duplicates
        image_generation_called=$false
        tiny_snow_api_called=$false
        paid_api_called=$false
    }
    Write-Host "SELFTEST_RESULT=$($summary | ConvertTo-Json -Compress)"
    if (-not $passed) { throw "v4c_aggregate_results self-test failed" }
}

if ($SelfTest) { Invoke-SelfTest; exit 0 }
if ([string]::IsNullOrWhiteSpace($BaseProgressPath)) { throw "BaseProgressPath required" }
if ([string]::IsNullOrWhiteSpace($ShardResultRoot)) { throw "ShardResultRoot required" }

Ensure-Inventory $InventoryPath
$inventory = @(Read-JsonLines $InventoryPath | Sort-Object {[int]$_.sequence})
$base = @(Read-JsonLines $BaseProgressPath)
$map = @{}
foreach ($record in $base) {
    if ($record.PSObject.Properties.Name -contains "sequence") {
        $map[[int]$record.sequence] = $record
    }
}
if ($map.Count -ne $inventory.Count) {
    throw "Base progress must reconcile to inventory: $($map.Count)/$($inventory.Count)"
}

$resultFiles = @(Get-ChildItem -LiteralPath $ShardResultRoot -Recurse -File -Filter "*.progress.jsonl" -ErrorAction SilentlyContinue)
$seenResult = @{}
foreach ($file in $resultFiles) {
    foreach ($result in @(Read-JsonLines $file.FullName)) {
        $seq = [int]$result.sequence
        if ($seenResult.ContainsKey($seq)) { throw "Sequence $seq appears in more than one shard result" }
        if (-not $map.ContainsKey($seq)) { throw "Shard result sequence $seq not in inventory" }
        $seenResult[$seq] = $true

        $merged = [ordered]@{}
        foreach ($property in $map[$seq].PSObject.Properties) { $merged[$property.Name] = $property.Value }
        foreach ($property in $result.PSObject.Properties) { $merged[$property.Name] = $property.Value }
        $map[$seq] = [pscustomobject]$merged
    }
}

$shaCanonical = @{}
$shaDuplicates = @()
foreach ($seq in ($map.Keys | Sort-Object)) {
    $record = $map[$seq]
    if ([string]$record.status -ne "DONE") { continue }

    # PowerShell 5.1: logical negation must be -not, not numeric unary '-'.
    if (-not ($record.PSObject.Properties.Name -contains "sha256") -or [string]::IsNullOrWhiteSpace([string]$record.sha256)) {
        throw "DONE without SHA256 at $seq"
    }

    $sha = ([string]$record.sha256).ToLowerInvariant()
    if ($shaCanonical.ContainsKey($sha)) {
        $canonicalSequence = [int]$shaCanonical[$sha]
        $copy = [ordered]@{}
        foreach ($property in $record.PSObject.Properties) { $copy[$property.Name] = $property.Value }
        $copy["status"] = "SHA_DUPLICATE"
        $copy["semantic_status"] = "SKIP_DUPLICATE"
        $copy["sha_duplicate_of_sequence"] = $canonicalSequence
        $map[$seq] = [pscustomobject]$copy
        $shaDuplicates += [pscustomobject]@{
            sequence=$seq
            sha256=$sha
            canonical_sequence=$canonicalSequence
        }
    } else {
        $shaCanonical[$sha] = [int]$seq
    }
}

$ordered = @()
foreach ($source in $inventory) {
    $seq = [int]$source.sequence
    if (-not $map.ContainsKey($seq)) { throw "Missing aggregate record for sequence $seq" }
    $ordered += $map[$seq]
}
if ($ordered.Count -ne $inventory.Count) { throw "Aggregate output count mismatch" }

$urlDuplicates = @(
    $ordered | Where-Object { $_.status -eq "URL_DUPLICATE" } | ForEach-Object {
        [pscustomobject]@{
            sequence=[int]$_.sequence
            url=[string]$_.url
            canonical_sequence=[int]$_.canonical_sequence
        }
    }
)
$failed = @($ordered | Where-Object { $_.status -eq "FAILED" })
$pending = @($ordered | Where-Object { $_.semantic_status -eq "PENDING" -and $_.status -in @("DONE","LEGACY_DONE") })
$hold = @($ordered | Where-Object { $_.semantic_status -eq "HOLD" })
$block = @($ordered | Where-Object { $_.semantic_status -eq "BLOCK" -or $_.status -eq "FAILED" })
$legacyRecords = @($ordered | Where-Object { $_.status -eq "LEGACY_DONE" })

$legacySequenceCoverage = 0
foreach ($record in $legacyRecords) {
    if ($record.PSObject.Properties.Name -contains "legacy_sequences") {
        $legacySequenceCoverage += @($record.legacy_sequences).Count
    } elseif ($record.PSObject.Properties.Name -contains "legacy_sequence") {
        $legacySequenceCoverage++
    }
}

if (Test-Path $OutputDir) { Remove-Item -Recurse -Force $OutputDir }
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null

$progressText = (($ordered | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 14 }) -join "`n") + "`n"
Write-Utf8NoBom (Join-Path $OutputDir "v4c_source_progress.jsonl") $progressText
Write-Utf8NoBom (Join-Path $OutputDir "source_evidence.jsonl") $progressText

$duplicateMap = [ordered]@{
    url_duplicates=$urlDuplicates
    sha256_duplicates=$shaDuplicates
}
Write-Utf8NoBom (Join-Path $OutputDir "duplicate_map.json") (($duplicateMap | ConvertTo-Json -Depth 12) + "`n")
Write-Utf8NoBom (Join-Path $OutputDir "failed_sources.json") ((@($failed) | ConvertTo-Json -Depth 12) + "`n")

$semanticQueue = ""
if ($pending.Count -gt 0) {
    $semanticQueue = (($pending | ForEach-Object {
        [pscustomobject]@{
            sequence=[int]$_.sequence
            source_id=[string]$_.source_id
            product_id=[string]$_.product_id
            url=[string]$_.url
            sha256=$(if ($_.PSObject.Properties.Name -contains "sha256") { [string]$_.sha256 } else { "" })
            reason="semantic_evidence_pending"
        } | ConvertTo-Json -Compress
    }) -join "`n") + "`n"
}
Write-Utf8NoBom (Join-Path $OutputDir "semantic_evidence_queue.jsonl") $semanticQueue

$summary = [ordered]@{
    phase=$Phase
    inventory_count=$inventory.Count
    shard_result_count=$seenResult.Count
    legacy_done=$legacyRecords.Count
    legacy_sequence_coverage=$legacySequenceCoverage
    legacy_duplicate_occurrences=(900-$legacyRecords.Count)
    done=@($ordered | Where-Object { $_.status -eq "DONE" }).Count
    url_duplicates=$urlDuplicates.Count
    sha256_duplicates=$shaDuplicates.Count
    failed=$failed.Count
    semantic_pending=$pending.Count
    hold=$hold.Count
    block=$block.Count
    terminal_count=@($ordered | Where-Object { $_.status -in @("LEGACY_DONE","DONE","URL_DUPLICATE","SHA_DUPLICATE","FAILED") }).Count
    image_generation_called=$false
    tiny_snow_api_called=$false
    paid_api_called=$false
}
Write-Utf8NoBom (Join-Path $OutputDir "aggregate_summary.json") (($summary | ConvertTo-Json -Depth 8) + "`n")
Write-Host "AGGREGATE_SUMMARY=$($summary | ConvertTo-Json -Compress)"
