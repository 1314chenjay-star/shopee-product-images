$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot=Split-Path $PSScriptRoot -Parent
$startRoot=Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$key=[string]$env:TINYSNOW_API_KEY
if([string]::IsNullOrWhiteSpace($key)){throw'TINYSNOW_API_KEY repository secret is missing.'}
$artifactName=if([string]::IsNullOrWhiteSpace([string]$env:V4B_ARTIFACT_NAME)){'TinySnow-V4-B-575-R11'}else{([string]$env:V4B_ARTIFACT_NAME).Trim()}
$outDirName='live_e2e_output_v4b_575_r11'
$outDir=Join-Path $systemRoot $outDirName
if(Test-Path -LiteralPath $outDir){Remove-Item -LiteralPath $outDir -Recurse -Force}
New-Item -ItemType Directory -Path $outDir -Force|Out-Null
$config=[pscustomobject]@{api_key=$key;base_url='https://tinysnow.one/v1';model='gpt-image-2';quality='medium';size='1024x1024';safe_test_mode=$true;max_reference_images=2;transport_profile='r3_120s_safe'}
function Assert-R11([bool]$Condition,[string]$Message){if(-not$Condition){throw('V4-B 575 R11 failed: '+$Message)}}

$urls=[string[]]@(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259g-mrpfuzzrmcjo62','https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv0x43n5t1a',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a3-mrpfv1r0chl227','https://s-cf-tw.shopeesz.com/file/sg-11134201-825a6-mrpfv2cg1xjafd',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82588-mrpfv2vst24gdd'
)
$header=@{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1';21='et_title_option_1_for_variation_1'}
$data=@{0='57565745174';1='';2='排球訓練器材 墊球阻力帶 排球控球輔助訓練器 傳球墊球練習用品 學生球隊訓練裝備';3='Sports & Outdoors/Volleyball/Others';4=$urls[0];20='款式';21='美璐捷排球訓練器材(VZJ-004S)'}
for($i=1;$i-lt$urls.Count;$i++){$column=4+$i;$header[$column]='ps_item_image.'+$i;$data[$column]=$urls[$i]}
$product=@(Convert-ShopeeRowsToProducts @($header,$data))[0]
Assert-R11 ($null -ne $product) '575 product construction failed'
Assert-R11 (@($product.verified_facts.verified_models) -contains 'VZJ-004S') 'verified model missing'
Assert-R11 (@($product.verified_facts.verified_materials).Count -eq 0) 'material must remain unverified'
$selectionDir=Get-SelectionWorkspaceV2;New-Item -ItemType Directory -Path $selectionDir -Force|Out-Null
$product|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $selectionDir 'selected_product.json') -Encoding UTF8
$download=Download-ProductImagesV2 $product
$analysis=Analyze-ProductImagesV2 '57565745174' ([string[]]$download.paths)
$plan=Get-V4BCurrentSourcePlan
Assert-R11 ($null -ne $plan) 'source plan missing'
$validation=Test-V4BSourcePlan $plan $true
Assert-R11 ([bool]$validation.passed) ('source plan validation failed: '+(@($validation.errors)-join'; '))
$slotPlan=Get-V4BPlanSlot $plan 'detail1'
Assert-R11 ([bool]$slotPlan.text_shield_required) '575 detail1 source-text shield missing'
Assert-R11 ([string]$slotPlan.text_shield_reason -eq 'sparse_verified_facts_source_text_risk') '575 detail1 shield reason mismatch'
Assert-R11 ([string]$slotPlan.verified_text_policy -eq 'deterministic_overlay_only') '575 detail1 must use deterministic overlay'
Assert-R11 ([int]$slotPlan.reference_proxy_max_edge -eq 384) '575 detail1 must use 384px proxy'

