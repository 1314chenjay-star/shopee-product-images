param(
    [Parameter(Mandatory=$false)][string]$InventoryPath = "_system/v4c/inventory/source_inventory.jsonl",
    [Parameter(Mandatory=$false)][string]$BaseProgressPath,
    [Parameter(Mandatory=$false)][string]$ShardResultRoot,
    [Parameter(Mandatory=$false)][string]$OutputDir = "_system/v4c/runtime/aggregate",
    [Parameter(Mandatory=$false)][string]$Phase = "Smoke",
    [Parameter(Mandatory=$false)][switch]$SelfTest
)
Set-StrictMode -Version 2.0
$ErrorActionPreference="Stop"
$Utf8NoBom=New-Object Text.UTF8Encoding($false)
function Write-Text([string]$Path,[string]$Text){$p=Split-Path -Parent $Path;if($p -and -not(Test-Path $p)){New-Item -ItemType Directory -Force -Path $p|Out-Null};[IO.File]::WriteAllText($Path,$Text,$Utf8NoBom)}
function Read-JL([string]$Path){$a=@();if(-not(Test-Path $Path)){return ,$a};foreach($l in [IO.File]::ReadAllLines($Path,$Utf8NoBom)){if([string]::IsNullOrWhiteSpace($l)){continue};$a+=($l|ConvertFrom-Json)};return ,$a}
function Ensure-Inventory([string]$Path){
    $first=Get-Content -LiteralPath $Path -TotalCount 1 -Encoding UTF8
    try{$o=$first|ConvertFrom-Json}catch{return}
    if(-not($o.PSObject.Properties.Name -contains "bootstrap") -or -not [bool]$o.bootstrap){return}
    $expectedSha=if($o.PSObject.Properties.Name -contains "inventory_sha256"){[string]$o.inventory_sha256}else{""}
    $dir=Split-Path -Parent $Path
    $b=Join-Path $dir "source_inventory.bootstrap.gz.b64"
    $partsDir=Join-Path $dir "source_inventory.bootstrap.parts"
    if(Test-Path $b){$encoded=([IO.File]::ReadAllText($b,$Utf8NoBom)).Trim()}elseif(Test-Path $partsDir){$encoded="";foreach($part in @(Get-ChildItem -LiteralPath $partsDir -File|Sort-Object Name)){$encoded+=([IO.File]::ReadAllText($part.FullName,$Utf8NoBom)).Trim()}}else{throw "Bootstrap inventory missing"}
    $bytes=[Convert]::FromBase64String($encoded)
    $ms=New-Object IO.MemoryStream(,$bytes);$gz=New-Object IO.Compression.GZipStream($ms,[IO.Compression.CompressionMode]::Decompress);$out=[IO.File]::Create($Path)
    try{$gz.CopyTo($out)}finally{$out.Dispose();$gz.Dispose();$ms.Dispose()}
    if(-not[string]::IsNullOrWhiteSpace($expectedSha)){$actual=(Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant();if($actual -ne $expectedSha.ToLowerInvariant()){throw "Expanded inventory SHA256 mismatch"}}
}
function Invoke-SelfTest {
    $same="abc";$r=@([pscustomobject]@{sequence=1;sha256=$same},[pscustomobject]@{sequence=2;sha256=$same});$hash=@{};$dupes=0
    foreach($x in ($r|Sort-Object sequence)){if($hash.ContainsKey($x.sha256)){$dupes++}else{$hash[$x.sha256]=[int]$x.sequence}}
    $passed=($dupes -eq 1);$s=[ordered]@{passed=$passed;sha_duplicate_not_reanalyzed=$passed;sha_duplicate_count=$dupes;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false}
    Write-Host "SELFTEST_RESULT=$($s|ConvertTo-Json -Compress)";if(-not $passed){throw "v4c_aggregate_results self-test failed"}
}
if($SelfTest){Invoke-SelfTest;exit 0}
if([string]::IsNullOrWhiteSpace($BaseProgressPath)){throw "BaseProgressPath required"}
if([string]::IsNullOrWhiteSpace($ShardResultRoot)){throw "ShardResultRoot required"}
Ensure-Inventory $InventoryPath
$inventory=@(Read-JL $InventoryPath|Sort-Object {[int]$_.sequence});$base=@(Read-JL $BaseProgressPath);$map=@{}
foreach($p in $base){if($p.PSObject.Properties.Name -contains "sequence"){$map[[int]$p.sequence]=$p}}
if($map.Count -ne $inventory.Count){throw "Base progress must reconcile to inventory: $($map.Count)/$($inventory.Count)"}
$resultFiles=@(Get-ChildItem -LiteralPath $ShardResultRoot -Recurse -File -Filter "*.progress.jsonl" -ErrorAction SilentlyContinue);$seenResult=@{}
foreach($f in $resultFiles){foreach($r in @(Read-JL $f.FullName)){$seq=[int]$r.sequence;if($seenResult.ContainsKey($seq)){throw "Sequence $seq appears in more than one shard result"};$seenResult[$seq]=$true;if(-not $map.ContainsKey($seq)){throw "Shard result sequence $seq not in inventory"};$baseRec=$map[$seq];$merged=[ordered]@{};foreach($prop in $baseRec.PSObject.Properties){$merged[$prop.Name]=$prop.Value};foreach($prop in $r.PSObject.Properties){$merged[$prop.Name]=$prop.Value};$map[$seq]=[pscustomobject]$merged}}
$shaCanon=@{};$shaDupes=New-Object Collections.Generic.List[object]
foreach($seq in ($map.Keys|Sort-Object)){$p=$map[$seq];if([string]$p.status -ne "DONE"){continue};if(-($p.PSObject.Properties.Name -contains "sha256") -or [string]::IsNullOrWhiteSpace([string]$p.sha256)){throw "DONE without SHA256 at $seq"};$sha=([string]$p.sha256).ToLowerInvariant();if($shaCanon.ContainsKey($sha)){$canon=[int]$shaCanon[$sha];$h=[ordered]@{};foreach($prop in $p.PSObject.Properties){$h[$prop.Name]=$prop.Value};$h["status"]="SHA_DUPLICATE";$h["semantic_status"]="SKIP_DUPLICATE";$h["sha_duplicate_of_sequence"]=$canon;$map[$seq]=[pscustomobject]$h;$shaDupes.Add([pscustomobject]@{sequence=$seq;sha256=$sha;canonical_sequence=$canon})}else{$shaCanon[$sha]=[int]$seq}}
$ordered=New-Object Collections.Generic.List[object];foreach($src in $inventory){$ordered.Add($map[[int]$src.sequence])}
$urlDupes=@($ordered|Where-Object{$_.status -eq "URL_DUPLICATE"}|ForEach-Object{[pscustomobject]@{sequence=[int]$_.sequence;url=[string]$_.url;canonical_sequence=[int]$_.canonical_sequence}})
$failed=@($ordered|Where-Object{$_.status -eq "FAILED"});$pending=@($ordered|Where-Object{$_.semantic_status -eq "PENDING" -and $_.status -in @("DONE","LEGACY_DONE")});$hold=@($ordered|Where-Object{$_.semantic_status -eq "HOLD"});$block=@($ordered|Where-Object{$_.semantic_status -eq "BLOCK" -or $_.status -eq "FAILED"})
if(Test-Path $OutputDir){Remove-Item -Recurse -Force $OutputDir};New-Item -ItemType Directory -Force -Path $OutputDir|Out-Null
$progressText=(($ordered|ForEach-Object{$_|ConvertTo-Json -Compress -Depth 14}) -join "`n")+"`n";Write-Text (Join-Path $OutputDir "v4c_source_progress.jsonl") $progressText;Write-Text (Join-Path $OutputDir "source_evidence.jsonl") $progressText
$dup=[ordered]@{url_duplicates=@($urlDupes);sha256_duplicates=@($shaDupes)};Write-Text (Join-Path $OutputDir "duplicate_map.json") (($dup|ConvertTo-Json -Depth 12)+"`n");Write-Text (Join-Path $OutputDir "failed_sources.json") ((@($failed)|ConvertTo-Json -Depth 12)+"`n")
$queueText="";if($pending.Count -gt 0){$queueText=(($pending|ForEach-Object{[pscustomobject]@{sequence=[int]$_.sequence;source_id=[string]$_.source_id;product_id=[string]$_.product_id;url=[string]$_.url;sha256=$(if($_.PSObject.Properties.Name -contains "sha256"){[string]$_.sha256}else{""});reason="semantic_evidence_pending"}|ConvertTo-Json -Compress}) -join "`n")+"`n"};Write-Text (Join-Path $OutputDir "semantic_evidence_queue.jsonl") $queueText
$summary=[ordered]@{phase=$Phase;inventory_count=$inventory.Count;shard_result_count=$seenResult.Count;legacy_done=@($ordered|Where-Object{$_.status -eq "LEGACY_DONE"}).Count;done=@($ordered|Where-Object{$_.status -eq "DONE"}).Count;url_duplicates=$urlDupes.Count;sha256_duplicates=$shaDupes.Count;failed=$failed.Count;semantic_pending=$pending.Count;hold=$hold.Count;block=$block.Count;terminal_count=@($ordered|Where-Object{$_.status -in @("LEGACY_DONE","DONE","URL_DUPLICATE","SHA_DUPLICATE","FAILED")}).Count;image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false}
Write-Text (Join-Path $OutputDir "aggregate_summary.json") (($summary|ConvertTo-Json -Depth 8)+"`n");Write-Host "AGGREGATE_SUMMARY=$($summary|ConvertTo-Json -Compress)"
