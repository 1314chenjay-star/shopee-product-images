param(
  [string]$InventoryPath='_system/v4c/inventory/source_inventory.jsonl',
  [string]$SourceProgressPath='_system/v4c/progress/v4c_source_progress.jsonl',
  [string]$DuplicateMapPath='_system/v4c/results/duplicate_map.json',
  [string]$OutDir='artifacts/preservation-plan'
)
$ErrorActionPreference='Stop'
function Read-Jsonl([string]$Path){if(-not(Test-Path $Path)){throw "Missing JSONL: $Path"};$a=@();Get-Content $Path -Encoding UTF8|ForEach-Object{if(-not[string]::IsNullOrWhiteSpace($_)){$a+=($_|ConvertFrom-Json)}};return $a}
function Write-Jsonl([string]$Path,$Items){$d=Split-Path -Parent $Path;if($d){New-Item -ItemType Directory -Force $d|Out-Null};$e=New-Object System.Text.UTF8Encoding($false);$lines=@();foreach($x in @($Items)){$lines+=($x|ConvertTo-Json -Depth 20 -Compress)};[IO.File]::WriteAllLines($Path,$lines,$e)}
$inv=@(Read-Jsonl $InventoryPath);$prog=@(Read-Jsonl $SourceProgressPath)
if($inv.Count-ne2394){throw "Frozen inventory count changed: $($inv.Count)"};if($prog.Count-ne2394){throw "Frozen progress count changed: $($prog.Count)"}
$pBySeq=@{};foreach($p in $prog){$pBySeq[[int]$p.sequence]=$p}
$rows=@();foreach($i in $inv){$s=[int]$i.sequence;if(-not$pBySeq.ContainsKey($s)){throw "Missing V4-C1 progress sequence $s"};$p=$pBySeq[$s];$sha=[string]$p.sha256;$rows+=[pscustomobject]@{sequence=$s;source_id=[string]$i.source_id;product_id=[string]$i.product_id;image_index=[int]$i.image_index;image_type=[string]$i.image_type;url=[string]$i.url;source_action=[string]$i.source_action;sha256=$sha.ToLowerInvariant();v4c1_status=[string]$p.status}}
$groups=@($rows|Group-Object product_id|ForEach-Object{[pscustomobject]@{product_id=$_.Name;first_sequence=(@($_.Group|Measure-Object sequence -Minimum).Minimum);rows=@($_.Group|Sort-Object sequence)}}|Sort-Object first_sequence)
$selected=@();$selectedProducts=@{};$targetMin=160;$targetMax=190
function Add-Group($g){foreach($r in @($g.rows)){$script:selected+=$r};$script:selectedProducts[[string]$g.product_id]=$true}
$dupProduct=@($groups|Where-Object{(@($_.rows|Where-Object{[int]$_.sequence-eq7})).Count-gt0})
if($dupProduct.Count-ne1){throw 'Unable to locate duplicate-probe product containing sequence 7'}
foreach($r in @($dupProduct[0].rows)){if(([string]$r.sha256)-notmatch'^[a-f0-9]{64}$'){throw "Duplicate-probe product has missing V4-C1 SHA at sequence $($r.sequence)"}}
Add-Group $dupProduct[0]
foreach($g in $groups){if($selectedProducts.ContainsKey([string]$g.product_id)){continue};$valid=$true;foreach($r in @($g.rows)){if(([string]$r.sha256)-notmatch'^[a-f0-9]{64}$'){$valid=$false;break}};if(-not$valid){continue};$next=$selected.Count+$g.rows.Count;if($next-le$targetMax){Add-Group $g};if($selected.Count-ge$targetMin){break}}
if($selected.Count-lt100-or$selected.Count-gt200){throw "Preservation smoke must be 100-200 images; got $($selected.Count)"}
$seqs=@{};foreach($r in $selected){if($seqs.ContainsKey([int]$r.sequence)){throw "Duplicate smoke sequence $($r.sequence)"};$seqs[[int]$r.sequence]=$true}
if(-not$seqs.ContainsKey(7)-or-not$seqs.ContainsKey(13)){throw 'Smoke must include SHA duplicate pair sequences 7 and 13'}
$dups=Get-Content $DuplicateMapPath -Raw -Encoding UTF8|ConvertFrom-Json;$pair=@($dups.sha256_duplicates|Where-Object{[int]$_.sequence-eq13-and[int]$_.canonical_sequence-eq7});if($pair.Count-ne1){throw 'Frozen duplicate map no longer contains 13 -> 7'}
New-Item -ItemType Directory -Force $OutDir|Out-Null;Write-Jsonl (Join-Path $OutDir 'preservation_smoke_manifest.jsonl') $selected
$main=@($selected|Where-Object{[int]$_.image_index-eq0}).Count;$detail=$selected.Count-$main
[ordered]@{phase='Smoke';smoke_count=$selected.Count;product_count=$selectedProducts.Count;main_image_count=$main;detail_image_count=$detail;sha_duplicate_probe='13->7';all_have_v4c1_sha=$true;v4c1_baseline_head='a7447b792e65780bc95aa248b9e3a2fd0466f142';image_generation_called=$false;tiny_snow_api_called=$false;paid_api_called=$false;source_pipeline_redownload=$false}|ConvertTo-Json -Depth 10|Set-Content (Join-Path $OutDir 'plan_summary.json') -Encoding UTF8
Write-Host "PRESERVATION_SMOKE_COUNT=$($selected.Count)";Write-Host "PRESERVATION_PRODUCT_COUNT=$($selectedProducts.Count)";Write-Host "PRESERVATION_MAIN_COUNT=$main";Write-Host "PRESERVATION_DETAIL_COUNT=$detail";Write-Host 'SHA_DUPLICATE_PROBE=13->7';Write-Host 'IMAGE_GENERATION_CALLED=false';Write-Host 'TINY_SNOW_API_CALLED=false'
