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
if (@($product.verified_facts.verified_dimensions) -notcontains '2米') { throw 'Source fact must stay unchanged as 2米.' }

$mainPrompt = Get-PromptV2 'main' $product
$compactPrompt = Get-CompactTransportPromptV2 'main' $product

$legacyMainVisualGuard = ($mainPrompt -match '視覺數量限制') -and
    ($mainPrompt -match '禁止用多個重複商品單位') -and
    ($mainPrompt -match '以單一代表性商品外觀為主')
$legacyCompactVisualGuard = ($compactPrompt -match '禁止用多個重複商品單位') -and
    ($compactPrompt -match '以單一代表性商品外觀為主')

$v4bMainVisualGuard = ($mainPrompt -match '本商品有多規格') -and
    ($mainPrompt -match '不得把單一規格內容改寫成所有規格共同具備') -and
    ($mainPrompt -match '數量／套組數有差異') -and
    ($mainPrompt -match '不要翻譯、重建或改寫成通用賣點')
$v4bCompactVisualGuard = ($compactPrompt -match '本商品有多規格') -and
    ($compactPrompt -match '不得把單一規格內容改寫成所有規格共同具備') -and
    ($compactPrompt -match '數量／套組數有差異') -and
    ($compactPrompt -match '不要翻譯、重建或改寫成通用賣點')

if (-not ($legacyMainVisualGuard -or $v4bMainVisualGuard)) { throw 'Main prompt multi-variant visual/source guard missing.' }
if (-not ($legacyCompactVisualGuard -or $v4bCompactVisualGuard)) { throw 'Compact prompt multi-variant visual/source guard missing.' }

foreach ($value in @('2公尺','30磅','腰帶','黑色')) {
    if ($mainPrompt -notmatch [regex]::Escape($value)) { throw ('Localized/common verified fact missing: ' + $value) }
}
if ($mainPrompt -match '(?<!公)2米') { throw 'Main prompt leaked Mainland length wording 2米.' }
if ($mainPrompt -match '一組' -or $mainPrompt -match '5組' -or $mainPrompt -match '五套') { throw 'Variant-specific quantity leaked into prompt.' }

Write-Host '[PASS] Visual quantity/source truth guard: source facts remain unchanged, common facts are localized, and multi-variant quantities cannot be generalized or rebuilt as common claims.' -ForegroundColor Green
