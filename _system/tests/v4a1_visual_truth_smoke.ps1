$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')
. (Join-Path $startRoot 'v4a1_visual_truth.ps1')

$rows = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='ps_item_image.1';6='et_title_variation_1';7='et_title_option_1_for_variation_1';8='et_title_option_2_for_variation_1'},
    @{0='58015741169';1='';2='籃球訓練阻力繩';3='Sports & Outdoors/Basketball/Training';4='https://example.com/cover.jpg';5='https://example.com/detail.jpg';6='規格';7='黑色2米30磅+腰帶一組';8='黑色2米30磅+腰帶各5組'}
)
$product = @(Convert-ShopeeRowsToProducts $rows)[0]
if ($null -eq $product) { throw 'Visual truth smoke product construction failed.' }
if (-not [bool]$product.multi_variant_flags.has_multiple_quantities) { throw '580 must have multiple quantity variants.' }
if (-not [bool]$product.multi_variant_flags.has_multiple_bundle_counts) { throw '580 must have multiple bundle counts.' }

$mainPrompt = Get-PromptV2 'main' $product
$compactPrompt = Get-CompactTransportPromptV2 'main' $product
foreach ($needle in @('視覺數量限制','禁止用多個重複商品單位','以單一代表性商品外觀為主')) {
    if ($mainPrompt -notmatch [regex]::Escape($needle)) { throw ('Main prompt visual guard missing: ' + $needle) }
}
foreach ($needle in @('禁止用多個重複商品單位','以單一代表性商品外觀為主')) {
    if ($compactPrompt -notmatch [regex]::Escape($needle)) { throw ('Compact prompt visual guard missing: ' + $needle) }
}

foreach ($value in @('2米','30磅','腰帶','黑色')) {
    if ($mainPrompt -notmatch [regex]::Escape($value)) { throw ('Verified common fact missing: ' + $value) }
}
if ($mainPrompt -match '一組' -or $mainPrompt -match '5組' -or $mainPrompt -match '五套') { throw 'Variant-specific quantity leaked into prompt.' }

Write-Host '[PASS] V4-A.1 visual quantity truth guard: multi-variant bundle visuals are neutralized in full and compact prompts.' -ForegroundColor Green
