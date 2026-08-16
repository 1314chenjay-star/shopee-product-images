param(
    [ValidateSet('Smoke','Full')][string]$Mode = 'Smoke',
    [string]$QueuePath = '_system/v4c/results/semantic_evidence_queue.jsonl',
    [string]$SmokeManifestPath = '_system/v4c/semantic/smoke/semantic_smoke_manifest.jsonl',
    [string]$ContextPath = '_system/v4c/semantic/product_context.jsonl',
    [string]$SeedProgressPath = '',
    [string]$OutDir = 'artifacts/semantic-plan',
    [int]$ShardCount = 4
)
$ErrorActionPreference = 'Stop'
function Fail-Plan([string]$Message) { Write-Host ("::error title=V4-C2 semantic planner::" + $Message); throw $Message }
function Notice-Plan([string]$Message) { Write-Host ("::notice title=V4-C2 semantic planner::" + $Message) }
function Read-Jsonl([string]$Path) { if (-not (Test-Path $Path)) { Fail-Plan "JSONL not found: $Path" }; $items=@(); Get-Content $Path -Encoding UTF8 | ForEach-Object { if (-not [string]::IsNullOrWhiteSpace($_)) { $items += ($_ | ConvertFrom-Json) } }; return $items }
function Write-Jsonl([string]$Path,$Items) { $dir=Split-Path -Parent $Path; if(-not[string]::IsNullOrWhiteSpace($dir)){New-Item -ItemType Directory -Force $dir|Out-Null}; $enc=New-Object System.Text.UTF8Encoding($false); $lines=@(); foreach($item in @($Items)){$lines+=($item|ConvertTo-Json -Depth 20 -Compress)}; [System.IO.File]::WriteAllLines($Path,$lines,$enc) }

$queue=@(Read-Jsonl $QueuePath); $context=@(Read-Jsonl $ContextPath)
Notice-Plan "loaded queue=$($queue.Count) context=$($context.Count)"
if($queue.Count-ne1544){Fail-Plan "V4-C1 semantic queue must stay at 1544; got $($queue.Count)"}
$ctxByProduct=@{}; foreach($c in $context){$k=[string]($c.product_id);if([string]::IsNullOrWhiteSpace($k)){Fail-Plan 'Blank product_id in semantic context'};$ctxByProduct[$k]=$c}
if($ctxByProduct.Count-ne214){Fail-Plan "Expected exactly 214 pending-product context records; got $($ctxByProduct.Count)"}
$queueBySeq=@{};$missingShaQueue=0
foreach($q in $queue){$seq=[int]($q.sequence);if($queueBySeq.ContainsKey($seq)){Fail-Plan "Duplicate pending sequence: $seq"};$pk=[string]($q.product_id);if(-not$ctxByProduct.ContainsKey($pk)){Fail-Plan "Missing product context: sequence=$seq product=$pk"};if([string]::IsNullOrWhiteSpace([string]($q.sha256))){$missingShaQueue++};$queueBySeq[$seq]=$q}
Notice-Plan "queue_map=$($queueBySeq.Count) missing_sha=$missingShaQueue"
if($queueBySeq.Count-ne1544){Fail-Plan "Queue sequence map mismatch: $($queueBySeq.Count)"}
if($missingShaQueue-ne50){Fail-Plan "Frozen V4-C1 queue must expose exactly 50 legacy SHA gaps; got $missingShaQueue"}
New-Item -ItemType Directory -Force $OutDir|Out-Null

