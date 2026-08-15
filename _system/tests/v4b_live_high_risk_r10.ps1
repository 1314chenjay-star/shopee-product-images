$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$key=[string]$env:TINYSNOW_API_KEY
if([string]::IsNullOrWhiteSpace($key)){throw'TINYSNOW_API_KEY repository secret is missing.'}
$artifactName=if([string]::IsNullOrWhiteSpace([string]$env:V4B_ARTIFACT_NAME)){'TinySnow-V4-B-High-Risk-R10'}else{([string]$env:V4B_ARTIFACT_NAME).Trim()}
$outDirName='live_e2e_output_v4b_high_risk_r10'
$outDir=Join-Path $systemRoot $outDirName
if(Test-Path -LiteralPath $outDir){Remove-Item -LiteralPath $outDir -Recurse -Force}
New-Item -ItemType Directory -Path $outDir -Force|Out-Null
$config=[pscustomobject]@{api_key=$key;base_url='https://tinysnow.one/v1';model='gpt-image-2';quality='medium';size='1024x1024';safe_test_mode=$true;max_reference_images=2;transport_profile='r3_120s_safe'}

function Assert-R10([bool]$Condition,[string]$Message){if(-not$Condition){throw('V4-B high-risk R10 failed: '+$Message)}}
function New-R10Product([string]$Id,[string]$Name,[string]$Category,[string[]]$Urls,[string]$Variation,[string[]]$Options){
    $header=@{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1'}
    $data=@{0=$Id;1='';2=$Name;3=$Category;4=$Urls[0];20=$Variation}
    for($i=1;$i-lt$Urls.Count;$i++){$column=4+$i;$header[$column]='ps_item_image.'+$i;$data[$column]=$Urls[$i]}
    for($i=1; $i -le $Options.Count; $i++){$column=20+$i;$header[$column]='et_title_option_'+$i+'_for_variation_1';$data[$column]=$Options[$i-1]}
    $product=@(Convert-ShopeeRowsToProducts @($header,$data))[0]
    if($null -eq $product){throw('Product construction failed: '+$Id)}
    return $product
}
function Save-R10Selection($Product){$dir=Get-SelectionWorkspaceV2;New-Item -ItemType Directory -Path $dir -Force|Out-Null;$Product|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $dir 'selected_product.json') -Encoding UTF8}
function Prepare-R10($Product){
    Save-R10Selection $Product
    $download=Download-ProductImagesV2 $Product
    $analysis=Analyze-ProductImagesV2 ([string]$Product.product_id) ([string[]]$download.paths)
    $plan=Get-V4BCurrentSourcePlan
    Assert-R10 ($null -ne $plan) ('source plan missing: '+[string]$Product.product_id)
    $validation=Test-V4BSourcePlan $plan $true
    Assert-R10 ([bool]$validation.passed) ('source validation failed: '+(@($validation.errors)-join'; '))
    return [pscustomobject]@{product=$Product;analysis=$analysis;plan=$plan}
}
function Invoke-R10($Prepared,[string]$Slot){
    $product=$Prepared.product;$id=[string]$product.product_id;Save-R10Selection $product
    $slotPlan=Get-V4BPlanSlot $Prepared.plan $Slot
    $prompt=Get-PromptV2 $Slot $product
    $refs=[string[]]@(Get-ReferencesForSlotV2 $Prepared.analysis $Slot 2)
    Assert-R10 ($refs.Count -ge 1 -and $refs.Count -le 2) ('invalid refs: '+$id+'/'+$Slot)
    $prompt|Set-Content -LiteralPath (Join-Path $outDir ($id+'_'+$Slot+'_prompt.txt')) -Encoding UTF8
    $slotPlan|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $outDir ($id+'_'+$Slot+'_slot_plan.json')) -Encoding UTF8
    for($i=0;$i-lt$refs.Count;$i++){Copy-Item -LiteralPath $refs[$i] -Destination (Join-Path $outDir ($id+'_'+$Slot+'_runtime_ref'+($i+1)+'.jpg')) -Force}
    $apiRefs=[string[]]@(Get-PreparedApiReferencesV2 $id $refs)
    Write-Host ('[LIVE V4-B HIGH-RISK R10] '+$id+' / '+$Slot) -ForegroundColor Cyan
    $temporary=Invoke-ImageEditMultiV2 $config $apiRefs $prompt '1024x1024' 'medium'
    $output=Join-Path $outDir ($id+'_'+$Slot+'_live.jpg')
    Convert-ToFinalJpegV2 $temporary $output|Out-Null
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    Assert-R10 ((Test-Path -LiteralPath $output -PathType Leaf) -and (Get-Item -LiteralPath $output).Length -gt 10000) ('output missing: '+$id+'/'+$Slot)
    return [pscustomobject]@{product_id=$id;slot=$Slot;source_indices=[int[]]@($slotPlan.source_indices);source_selection_policy=[string]$slotPlan.source_selection_policy;runtime_reference_strategy=[string]$slotPlan.runtime_reference_strategy;verified_text_policy=[string]$slotPlan.verified_text_policy;output_file=(Split-Path $output -Leaf);bytes=(Get-Item -LiteralPath $output).Length;sha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()}
}

