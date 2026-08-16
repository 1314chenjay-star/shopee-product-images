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
$outDir = Join-Path $systemRoot 'live_e2e_output_v4a3_580_d2'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
New-Item -ItemType Directory -Path $outDir -Force | Out-Null

$config = [pscustomobject]@{ api_key=$key; base_url='https://tinysnow.one/v1'; model='gpt-image-2'; quality='medium'; size='1024x1024'; safe_test_mode=$true; max_reference_images=2; transport_profile='r3_120s_safe' }

$urls = @(
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
$data = @{0='58015741169';1='';2='籃球訓練阻力繩 籃球防守訓練輔助器材 彈力帶敏捷訓練器 運動訓練帶 成人學生籃球用品';3='Sports & Outdoors/Basketball/Training';4=$urls[0]}
for ($i=1; $i -lt $urls.Count; $i++) { $header[4+$i]="ps_item_image.$i"; $data[4+$i]=$urls[$i] }
$header[20]='et_title_variation_1'; $data[20]='規格'
$header[21]='et_title_option_1_for_variation_1'; $data[21]='黑色2米30磅+腰帶一組'
$header[22]='et_title_option_2_for_variation_1'; $data[22]='黑色2米30磅+腰帶各5組'
$product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
if ($null -eq $product) { throw '580 fixture construction failed.' }

$selectionDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selectionDir -Force | Out-Null
$product | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $selectionDir 'selected_product.json') -Encoding UTF8

$download = Download-ProductImagesV2 $product
$analysis = Analyze-ProductImagesV2 '58015741169' ([string[]]$download.paths)
$plan = Get-V4A3CurrentPlan
if ($null -eq $plan) { throw '580 five-image plan missing.' }
$slot = 'detail2'
$slotPlan = Get-V4A3PlanSlot $plan $slot
if ($null -eq $slotPlan -or [string]$slotPlan.preferred_layout_family -ne 'macro_breakdown') { throw '580 detail2 plan role/layout mismatch.' }
$refs = [string[]]@(Get-ReferencesForSlotV2 $analysis $slot 2)
if ($refs.Count -lt 1 -or $refs.Count -gt 2) { throw '580 detail2 invalid reference count.' }
if ([bool]$plan.high_variant_conflict -and $refs.Count -ne 1) { throw '580 high-conflict detail2 must use one safest reference.' }
$prepared = [string[]]@(Get-PreparedApiReferencesV2 '58015741169' $refs)
$prompt = Get-PromptV2 $slot ([string]$product.product_name)
if ($null -ne (Get-Command Get-LayoutRetryPromptV2 -ErrorAction SilentlyContinue)) { $prompt += Get-LayoutRetryPromptV2 $slot 0 }
# detail2 intentionally does not require the product label to be rendered. Its stable text role is
# the detail-section title plus verified common facts; this avoids repeating the hero/main copy.
foreach ($required in @('2公尺','30磅','腰帶','黑色','商品結構與細節展示')) { if ($prompt -notmatch [regex]::Escape($required)) { throw ('580 prompt missing: ' + $required) } }
if ($prompt -match '(?<!公)2米|5組|五人聯動|32cm|60cm|9cm|尼龍|橡膠|金屬|彈力繩|連接扣') { throw '580 unsafe/invented fact or local label leaked.' }
if ($prompt -notmatch '局部放大圖與圈選細節全部禁止加文字標籤') { throw '580 detail2 text-free local callout rule missing.' }
if ($prompt -notmatch 'V4-A\.3 五圖整體規劃') { throw '580 V4-A.3 planner directive missing.' }

$plan | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $outDir '580_five_image_plan_v4a3.json') -Encoding UTF8
$prompt | Set-Content -LiteralPath (Join-Path $outDir '58015741169_detail2_prompt.txt') -Encoding UTF8
for ($i=0; $i -lt $refs.Count; $i++) { Copy-Item -LiteralPath $refs[$i] -Destination (Join-Path $outDir ('58015741169_detail2_selected_ref' + ($i+1) + '.jpg')) -Force }

Write-Host '[LIVE] 58015741169 / detail2 -> TinySnow' -ForegroundColor Cyan
$temp = Invoke-ImageEditMultiV2 $config $prepared $prompt '1024x1024' 'medium'
if (-not (Test-Path -LiteralPath $temp -PathType Leaf) -or (Get-Item -LiteralPath $temp).Length -lt 10000) { throw '580 detail2 TinySnow output invalid.' }
$output = Join-Path $outDir '58015741169_detail2_live.jpg'
Convert-ToFinalJpegV2 $temp $output | Out-Null
Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue

[pscustomobject]@{
    version='V4-A.3'; product_id='58015741169'; slot='detail2'; generated_image_count=1;
    layout_family=[string]$slotPlan.preferred_layout_family; selected_reference_count=$refs.Count;
    output_file=(Split-Path $output -Leaf); output_bytes=(Get-Item -LiteralPath $output).Length;
    sha256=(Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant(); visual_review_required=$true
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'v4a3_580_detail2_live_summary.json') -Encoding UTF8
Write-Host '[PASS] V4-A.3 580 detail2 one-image technical non-regression live test completed; visual review required.' -ForegroundColor Green
