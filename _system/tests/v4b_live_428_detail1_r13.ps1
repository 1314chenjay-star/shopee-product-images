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
$artifactName = if ([string]::IsNullOrWhiteSpace([string]$env:V4B_ARTIFACT_NAME)) { 'TinySnow-V4-B-428-R13' } else { ([string]$env:V4B_ARTIFACT_NAME).Trim() }
$outDirName = 'live_e2e_output_v4b_428_r13'
$outDir = Join-Path $systemRoot $outDirName
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$config = [pscustomobject]@{api_key=$key;base_url='https://tinysnow.one/v1';model='gpt-image-2';quality='medium';size='1024x1024';safe_test_mode=$true;max_reference_images=2;transport_profile='r3_120s_safe'}
function Assert-R13([bool]$Condition,[string]$Message) { if (-not $Condition) { throw ('V4-B 428 R13 failed: ' + $Message) } }

$urls = [string[]]@(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825ap-mrpfutt4ncp41f',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825au-mrpfuuls51qgc0',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259z-mrpfuvcqstttff',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825az-mrpfuvy05b7s56',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82587-mrpfux6j2cqqff',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8258l-mrpfuxtu721481',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82595-mrpfuyp7gsncb8',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv0wxe32cf0',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8257w-mrpfv1qfv1fo7f'
)
$options = [string[]]@('粉標黑色','粉標白色','白標黑色','黑標白色','黑內光板','白內光板','粉標火焰黑','白標火焰黑','粉標火焰白','黑標火焰白','BRRO【粉标】黑色【速干透气】')
$header = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1'}
$data = @{0='42833435408';1='';2='籃球短褲 男款寬鬆五分褲 假兩件設計 速乾透氣運動短褲 夏季籃球訓練休閒褲';3='101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others';4=$urls[0];20='款式'}
for ($i=1; $i -lt $urls.Count; $i++) { $column=4+$i; $header[$column]='ps_item_image.'+$i; $data[$column]=$urls[$i] }
for ($i=1; $i -le $options.Count; $i++) { $column=20+$i; $header[$column]="et_title_option_${i}_for_variation_1"; $data[$column]=$options[$i-1] }

$product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
Assert-R13 ($null -ne $product) '428 product construction failed'
Assert-R13 ([string]$product.product_id -eq '42833435408') '428 product ID changed'
Assert-R13 (@($product.variants).Count -eq 11) 'variant count mismatch'
Assert-R13 ([string](Get-V4BSafeProductLabel $product) -eq '籃球短褲') 'safe Taiwan label must be 籃球短褲'
$facts = $product.verified_facts
foreach ($property in @('verified_dimensions','verified_materials','verified_accessories','verified_gifts','verified_bundle_contents','verified_colors','verified_sizes','verified_models','verified_quantities','verified_features','verified_use_cases','verified_certifications')) {
    Assert-R13 (@(Get-V4A1Property $facts $property @()).Count -eq 0) ('unverified common fact leaked: ' + $property)
}

$selectionDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selectionDir -Force | Out-Null
$product | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $selectionDir 'selected_product.json') -Encoding UTF8
$download = Download-ProductImagesV2 $product
Assert-R13 (@($download.paths).Count -eq 9) 'did not download all 9 sources'
$analysis = Analyze-ProductImagesV2 '42833435408' ([string[]]$download.paths)
$plan = Get-V4BCurrentSourcePlan
Assert-R13 ($null -ne $plan) 'source plan missing'
$validation = Test-V4BSourcePlan $plan $true
Assert-R13 ([bool]$validation.passed) ('source plan validation failed: ' + (@($validation.errors)-join'; '))
$slotPlan = Get-V4BPlanSlot $plan 'detail1'
Assert-R13 ($null -ne $slotPlan) 'detail1 slot plan missing'
Assert-R13 ([string]$slotPlan.source_mode -eq 'single_original') 'detail1 must use one real original'
Assert-R13 (@($slotPlan.source_indices).Count -eq 1) 'detail1 must use exactly one source index'
Assert-R13 ([int]$slotPlan.source_indices[0] -eq 4) ('unexpected detail1 source index: ' + [string]$slotPlan.source_indices[0])
Assert-R13 (-not [bool]$slotPlan.text_shield_required) 'R13 intentionally tests direct preservation of the real apparel print, not text erasure'

