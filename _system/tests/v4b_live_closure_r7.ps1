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
$round = 'R7'
$slug = 'r7'
$artifactName = if ([string]::IsNullOrWhiteSpace([string]$env:V4B_ARTIFACT_NAME)) { 'TinySnow-V4-B-Closure-R7' } else { ([string]$env:V4B_ARTIFACT_NAME).Trim() }
$outDirName = 'live_e2e_output_v4b_closure_r7'
$outDir = Join-Path $systemRoot $outDirName
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$config = [pscustomobject]@{api_key=$key;base_url='https://tinysnow.one/v1';model='gpt-image-2';quality='medium';size='1024x1024';safe_test_mode=$true;max_reference_images=2;transport_profile='r3_120s_safe'}

function Assert-ClosureR7([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw ('V4-B closure R7 failed: ' + $Message) }
}

function Save-ClosureSelection($Product) {
    $dir = Get-SelectionWorkspaceV2
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $Product | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $dir 'selected_product.json') -Encoding UTF8
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
$header = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image'}
$data = @{0='58015741169';1='';2='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品';3='Sports & Outdoors/Basketball/Training';4=$urls[0];20='規格';21='黑色2米30磅+腰帶一組';22='黑色2米30磅+腰帶各5組'}
for ($i=1; $i -lt $urls.Count; $i++) { $column=4+$i; $header[$column]='ps_item_image.'+$i; $data[$column]=$urls[$i] }
$header[20]='et_title_variation_1';$header[21]='et_title_option_1_for_variation_1';$header[22]='et_title_option_2_for_variation_1'
$product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
Assert-ClosureR7 ($null -ne $product) '580 product construction failed'
Assert-ClosureR7 ([string]$product.product_id -eq '58015741169') '580 product ID changed'
Assert-ClosureR7 ([bool]$product.multi_variant_flags.has_multiple_quantities) '580 quantity conflict flag missing'

Save-ClosureSelection $product
$download = Download-ProductImagesV2 $product
$analysis = Analyze-ProductImagesV2 '58015741169' ([string[]]$download.paths)
$plan = Get-V4BCurrentSourcePlan
Assert-ClosureR7 ($null -ne $plan) 'source plan missing'
$validation = Test-V4BSourcePlan $plan $true
Assert-ClosureR7 ([bool]$validation.passed) ('source plan validation failed: ' + (@($validation.errors) -join '; '))

foreach ($slot in @('main','detail2','detail3','detail4')) {
    $slotPlan = Get-V4BPlanSlot $plan $slot
    Assert-ClosureR7 ([bool]$slotPlan.text_shield_required) ($slot + ' must use conflict text shield')
    Assert-ClosureR7 ([string]$slotPlan.verified_text_policy -eq 'deterministic_overlay_only') ($slot + ' must use deterministic overlay only')
    Assert-ClosureR7 ([int]$slotPlan.reference_proxy_max_edge -eq 384) ($slot + ' text-shield proxy must be 384px')
}
foreach ($slot in @('main','detail2','detail4')) {
    $slotPlan = Get-V4BPlanSlot $plan $slot
    Assert-ClosureR7 ([string]$slotPlan.source_selection_policy -eq 'product_focus_proxy') ($slot + ' must use product-focus source policy')
    Assert-ClosureR7 (@($slotPlan.source_indices).Count -eq 1) ($slot + ' must use one source')
    Assert-ClosureR7 ([int]$slotPlan.source_indices[0] -eq 4) ($slot + ' must use visually reviewed product-focused source index 4')
}

$detail3Content = Get-V4BVerifiedOverlayContent $product 'detail3'
Assert-ClosureR7 ([string]$detail3Content.title -eq '籃球訓練阻力繩') 'detail3 overlay title must use verified Taiwan product label'
Assert-ClosureR7 ([string]$detail3Content.title -notmatch '區域聯防') 'detail3 overlay retained unsupported source phrase'
$detail3Prompt = Get-PromptV2 'detail3' $product
Assert-ClosureR7 ($detail3Prompt -match '不要生成任何可辨識文字') 'detail3 TinySnow stage must be text-free'
Assert-ClosureR7 ($detail3Prompt -notmatch '區域聯防') 'detail3 prompt seeded unsupported source phrase'

