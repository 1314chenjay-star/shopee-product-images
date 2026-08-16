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
$artifactName = if ([string]::IsNullOrWhiteSpace([string]$env:V4B_ARTIFACT_NAME)) { 'TinySnow-V4-B-Detail3-R8' } else { ([string]$env:V4B_ARTIFACT_NAME).Trim() }
$outDirName = 'live_e2e_output_v4b_detail3_r8'
$outDir = Join-Path $systemRoot $outDirName
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$config = [pscustomobject]@{api_key=$key;base_url='https://tinysnow.one/v1';model='gpt-image-2';quality='medium';size='1024x1024';safe_test_mode=$true;max_reference_images=2;transport_profile='r3_120s_safe'}

function Assert-Detail3R8([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('V4-B detail3 R8 failed: ' + $Message) }
}

$urls = [string[]]@(
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82590-mrpfuzxcymtj83',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259m-mrpfv0sqdzpk57',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825aw-mrpfv1ftvdonbb',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259p-mrpfv1zcms5g87',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825b2-mrpfv2mgqn7p69',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82593-mrpfv3ovpjwle0',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-825a0-mrpfv4hwe0w66e',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-82586-mrpfv6mpe4n5c7',
    'https://s-cf-tw.shopeesz.com/file/sg-11134201-8259l-mrpfv78r80lhdb'
)
$header = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1';21='et_title_option_1_for_variation_1';22='et_title_option_2_for_variation_1'}
$data = @{0='58015741169';1='';2='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品';3='Sports & Outdoors/Basketball/Training';4=$urls[0];20='規格';21='黑色2米30磅+腰帶一組';22='黑色2米30磅+腰帶各5組'}
for ($i=1; $i -lt $urls.Count; $i++) { $column=4+$i; $header[$column]='ps_item_image.'+$i; $data[$column]=$urls[$i] }
$product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
Assert-Detail3R8 ($null -ne $product) '580 product construction failed'
Assert-Detail3R8 ([bool]$product.multi_variant_flags.has_multiple_quantities) '580 quantity conflict flag missing'

$selectionDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selectionDir -Force | Out-Null
$product | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $selectionDir 'selected_product.json') -Encoding UTF8
$download = Download-ProductImagesV2 $product
$analysis = Analyze-ProductImagesV2 '58015741169' ([string[]]$download.paths)
$plan = Get-V4BCurrentSourcePlan
Assert-Detail3R8 ($null -ne $plan) 'source plan missing'
$validation = Test-V4BSourcePlan $plan $true
Assert-Detail3R8 ([bool]$validation.passed) ('source plan validation failed: ' + (@($validation.errors) -join '; '))

$slot = 'detail3'
$slotPlan = Get-V4BPlanSlot $plan $slot
Assert-Detail3R8 ([bool]$slotPlan.text_shield_required) 'detail3 must use conflict text shield'
Assert-Detail3R8 ([string]$slotPlan.verified_text_policy -eq 'deterministic_overlay_only') 'detail3 must use deterministic overlay only'
Assert-Detail3R8 ([int]$slotPlan.reference_proxy_max_edge -eq 384) 'detail3 text-shield proxy must be 384px'
$content = Get-V4BVerifiedOverlayContent $product $slot
Assert-Detail3R8 ([string]$content.title -eq '籃球訓練阻力繩') 'detail3 overlay title must use the verified Taiwan product label'
Assert-Detail3R8 ([string]$content.title -notmatch '區域聯防') 'detail3 overlay retained unsupported source phrase'

$prompt = Get-PromptV2 $slot $product
Assert-Detail3R8 ($prompt -match '程式化驗證文字覆蓋') 'detail3 deterministic overlay directive missing'
Assert-Detail3R8 ($prompt -match '不要生成任何可辨識文字') 'detail3 TinySnow stage must be text-free'
Assert-Detail3R8 ($prompt -notmatch '各5組|區域聯防|一套裝|五套裝') 'detail3 prompt contains unsupported source text'
foreach ($fact in @('2公尺','30磅','腰帶','黑色')) { Assert-Detail3R8 ($prompt -match [regex]::Escape($fact)) ('detail3 prompt missing common verified fact: ' + $fact) }

$runtimeRefs = [string[]]@(Get-ReferencesForSlotV2 $analysis $slot 2)
Assert-Detail3R8 ($runtimeRefs.Count -eq 1) 'detail3 must use one runtime reference'
Assert-Detail3R8 ([IO.Path]::GetFileNameWithoutExtension($runtimeRefs[0]) -match '_safe$') 'detail3 runtime reference must be the text-shield proxy'

$plan | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $outDir '58015741169_source_plan_v4b_r8.json') -Encoding UTF8
$prompt | Set-Content -LiteralPath (Join-Path $outDir '58015741169_detail3_prompt.txt') -Encoding UTF8
$slotPlan | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $outDir '58015741169_detail3_slot_plan.json') -Encoding UTF8
Copy-Item -LiteralPath ([string]$slotPlan.source_paths[0]) -Destination (Join-Path $outDir '58015741169_detail3_selected_original.png') -Force
Copy-Item -LiteralPath $runtimeRefs[0] -Destination (Join-Path $outDir '58015741169_detail3_runtime_ref.jpg') -Force

$apiRefs = [string[]]@(Get-PreparedApiReferencesV2 '58015741169' $runtimeRefs)
Write-Host '[LIVE V4-B DETAIL3 R8] 58015741169 / detail3' -ForegroundColor Cyan
$temporary = Invoke-ImageEditMultiV2 $config $apiRefs $prompt '1024x1024' 'medium'
$output = Join-Path $outDir '58015741169_detail3_live.jpg'
Convert-ToFinalJpegV2 $temporary $output | Out-Null
Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
Assert-Detail3R8 ((Test-Path -LiteralPath $output -PathType Leaf) -and (Get-Item -LiteralPath $output).Length -gt 10000) 'detail3 output missing or invalid'
$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()

[pscustomobject]@{
    schema_version=2;version='V4-B Detail3 R8';round='R8';head_sha=[string]$env:GITHUB_SHA;run_id=[string]$env:GITHUB_RUN_ID;
    run_attempt=[string]$env:GITHUB_RUN_ATTEMPT;workflow_name=[string]$env:GITHUB_WORKFLOW;repository=[string]$env:GITHUB_REPOSITORY;
    artifact_name=$artifactName;artifact_id=$null;artifact_id_status='assigned after payload upload; see v4b_detail3_r8_artifact_receipt.json and GitHub job summary';
    output_directory=$outDirName;test_scope=[string[]]@('58015741169/detail3');generated_image_count=1;
    source_index=[int]$slotPlan.source_indices[0];runtime_reference_strategy=[string]$slotPlan.runtime_reference_strategy;
    verified_text_policy=[string]$slotPlan.verified_text_policy;safe_overlay_title=[string]$content.title;unsupported_phrase_absent=$true;
    output_file=(Split-Path $output -Leaf);bytes=(Get-Item -LiteralPath $output).Length;sha256=$hash;visual_review_required=$true;full_five_image_regression_required=$true
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $outDir 'v4b_detail3_r8_summary.json') -Encoding UTF8

Write-Host '[PASS] V4-B Detail3 R8 technical gate: text-free TinySnow stage plus verified Taiwan overlay. Visual review required.' -ForegroundColor Green
