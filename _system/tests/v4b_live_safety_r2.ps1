$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$key = [string]$env:TINYSNOW_API_KEY
if ([string]::IsNullOrWhiteSpace($key)) { throw 'TINYSNOW_API_KEY repository secret is missing.' }
$round = if ([string]::IsNullOrWhiteSpace([string]$env:V4B_SAFETY_ROUND)) { 'R2' } else { ([string]$env:V4B_SAFETY_ROUND).Trim().ToUpperInvariant() }
$slug = if ([string]::IsNullOrWhiteSpace([string]$env:V4B_SAFETY_SLUG)) { $round.ToLowerInvariant() } else { ([string]$env:V4B_SAFETY_SLUG).Trim().ToLowerInvariant() }
if ($slug -notmatch '^[a-z0-9_-]+$') { throw ('V4B_SAFETY_SLUG is invalid: ' + $slug) }
$artifactName = if ([string]::IsNullOrWhiteSpace([string]$env:V4B_ARTIFACT_NAME)) { 'TinySnow-V4-B-Safety-' + $round } else { ([string]$env:V4B_ARTIFACT_NAME).Trim() }
$outDirName = 'live_e2e_output_v4b_safety_' + $slug
$outDir = Join-Path $systemRoot $outDirName
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$config = [pscustomobject]@{api_key=$key;base_url='https://tinysnow.one/v1';model='gpt-image-2';quality='medium';size='1024x1024';safe_test_mode=$true;max_reference_images=2;transport_profile='r3_120s_safe'}

function Assert-LiveR2([bool]$Condition,[string]$Message){if(-not $Condition){throw('V4-B safety R2 live failed: '+$Message)}}
function New-ProductR2([string]$ProductId,[string]$Name,[string]$Category,[string[]]$Urls,[string]$VariationName,[string[]]$Options){
    $h=@{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image'};$d=@{0=$ProductId;1='';2=$Name;3=$Category;4=$Urls[0]}
    for($i=1;$i-lt$Urls.Count;$i++){$c=4+$i;$h[$c]="ps_item_image.$i";$d[$c]=$Urls[$i]}
    $vc=20;$h[$vc]='et_title_variation_1';$d[$vc]=$VariationName
    for($i=1;$i-le$Options.Count;$i++){$c=20+$i;$h[$c]="et_title_option_${i}_for_variation_1";$d[$c]=$Options[$i-1]}
    $p=@(Convert-ShopeeRowsToProducts @($h,$d))[0];if($null-eq$p){throw('Product construction failed: '+$ProductId)};return $p
}
function Save-SelectionR2($Product){$dir=Get-SelectionWorkspaceV2;New-Item -ItemType Directory -Path $dir -Force|Out-Null;$Product|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $dir 'selected_product.json') -Encoding UTF8}
function Prepare-R2($Product){
    Save-SelectionR2 $Product;$download=Download-ProductImagesV2 $Product;$analysis=Analyze-ProductImagesV2 ([string]$Product.product_id) ([string[]]$download.paths);$plan=Get-V4BCurrentSourcePlan
    Assert-LiveR2 ($null-ne$plan) ('source plan missing: '+[string]$Product.product_id)
    return [pscustomobject]@{product=$Product;analysis=$analysis;plan=$plan}
}
function Invoke-R2($Prepared,[string]$Slot){
    $p=$Prepared.product;$id=[string]$p.product_id;Save-SelectionR2 $p;$sp=Get-V4BPlanSlot $Prepared.plan $Slot;$refs=[string[]]@(Get-ReferencesForSlotV2 $Prepared.analysis $Slot 2)
    Assert-LiveR2 ($refs.Count-ge1 -and $refs.Count-le2) ('invalid refs: '+$id)
    $prompt=Get-PromptV2 $Slot $p
    Assert-LiveR2 ($prompt-match'EDIT / PRESERVE / LOCALIZE') ('V4-B mode missing: '+$id)
    Assert-LiveR2 ($prompt-match'來源賣家促銷／承諾清理') ('seller policy cleanup missing: '+$id)
    if([bool]$p.multi_variant_flags.has_multiple_quantities){Assert-LiveR2 ($prompt-match'具體件數、片數、入數、組數、套數、條數') ('quantity conflict cleanup missing: '+$id)}
    $prompt|Set-Content -LiteralPath (Join-Path $outDir ($id+'_'+$Slot+'_prompt.txt')) -Encoding UTF8
    $sp|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $outDir ($id+'_'+$Slot+'_slot_plan.json')) -Encoding UTF8
    for($i=0;$i-lt$refs.Count;$i++){Copy-Item -LiteralPath $refs[$i] -Destination (Join-Path $outDir ($id+'_'+$Slot+'_selected_ref'+($i+1)+'.png')) -Force}
    $apiRefs=[string[]]@(Get-PreparedApiReferencesV2 $id $refs);Write-Host ('[LIVE V4-B SAFETY '+$round+'] '+$id+' / '+$Slot) -ForegroundColor Cyan
    $tmp=Invoke-ImageEditMultiV2 $config $apiRefs $prompt '1024x1024' 'medium';$out=Join-Path $outDir ($id+'_'+$Slot+'_live.jpg');Convert-ToFinalJpegV2 $tmp $out|Out-Null;Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    return [pscustomobject]@{product_id=$id;slot=$Slot;source_mode=[string]$sp.source_mode;output_file=(Split-Path $out -Leaf);bytes=(Get-Item -LiteralPath $out).Length;sha256=(Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash.ToLowerInvariant()}
}