$prompt = Get-PromptV2 'detail1' $product
$prompt += "`n[428 九張原圖人工驗收硬限制]`n本次 detail1 唯一來源是黑色雙層短褲、粉色火焰與既有裝飾字樣的真實商品圖。保留原本外層短褲、較長內層、腰頭、抽繩、下擺條紋、火焰與該款式既有表面印花位置/造型。九張來源沒有清楚可驗證的口袋開口，因此不得新增任何可見口袋、拉鍊袋或側袋。不得新增尺寸、材質、品牌、Logo、功能、配件、贈品或性能宣稱。商品表面既有裝飾字樣不可改寫成新的品牌式英文、地名或不同文字；若無法精確保留，就保持原圖像素感與不可辨識視覺，不要發明新字。不要把其他 variant 的顏色或印花套到本款。"
Assert-R13 ($prompt -match 'EDIT / PRESERVE / LOCALIZE') 'preservation mode missing'
Assert-R13 ($prompt -match '不得新增任何可見口袋') 'pocket fail-closed rule missing'
Assert-R13 ($prompt -notmatch 'BRRO') 'variant-only token seeded into positive prompt'
$analysis | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $outDir '42833435408_analysis_r13.json') -Encoding UTF8
$plan | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $outDir '42833435408_source_plan_r13.json') -Encoding UTF8
$slotPlan | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $outDir '42833435408_detail1_slot_plan.json') -Encoding UTF8
$prompt | Set-Content -LiteralPath (Join-Path $outDir '42833435408_detail1_prompt.txt') -Encoding UTF8
Copy-Item -LiteralPath ([string]$slotPlan.source_paths[0]) -Destination (Join-Path $outDir '42833435408_detail1_selected_original.png') -Force

$runtimeRefs = [string[]]@(Get-ReferencesForSlotV2 $analysis 'detail1' 2)
Assert-R13 ($runtimeRefs.Count -eq 1) 'detail1 must use one runtime reference'
Copy-Item -LiteralPath $runtimeRefs[0] -Destination (Join-Path $outDir '42833435408_detail1_runtime_ref.jpg') -Force
$apiRefs = [string[]]@(Get-PreparedApiReferencesV2 '42833435408' $runtimeRefs)
Write-Host '[LIVE V4-B 428 R13] 42833435408 / detail1 / direct apparel-print preservation' -ForegroundColor Cyan
$temporary = Invoke-ImageEditMultiV2 $config $apiRefs $prompt '1024x1024' 'medium'
$output = Join-Path $outDir '42833435408_detail1_live.jpg'
Convert-ToFinalJpegV2 $temporary $output | Out-Null
Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
Assert-R13 ((Test-Path -LiteralPath $output -PathType Leaf) -and (Get-Item -LiteralPath $output).Length -gt 10000) '428 detail1 output missing'
$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
    schema_version=2;version='V4-B 428 R13';round='R13';head_sha=[string]$env:GITHUB_SHA;run_id=[string]$env:GITHUB_RUN_ID;
    run_attempt=[string]$env:GITHUB_RUN_ATTEMPT;workflow_name=[string]$env:GITHUB_WORKFLOW;repository=[string]$env:GITHUB_REPOSITORY;
    artifact_name=$artifactName;artifact_id=$null;artifact_id_status='assigned after payload upload; see receipt artifact';
    output_directory=$outDirName;test_scope=[string[]]@('42833435408/detail1');generated_image_count=1;source_index=[int]$slotPlan.source_indices[0];
    source_review_run_id='31917384949';source_review_artifact_id='9255311958';source_review_count=9;
    source_mode=[string]$slotPlan.source_mode;text_shield_required=[bool]$slotPlan.text_shield_required;
    expected_visual_identity='black double-layer shorts with pink flame/decorative print and no newly visible pocket';
    forbidden_new_content=[string[]]@('visible pocket','zip pocket','size','material','brand/logo','new function','accessory/gift','performance claim','variant-generalized color/print');
    output_file=(Split-Path $output -Leaf);bytes=(Get-Item -LiteralPath $output).Length;sha256=$hash;visual_review_required=$true
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir 'v4b_428_r13_summary.json') -Encoding UTF8
Write-Host '[PASS] V4-B 428 R13 technical gate: one real detail1 source and one generated image. Human original/output visual review required.' -ForegroundColor Green
