$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

function Assert-V4BConflict([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('V4-B conflict cleanup smoke failed: ' + $Message) }
}

$rows = @(
    @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';5='et_title_variation_1';6='et_title_option_1_for_variation_1';7='et_title_option_2_for_variation_1'},
    @{0='90000030001';1='';2='測試訓練用品';3='Sports/Training';4='https://example.invalid/a.jpg';5='規格';6='黑色2米30磅+腰帶一組';7='黑色2米30磅+腰帶各5組'}
)
$product = @(Convert-ShopeeRowsToProducts $rows)[0]
Assert-V4BConflict ($null -ne $product) 'synthetic product parse failed'
Assert-V4BConflict ([bool]$product.multi_variant_flags.has_multiple_quantities) 'quantity conflict flag missing'
$guard = Get-V4BVariantConflictPrompt $product
Assert-V4BConflict ($guard -match '具體件數、片數、入數、組數、套數、條數') 'generic quantity-conflict suppression rule missing'
Assert-V4BConflict ($guard -match '共同已驗證的長度、重量、阻力') 'non-count shared specs should remain allowed'
$sellerGuard = Get-V4BSourceSellerPolicyPrompt
foreach ($term in @('價格','包郵','包退','售後承諾','低敏','親膚','整個文字標籤')) {
    Assert-V4BConflict ($sellerGuard -match [regex]::Escape($term)) ('seller-policy cleanup missing: ' + $term)
}
Assert-V4BConflict ($sellerGuard -match '禁止把它改寫成') 'seller promise must be removed without replacement claim'
$iconGuard = Get-V4BIconTextPrompt
foreach ($term in @('KG','LB','CM','MM','IN','30磅')) {
    Assert-V4BConflict ($iconGuard -match [regex]::Escape($term)) ('unit-icon guard missing: ' + $term)
}

$selDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selDir -Force | Out-Null
$product | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$prompt = Get-PromptV2 'detail4' $product
Assert-V4BConflict ($prompt -match '來源賣家促銷／承諾清理') 'seller-policy cleanup section missing from prompt'
Assert-V4BConflict ($prompt -match '圖示與單位文字硬限制') 'unit-icon cleanup section missing from prompt'
Assert-V4BConflict ($prompt -match '數量／套組數有差異') 'quantity-conflict section missing from prompt'
Assert-V4BConflict ($prompt -notmatch '各5組') 'variant-specific quantity must not be seeded into prompt'
Assert-V4BConflict ($prompt -match '2公尺' -and $prompt -match '30磅' -and $prompt -match '腰帶' -and $prompt -match '黑色') 'common verified facts were lost while suppressing quantity conflict'

Write-Host 'V4-B quantity conflict, seller-promise deletion, and unit-icon smoke: PASS' -ForegroundColor Green