$urls529=[string[]]@(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b0-mrpfuutmlerlbc','https://s-cf-tw.shopeesz.com/file/sg-11134201-8258j-mrpfuvlre87892',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a4-mrpfuwav3oxz61','https://s-cf-tw.shopeesz.com/file/sg-11134201-8257t-mrpfuxgjpnuoca',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a9-mrpfuy40nm6g41','https://s-cf-tw.shopeesz.com/file/sg-11134201-8257s-mrpfuyr5b56v5c',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82597-mrpfv03xg9a855','https://s-cf-tw.shopeesz.com/file/sg-11134201-82588-mrpfv1k8bpxd4a'
)
$options529=[string[]]@('藍色-常規肌肉貼20片','藍色-常規肌肉貼40片','藍色-護膝貼10片','藍色-護膝貼20片','膚色-常規肌肉貼20片','膚色-常規肌肉貼40片','膚色-護膝貼10片','膚色-護膝貼20片','黑色-常規肌肉貼20片','黑色-常規肌肉貼40片','黑色-護膝貼10片','黑色-護膝貼20片','粉色-常規肌肉貼20片','粉色-常規肌肉貼40片','粉色-護膝貼10片','粉色-護膝貼20片','綠色-護膝貼10片','綠色-護膝貼20片','紫色-護膝貼10片','紫色-護膝貼20片')
$product529=New-R10Product '52915734564' '運動肌貼 肌肉貼布 高彈力運動機能貼 籃球跑步護膝防護貼 透氣彈性貼布 運動防護用品' 'Sports & Outdoors/Basketball/Others' $urls529 '顏色/款式' $options529
$prepared529=Prepare-R10 $product529
Assert-R10 ([bool]$prepared529.plan.high_variant_conflict -and [bool]$prepared529.plan.quantity_conflict) '529 conflict flags missing'
$plan529=Get-V4BPlanSlot $prepared529.plan 'detail4'
Assert-R10 ([bool]$plan529.text_shield_required -and [string]$plan529.verified_text_policy -eq 'deterministic_overlay_only') '529 detail4 deterministic text shield missing'
$content529=Get-V4BVerifiedOverlayContent $product529 'detail4'
Assert-R10 ([string]$content529.title -eq '運動肌貼') '529 safe Taiwan title mismatch'
Assert-R10 ([string]$content529.secondary -match '數量規格可選' -and [string]$content529.secondary -match '規格請依選項為準') '529 safe neutral overlay missing'
Assert-R10 ([string]$content529.secondary -notmatch '10片|20片|40片') '529 quantity leaked into overlay'
$prompt529=Get-PromptV2 'detail4' $product529
Assert-R10 ($prompt529 -notmatch '10片|20片|40片') '529 quantity leaked into prompt'

$urls575=[string[]]@(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259g-mrpfuzzrmcjo62','https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv0x43n5t1a',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a3-mrpfv1r0chl227','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a6-mrpfv2cg1xjafd',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82588-mrpfv2vst24gdd'
)
$product575=New-R10Product '57565745174' '排球訓練器材 墊球阻力帶 排球控球輔助訓練器 傳球墊球練習用品 學生球隊訓練裝備' 'Sports & Outdoors/Volleyball/Others' $urls575 '款式' ([string[]]@('美璐捷排球訓練器材(VZJ-004S)'))
$prepared575=Prepare-R10 $product575
Assert-R10 (@($product575.verified_facts.verified_models) -contains 'VZJ-004S') '575 verified model missing'
Assert-R10 (@($product575.verified_facts.verified_materials).Count -eq 0) '575 material must remain unverified'
$prompt575=Get-PromptV2 'detail1' $product575
Assert-R10 ($prompt575 -match 'VZJ-004S') '575 verified model missing from prompt'
Assert-R10 ($prompt575 -notmatch '尼龍|D-ring|D環|附球|提升防守|增強防守|有效限制過度移動') '575 unsupported material/accessory/performance leaked into prompt'

$results=@()
$results+=Invoke-R10 $prepared529 'detail4'
$results+=Invoke-R10 $prepared575 'detail1'
Assert-R10 (@($results|ForEach-Object{$_.sha256}|Select-Object -Unique).Count -eq 2) 'R10 outputs must have distinct hashes'
[pscustomobject]@{
    schema_version=2;version='V4-B High-Risk R10';round='R10';head_sha=[string]$env:GITHUB_SHA;run_id=[string]$env:GITHUB_RUN_ID;
    run_attempt=[string]$env:GITHUB_RUN_ATTEMPT;workflow_name=[string]$env:GITHUB_WORKFLOW;repository=[string]$env:GITHUB_REPOSITORY;
    artifact_name=$artifactName;artifact_id=$null;artifact_id_status='assigned after payload upload; see v4b_high_risk_r10_artifact_receipt.json and GitHub job summary';
    output_directory=$outDirName;test_scope=[string[]]@('52915734564/detail4','57565745174/detail1');generated_image_count=2;
    tests=[object[]]$results;visual_review_required=$true;excluded_case='42833435408 has no verified source URLs in repository or supplied handoff; no live claim made'
}|ConvertTo-Json -Depth 12|Set-Content -LiteralPath (Join-Path $outDir 'v4b_high_risk_r10_summary.json') -Encoding UTF8
Write-Host '[PASS] V4-B High-Risk R10 technical gate: 529 detail4 + 575 detail1 generated. Visual review required; 428 remains untested without sources.' -ForegroundColor Green