$content=Get-V4BVerifiedOverlayContent $product 'detail1'
Assert-R11 ([string]$content.title -match '排球訓練') '575 safe Taiwan product title missing'
Assert-R11 ([string]$content.secondary -match 'VZJ-004S') '575 verified model missing from overlay'
Assert-R11 ([string]$content.secondary -notmatch '公分|尼龍|金屬|耐用|穩固|尺寸') '575 overlay invented dimensions/material/performance'
$prompt=Get-PromptV2 'detail1' $product
Assert-R11 ($prompt -match '不要生成任何可辨識文字') '575 TinySnow stage must be text-free'
Assert-R11 ($prompt -match 'sparse_verified_facts_source_text_risk') '575 prompt missing source-text shield reason'
Assert-R11 ($prompt -notmatch '26公分|20公分|13公分|10公分|金屬環扣|加厚織帶|多尺寸選擇') '575 prompt seeded prior failed output text'

$runtimeRefs=[string[]]@(Get-ReferencesForSlotV2 $analysis 'detail1' 2)
Assert-R11 ($runtimeRefs.Count -eq 1) '575 detail1 must use one runtime reference'
Assert-R11 ([IO.Path]::GetFileNameWithoutExtension($runtimeRefs[0]) -match '_safe$') '575 detail1 must use text-shield proxy'
$analysis|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $outDir '57565745174_analysis_r11.json') -Encoding UTF8
$plan|ConvertTo-Json -Depth 16|Set-Content -LiteralPath (Join-Path $outDir '57565745174_source_plan_r11.json') -Encoding UTF8
$slotPlan|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $outDir '57565745174_detail1_slot_plan.json') -Encoding UTF8
$prompt|Set-Content -LiteralPath (Join-Path $outDir '57565745174_detail1_prompt.txt') -Encoding UTF8
Copy-Item -LiteralPath ([string]$slotPlan.source_paths[0]) -Destination (Join-Path $outDir '57565745174_detail1_selected_original.png') -Force
Copy-Item -LiteralPath $runtimeRefs[0] -Destination (Join-Path $outDir '57565745174_detail1_runtime_ref.jpg') -Force

$apiRefs=[string[]]@(Get-PreparedApiReferencesV2 '57565745174' $runtimeRefs)
Write-Host '[LIVE V4-B 575 R11] 57565745174 / detail1' -ForegroundColor Cyan
$temporary=Invoke-ImageEditMultiV2 $config $apiRefs $prompt '1024x1024' 'medium'
$output=Join-Path $outDir '57565745174_detail1_live.jpg'
Convert-ToFinalJpegV2 $temporary $output|Out-Null
Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
Assert-R11 ((Test-Path -LiteralPath $output -PathType Leaf) -and (Get-Item -LiteralPath $output).Length -gt 10000) '575 detail1 output missing'
$hash=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
    schema_version=2;version='V4-B 575 R11';round='R11';head_sha=[string]$env:GITHUB_SHA;run_id=[string]$env:GITHUB_RUN_ID;
    run_attempt=[string]$env:GITHUB_RUN_ATTEMPT;workflow_name=[string]$env:GITHUB_WORKFLOW;repository=[string]$env:GITHUB_REPOSITORY;
    artifact_name=$artifactName;artifact_id=$null;artifact_id_status='assigned after payload upload; see v4b_575_r11_artifact_receipt.json and GitHub job summary';
    output_directory=$outDirName;test_scope=[string[]]@('57565745174/detail1');generated_image_count=1;source_index=[int]$slotPlan.source_indices[0];
    text_shield_reason=[string]$slotPlan.text_shield_reason;verified_text_policy=[string]$slotPlan.verified_text_policy;safe_overlay_title=[string]$content.title;
    output_file=(Split-Path $output -Leaf);bytes=(Get-Item -LiteralPath $output).Length;sha256=$hash;visual_review_required=$true
}|ConvertTo-Json -Depth 10|Set-Content -LiteralPath (Join-Path $outDir 'v4b_575_r11_summary.json') -Encoding UTF8
Write-Host '[PASS] V4-B 575 R11 technical gate: sparse-fact source-text shield plus deterministic overlay. Visual review required.' -ForegroundColor Green