if($Mode-eq'Smoke'){
 $smoke=@(Read-Jsonl $SmokeManifestPath);if($smoke.Count-ne160){Fail-Plan "Smoke must contain exactly 160 images; got $($smoke.Count)"}
 $smokeSeq=@{};$families=@{};$subcats=@{};$products=@{};$missingShaSmoke=0
 foreach($s in $smoke){$seq=[int]($s.sequence);if($smokeSeq.ContainsKey($seq)){Fail-Plan "Duplicate smoke sequence: $seq"};if(-not$queueBySeq.ContainsKey($seq)){Fail-Plan "Smoke sequence is not V4-C1 PENDING: $seq"};$qr=$queueBySeq[$seq];$ss=[string]($s.sha256);$qs=[string]($qr.sha256);if($ss-ne$qs){Fail-Plan "Smoke SHA field differs from frozen queue at sequence $seq"};if([string]::IsNullOrWhiteSpace($ss)){$missingShaSmoke++};$f=[string]($s.family);$sc=[string]($s.subcategory);$p=[string]($s.product_id);$smokeSeq[$seq]=$true;$families[$f]=$true;$subcats[($f+'/'+$sc)]=$true;$products[$p]=$true}
 Notice-Plan "smoke=160 products=$($products.Count) families=$($families.Count) subcategories=$($subcats.Count) missing_sha=$missingShaSmoke sequence7=$($smokeSeq.ContainsKey(7))"
 if(-not$smokeSeq.ContainsKey(7)){Fail-Plan 'Smoke missing canonical sequence 7 for SHA reuse 13 -> 7'}
 foreach($r in @('sports','apparel','shoes','bags')){if(-not$families.ContainsKey($r)){Fail-Plan "Smoke missing family: $r"}}
 if($subcats.Count-ne13){Fail-Plan "Smoke subcategory coverage must be 13; got $($subcats.Count)"};if($products.Count-ne127){Fail-Plan "Smoke unique products must be 127; got $($products.Count)"};if($missingShaSmoke-ne9){Fail-Plan "Smoke must include 9 frozen legacy SHA-gap BLOCK probes; got $missingShaSmoke"}
 Write-Jsonl (Join-Path $OutDir 'smoke_manifest.jsonl') $smoke
 [ordered]@{mode='Smoke';queue_count=1544;smoke_count=160;unique_products=127;family_count=4;subcategory_count=13;missing_sha_queue=50;missing_sha_smoke=9;forced_canonical_sequence=7;duplicate_probe_sequence=13;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;vision_api_called=$false;source_pipeline_redownload=$false}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutDir 'plan_summary.json') -Encoding UTF8
 Write-Host 'SEMANTIC_SMOKE_COUNT=160';Write-Host 'SEMANTIC_SMOKE_UNIQUE_PRODUCTS=127';Write-Host 'SEMANTIC_SMOKE_FAMILIES=4';Write-Host 'SEMANTIC_SMOKE_SUBCATEGORIES=13';Write-Host 'SEMANTIC_SMOKE_MISSING_V4C1_SHA=9';Write-Host 'SOURCE_PIPELINE_REDOWNLOAD=false';return
}

if([string]::IsNullOrWhiteSpace($SeedProgressPath)-or-not(Test-Path $SeedProgressPath)){Fail-Plan 'Full mode requires successful smoke progress'}
$seed=@(Read-Jsonl $SeedProgressPath);$terminalPending=@{}
foreach($r in $seed){$status=[string]($r.semantic_status);$seq=[int]($r.sequence);if($status-in@('DONE','BLOCKED')){if($queueBySeq.ContainsKey($seq)){$terminalPending[$seq]=$true}}}
if($terminalPending.Count-ne160){Fail-Plan "Smoke terminal pending must be 160; got $($terminalPending.Count)"}
$remaining=@();foreach($q in $queue){$seq=[int]($q.sequence);if(-not$terminalPending.ContainsKey($seq)){$remaining+=$q}}
if($remaining.Count-ne1384){Fail-Plan "Expected 1384 remaining; got $($remaining.Count)"};if($ShardCount-lt1){Fail-Plan 'ShardCount must be >=1'}
$shardDir=Join-Path $OutDir 'shards';New-Item -ItemType Directory -Force $shardDir|Out-Null;$matrix=@()
for($i=0;$i-lt$ShardCount;$i++){$name=('semantic-{0:d3}'-f($i+1));$items=@();for($j=$i;$j-lt$remaining.Count;$j+=$ShardCount){$items+=$remaining[$j]};Write-Jsonl (Join-Path $shardDir ($name+'.jsonl')) $items;$matrix+=[ordered]@{shard=$name;count=$items.Count}}
$enc=New-Object System.Text.UTF8Encoding($false);[System.IO.File]::WriteAllText((Join-Path $OutDir 'matrix.json'),([ordered]@{include=$matrix}|ConvertTo-Json -Depth 10 -Compress),$enc)
[ordered]@{mode='Full';queue_count=1544;smoke_terminal_pending=160;remaining_count=1384;missing_sha_queue=50;shard_count=$ShardCount;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;vision_api_called=$false;source_pipeline_redownload=$false}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutDir 'plan_summary.json') -Encoding UTF8
Write-Host 'SEMANTIC_FULL_REMAINING=1384';Write-Host "SEMANTIC_FULL_SHARDS=$ShardCount"