$plan | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $outDir '58015741169_source_plan_v4b_r7.json') -Encoding UTF8
$results = @()
foreach ($slot in @('main','detail2')) {
    Save-ClosureSelection $product
    $slotPlan = Get-V4BPlanSlot $plan $slot
    $prompt = Get-PromptV2 $slot $product
    Assert-ClosureR7 ($prompt -match '程式化驗證文字覆蓋') ($slot + ' deterministic overlay directive missing')
    Assert-ClosureR7 ($prompt -match '不要生成任何可辨識文字') ($slot + ' TinySnow stage must be text-free')
    Assert-ClosureR7 ($prompt -notmatch '各5組|區域聯防') ($slot + ' prompt contains unsupported source text')
    foreach ($fact in @('2公尺','30磅','腰帶','黑色')) { Assert-ClosureR7 ($prompt -match [regex]::Escape($fact)) ($slot + ' prompt missing common verified fact: ' + $fact) }

    $runtimeRefs = [string[]]@(Get-ReferencesForSlotV2 $analysis $slot 2)
    Assert-ClosureR7 ($runtimeRefs.Count -eq 1) ($slot + ' must use one runtime reference')
    Assert-ClosureR7 ([IO.Path]::GetFileNameWithoutExtension($runtimeRefs[0]) -match '_safe$') ($slot + ' runtime reference must be the text-shield proxy')

    $prompt | Set-Content -LiteralPath (Join-Path $outDir ('58015741169_'+$slot+'_prompt.txt')) -Encoding UTF8
    $slotPlan | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $outDir ('58015741169_'+$slot+'_slot_plan.json')) -Encoding UTF8
    Copy-Item -LiteralPath ([string]$slotPlan.source_paths[0]) -Destination (Join-Path $outDir ('58015741169_'+$slot+'_selected_original.png')) -Force
    Copy-Item -LiteralPath $runtimeRefs[0] -Destination (Join-Path $outDir ('58015741169_'+$slot+'_runtime_ref.jpg')) -Force

    $apiRefs = [string[]]@(Get-PreparedApiReferencesV2 '58015741169' $runtimeRefs)
    Write-Host ('[LIVE V4-B CLOSURE R7] 58015741169 / '+$slot) -ForegroundColor Cyan
    $temporary = Invoke-ImageEditMultiV2 $config $apiRefs $prompt '1024x1024' 'medium'
    $output = Join-Path $outDir ('58015741169_'+$slot+'_live.jpg')
    Convert-ToFinalJpegV2 $temporary $output | Out-Null
    Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
    $results += [pscustomobject]@{
        product_id='58015741169';slot=$slot;source_index=[int]$slotPlan.source_indices[0];source_selection_policy=[string]$slotPlan.source_selection_policy;
        runtime_reference_strategy=[string]$slotPlan.runtime_reference_strategy;verified_text_policy=[string]$slotPlan.verified_text_policy;
        output_file=(Split-Path $output -Leaf);bytes=(Get-Item -LiteralPath $output).Length;
        sha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

$uniqueHashes = @($results | ForEach-Object { [string]$_.sha256 } | Select-Object -Unique).Count
Assert-ClosureR7 ($uniqueHashes -eq 2) 'main and detail2 outputs must have distinct hashes'
$summaryName = 'v4b_closure_r7_summary.json'
[pscustomobject]@{
    schema_version=2;version='V4-B Closure R7';round=$round;head_sha=[string]$env:GITHUB_SHA;run_id=[string]$env:GITHUB_RUN_ID;
    run_attempt=[string]$env:GITHUB_RUN_ATTEMPT;workflow_name=[string]$env:GITHUB_WORKFLOW;repository=[string]$env:GITHUB_REPOSITORY;
    artifact_name=$artifactName;artifact_id=$null;artifact_id_status='assigned after payload upload; see v4b_closure_r7_artifact_receipt.json and GitHub job summary';
    output_directory=$outDirName;test_scope=[string[]]@('58015741169/main','58015741169/detail2');generated_image_count=2;
    unique_hashes=$uniqueHashes;detail3_text_source_check='unsupported phrase not present in structured safe label, prompts, or deterministic overlay; detail3 live generation intentionally deferred';
    tests=[object[]]$results;visual_review_required=$true;full_five_image_regression_required=$true
} | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $outDir $summaryName) -Encoding UTF8

Write-Host '[PASS] V4-B Closure R7 technical gate: 580 main + detail2 generated with product-focused source, text-free TinySnow stage, and deterministic verified overlay. Visual review required.' -ForegroundColor Green