$u580=[string[]]@('https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57','https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrpfv1ftvdonbb','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259p-mrpfv1zcms5g87','https://s-cf-tw.shopeesz.com/file/sg-11134201-825b2-mrpfv2mgqn7p69','https://s-cf-tw.shopeesz.com/file/sg-11134201-82593-mrpfv3ovpjwle0','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a0-mrpfv4hwe0w66e','https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv6mpe4n5c7','https://s-cf-tw.shopeesz.com/file/sg-11134201-8259l-mrpfv78r80lhdb')
$p580=New-ProductR2 '58015741169' '籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品' 'Sports & Outdoors/Basketball/Training' $u580 '規格' ([string[]]@('黑色2米30磅+腰帶一組','黑色2米30磅+腰帶各5組'))
$a580=Prepare-R2 $p580;$pr580=Get-PromptV2 'detail4' $p580
Assert-LiveR2 ($pr580-notmatch'各5組') '580 variant-only quantity leaked'
foreach($x in @('2公尺','30磅','腰帶','黑色')){Assert-LiveR2 ($pr580-match[regex]::Escape($x)) ('580 common fact missing: '+$x)}

$u529=[string[]]@('https://s-cf-tw.shopeesz.com/file/sg-11134201-825b0-mrpfuutmlerlbc','https://s-cf-tw.shopeesz.com/file/sg-11134201-8258j-mrpfuvlre87892','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a4-mrpfuwav3oxz61','https://s-cf-tw.shopeesz.com/file/sg-11134201-8257t-mrpfuxgjpnuoca','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a9-mrpfuy40nm6g41','https://s-cf-tw.shopeesz.com/file/sg-11134201-8257s-mrpfuyr5b56v5c','https://s-cf-tw.shopeesz.com/file/sg-11134201-82597-mrpfv03xg9a855','https://s-cf-tw.shopeesz.com/file/sg-11134201-82588-mrpfv1k8bpxd4a')
$o529=[string[]]@('藍色-常規肌肉貼20片','藍色-常規肌肉貼40片','藍色-護膝貼10片','藍色-護膝貼20片','膚色-常規肌肉貼20片','膚色-常規肌肉貼40片','膚色-護膝貼10片','膚色-護膝貼20片','黑色-常規肌肉貼20片','黑色-常規肌肉貼40片','黑色-護膝貼10片','黑色-護膝貼20片','粉色-常規肌肉貼20片','粉色-常規肌肉貼40片','粉色-護膝貼10片','粉色-護膝貼20片','綠色-護膝貼10片','綠色-護膝貼20片','紫色-護膝貼10片','紫色-護膝貼20片')
$p529=New-ProductR2 '52915734564' '運動肌貼 肌肉貼布 高彈力運動機能貼 籃球跑步護膝防護貼 透氣彈性貼布 運動防護用品' 'Sports & Outdoors/Basketball/Others' $u529 '顏色/款式' $o529
$a529=Prepare-R2 $p529;$pr529=Get-PromptV2 'detail4' $p529
Assert-LiveR2 ($pr529-notmatch'10片|20片|40片') '529 variant-only quantities leaked'
Assert-LiveR2 ($pr529-match'包退') '529 prompt must explicitly suppress source seller return promise'

$results=@();$results+=Invoke-R2 $a580 'detail4';$results+=Invoke-R2 $a529 'detail4'
$summaryName = 'v4b_safety_' + $slug + '_summary.json'
[pscustomobject]@{
    schema_version=2
    version=('V4-B Safety '+$round)
    round=$round
    head_sha=[string]$env:GITHUB_SHA
    run_id=[string]$env:GITHUB_RUN_ID
    run_attempt=[string]$env:GITHUB_RUN_ATTEMPT
    workflow_name=[string]$env:GITHUB_WORKFLOW
    repository=[string]$env:GITHUB_REPOSITORY
    artifact_name=$artifactName
    artifact_id=$null
    artifact_id_status='assigned_after_payload_upload; see matching artifact receipt and GitHub job summary'
    output_directory=$outDirName
    generated_image_count=2
    tests=[object[]]$results
    visual_review_required=$true
}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $outDir $summaryName) -Encoding UTF8
Write-Host ('[PASS] V4-B Safety '+$round+' technical gate: 580 detail4 + 529 detail4 generated. Summary: '+$summaryName) -ForegroundColor Green
