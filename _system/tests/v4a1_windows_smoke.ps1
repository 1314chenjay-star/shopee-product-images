$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'

. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

$header = @{
    0='et_title_product_id'; 1='et_title_parent_sku'; 2='et_title_product_name'; 3='et_title_product_category'
    4='ps_item_cover_image'; 5='ps_item_image.1'; 6='ps_item_image.2'; 7='ps_new_size_chart'; 8='et_title_size_chart'
    9='et_title_variation_1'; 10='et_title_option_1_for_variation_1'; 11='et_title_option_image_1_for_variation_1'
    12='et_title_option_2_for_variation_1'; 13='et_title_option_image_2_for_variation_1'
}
$rows = @(
    $header,
    @{0='58015741169';1='P580';2='籃球訓練阻力繩';3='101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Training';4='https://example.com/cover580.jpg';5='https://example.com/580-1.jpg';6='https://example.com/580-2.jpg';7='SIZE-A';8='SIZE-B';9='規格';10='黑色2米30磅+腰帶一組';11='https://example.com/opt1.jpg';12='黑色2米30磅+腰帶各5組';13='https://example.com/opt2.jpg'},
    @{0='57565745174';1='P575';2='排球訓練器';3='Sports & Outdoors/Volleyball/Training';4='https://example.com/cover575.jpg';9='型號';10='美璐捷排球訓練器材(VZJ-004S)'},
    @{0='51111111111';1='P511';2='長度測試';3='Sports & Outdoors/Training';4='https://example.com/cover511.jpg';9='規格';10='2米30磅'},
    @{0='52222222222';1='P522';2='多款商品';3='Sports & Outdoors';4='https://example.com/cover522.jpg';9='款式';10='款式A';12='款式B'},
    @{0='53333333333';1='P533';2='材質測試';3='Sports & Outdoors';4='https://example.com/cover533.jpg';9='款式';10='不鏽鋼款'},
    @{0='54444444444';1='P544';2='多色商品';3='Sports & Outdoors';4='https://example.com/cover544.jpg';9='顏色';10='馬卡龍限定-淺粉';12='馬卡龍限定-淺粉藍'}
)

$products = @(Convert-ShopeeRowsToProducts $rows)
if ($products.Count -ne 6) { throw ('Expected 6 products, got ' + $products.Count) }

$p580 = @($products | Where-Object { $_.product_id -eq '58015741169' })[0]
if (@($p580.image_urls).Count -ne 3) { throw '580 image count/order failed.' }
if ([string]$p580.image_urls[0] -ne 'https://example.com/cover580.jpg' -or [string]$p580.image_urls[1] -ne 'https://example.com/580-1.jpg' -or [string]$p580.image_urls[2] -ne 'https://example.com/580-2.jpg') { throw 'image_urls must stay cover -> image.1 -> image.2.' }
foreach ($value in @('2米','30磅')) { if (@($p580.verified_facts.verified_numbers) -notcontains $value) { throw ('580 common number missing: ' + $value) } }
if (@($p580.verified_facts.verified_dimensions) -notcontains '2米') { throw '580 dimension missing.' }
if (@($p580.verified_facts.verified_accessories) -notcontains '腰帶') { throw '580 accessory missing.' }
if (@($p580.verified_facts.verified_colors) -notcontains '黑色') { throw '580 color missing.' }
if (@($p580.verified_facts.verified_quantities) -contains '一組' -or @($p580.verified_facts.verified_quantities) -contains '5組') { throw 'Variant-specific quantities leaked into common facts.' }
if (-not [bool]$p580.multi_variant_flags.has_multiple_variants -or -not [bool]$p580.multi_variant_flags.has_multiple_bundle_counts) { throw '580 multi-variant flags failed.' }
if (@($p580.factual_categories) -notcontains 'balls_rackets' -or @($p580.factual_categories) -notcontains 'training_equipment') { throw 'English/multi-category routing failed for 580.' }

$p575 = @($products | Where-Object { $_.product_id -eq '57565745174' })[0]
if (@($p575.verified_facts.verified_models) -notcontains 'VZJ-004S') { throw '575 model extraction failed.' }
if (@($p575.verified_facts.verified_accessories) -contains '球' -or @($p575.verified_facts.verified_bundle_contents) -contains '球') { throw '575 排球 must not become included ball.' }

$p511 = @($products | Where-Object { $_.product_id -eq '51111111111' })[0]
if (@($p511.verified_facts.verified_colors) -contains '米' -or @($p511.verified_facts.verified_colors) -contains '米色') { throw '2米 must not become a color.' }

$p522 = @($products | Where-Object { $_.product_id -eq '52222222222' })[0]
if (-not [bool]$p522.multi_variant_flags.has_multiple_variants -or -not (Test-IsMultiVariantV4A1 $p522.multi_variant_flags)) { throw 'Unparsed 款式A/款式B must still be multi-variant.' }

$p533 = @($products | Where-Object { $_.product_id -eq '53333333333' })[0]
if (@($p533.verified_facts.verified_materials) -notcontains '不鏽鋼' -or @($p533.verified_facts.verified_materials) -contains '鋼') { throw 'Material longest-match suppression failed.' }

$p544 = @($products | Where-Object { $_.product_id -eq '54444444444' })[0]
if (-not [bool]$p544.multi_variant_flags.has_multiple_colors -or @($p544.verified_facts.verified_colors).Count -ne 0) { throw 'Multi-color common isolation failed.' }

$prompt580 = Get-PromptV2 'main' $p580
foreach ($value in @('2米','30磅','腰帶','黑色')) { if ($prompt580 -notmatch [regex]::Escape($value)) { throw ('Prompt missing common verified fact: ' + $value) } }
if ($prompt580 -notmatch '所有文字型具體事實只能取自上方已驗證事實') { throw 'Prompt allowlist hard rule missing.' }
$compact580 = Get-CompactTransportPromptV2 'detail4' $p580
if ($compact580 -notmatch '未列入已驗證事實就禁止生成') { throw 'Compact prompt allowlist rule missing.' }

$risk = Test-FactualContentV4A1 '32cm 尼龍 不傷膝 提升爆發力 SGS' $p580
if (-not $risk.factual_risk -or [bool]$risk.image_text_ocr_verified) { throw 'Known-text factual guard failed or falsely claimed OCR.' }

$apiBlob = (& git rev-parse 'HEAD:_system/start/api_v2.ps1').Trim()
if ($LASTEXITCODE -ne 0 -or $apiBlob -ne '9e81a9c4a0769d5e41b4c1e7dba4b92266c49187') { throw ('API-R3-120S git blob changed: ' + $apiBlob) }

$guardText = Get-Content -LiteralPath (Join-Path $startRoot 'v4a1_guard.ps1') -Raw -Encoding UTF8
$rulesText = Get-Content -LiteralPath (Join-Path $systemRoot 'config\factual_rules_v4a1.json') -Raw -Encoding UTF8
if ($guardText.Contains([char]0xFFFD) -or $rulesText.Contains([char]0xFFFD)) { throw 'U+FFFD replacement character found.' }

Write-Host '[PASS] V4-A.1 direct factual guard: real Shopee headers, ordered images, variant facts, parser edge cases, prompt allowlist, and R3 identity all passed.' -ForegroundColor Green
