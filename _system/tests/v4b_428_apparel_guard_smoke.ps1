$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$systemRoot = Split-Path $PSScriptRoot -Parent
$startRoot = Join-Path $systemRoot 'start'
. (Join-Path $startRoot 'api_v2.ps1')
. (Join-Path $startRoot 'excel_reader.ps1')
. (Join-Path $startRoot 'selection_v2.ps1')
. (Join-Path $startRoot 'image_pipeline_v2.ps1')
. (Join-Path $startRoot 'v4a1_guard.ps1')

function Assert-428Guard([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('V4-B 428 apparel guard smoke failed: ' + $Message) }
}

$options = [string[]]@(
    '粉標黑色',
    '粉標白色',
    '白標黑色',
    '黑標白色',
    '黑內光板',
    '白內光板',
    '粉標火焰黑',
    '白標火焰黑',
    '粉標火焰白',
    '黑標火焰白',
    'BRRO【粉标】黑色【速干透气】'
)

$header = @{0='et_title_product_id';1='et_title_parent_sku';2='et_title_product_name';3='et_title_product_category';4='ps_item_cover_image';20='et_title_variation_1'}
$data = @{0='42833435408';1='';2='籃球短褲 男款寬鬆五分褲 假兩件設計 速乾透氣運動短褲 夏季籃球訓練休閒褲';3='101853 - Sports & Outdoors/Sports & Outdoor Recreation Equipments/Basketball/Others';4='https://example.invalid/428-main.jpg';20='款式'}
for ($i=1; $i -le $options.Count; $i++) {
    $column = 20 + $i
    $header[$column] = "et_title_option_${i}_for_variation_1"
    $data[$column] = $options[$i - 1]
}

$product = @(Convert-ShopeeRowsToProducts @($header,$data))[0]
Assert-428Guard ($null -ne $product) '428 fixture parse failed'
Assert-428Guard ([string]$product.product_id -eq '42833435408') '11-digit product ID changed'
Assert-428Guard (@($product.variants).Count -eq 11) 'variant count mismatch'
Assert-428Guard (@($product.factual_categories) -contains 'apparel') 'shorts must be classified as apparel'
Assert-428Guard ([bool]$product.multi_variant_flags.has_multiple_variants) 'multi-variant flag missing'
Assert-428Guard ([bool]$product.multi_variant_flags.has_multiple_colors) 'color conflict flag missing'
Assert-428Guard (-not [bool]$product.multi_variant_flags.has_multiple_quantities) '428 must not invent quantity conflict'

$facts = $product.verified_facts
foreach ($property in @('verified_dimensions','verified_materials','verified_accessories','verified_gifts','verified_bundle_contents','verified_colors','verified_sizes','verified_models','verified_quantities','verified_resistance_levels','verified_features','verified_use_cases','verified_certifications')) {
    $values = @(Get-V4A1Property $facts $property @())
    Assert-428Guard ($values.Count -eq 0) ('variant-only fact leaked into common facts: ' + $property + ' = ' + ($values -join '|'))
}

$label = Get-V4BSafeProductLabel $product
Assert-428Guard ([string]$label -eq '籃球短褲') ('safe product label must be 籃球短褲, got: ' + [string]$label)
$overlay = Get-V4BVerifiedOverlayContent $product 'detail1'
Assert-428Guard ([string]$overlay.title -eq '籃球短褲') 'deterministic overlay title regressed to generic 籃球'
$overlayText = ([string]$overlay.title + ' ' + [string]$overlay.secondary)
foreach ($forbidden in @('BRRO','速乾透氣','速干透气','口袋','尼龍','公分')) {
    Assert-428Guard ($overlayText -notmatch [regex]::Escape($forbidden)) ('unverified text leaked into overlay: ' + $forbidden)
}

# The actual 428 source set has multiple variants but no structured common claim facts.
# A moderately text-heavy detail1 source must therefore use the R12 sparse-fact surface-text shield,
# so the TinySnow stage cannot invent/rebuild brand-like surface text and Windows adds only verified copy.
$candidates = @(
    [pscustomobject]@{path='C:\refs\428_main.png';position=0;duplicate=$false;local_risk_score=0.31;local_safe_score=0.69;center_edge_density=0.14;outer_edge_density=0.10},
    [pscustomobject]@{path='C:\refs\428_detail1.png';position=1;duplicate=$false;local_risk_score=0.30;local_safe_score=0.70;center_edge_density=0.15;outer_edge_density=0.10},
    [pscustomobject]@{path='C:\refs\428_detail2.png';position=2;duplicate=$false;local_risk_score=0.18;local_safe_score=0.82;center_edge_density=0.17;outer_edge_density=0.08},
    [pscustomobject]@{path='C:\refs\428_detail3.png';position=3;duplicate=$false;local_risk_score=0.20;local_safe_score=0.80;center_edge_density=0.16;outer_edge_density=0.09},
    [pscustomobject]@{path='C:\refs\428_detail4.png';position=4;duplicate=$false;local_risk_score=0.22;local_safe_score=0.78;center_edge_density=0.18;outer_edge_density=0.08}
)
$analysis = [pscustomobject]@{product_id='42833435408';high_variant_conflict=$true;reference_safety=[object[]]$candidates;images=[object[]]$candidates}
$plan = New-V4BSourceImagePlan $product $analysis
Assert-428Guard ([bool](Test-V4BSourcePlan $plan $false).passed) '428 source plan validation failed'
$detail1 = Get-V4BPlanSlot $plan 'detail1'
Assert-428Guard ([bool]$detail1.text_shield_required) 'text-heavy sparse-fact detail1 must use source-text shield'
Assert-428Guard ([string]$detail1.text_shield_reason -eq 'sparse_verified_facts_source_text_risk') 'detail1 shield reason mismatch'
Assert-428Guard ([string]$detail1.runtime_reference_strategy -eq 'sparse_surface_text_shield_proxy') 'detail1 must use R12 surface-text shield proxy'
Assert-428Guard ([string]$detail1.surface_text_policy -eq 'neutral_texture_only') 'detail1 must neutralize unverified reconstructed surface text'

$selDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selDir -Force | Out-Null
$product | ConvertTo-Json -Depth 16 | Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$script:V4BSourcePlanCache[[string]$product.product_id] = $plan
$prompt = Get-PromptV2 'detail1' $product
Assert-428Guard ($prompt -match 'EDIT / PRESERVE / LOCALIZE') 'V4-B preservation mode missing'
Assert-428Guard ($prompt -match 'sparse_verified_facts_source_text_risk') 'sparse-fact shield not recorded in prompt'
Assert-428Guard ($prompt -match '不要生成任何可辨識文字') 'shielded TinySnow stage must be text-free'
Assert-428Guard ($prompt -match '新的英文詞、地名、品牌或仿 Logo') 'surface-brand hallucination guard missing'
Assert-428Guard ($prompt -notmatch 'BRRO') 'variant-only BRRO token must never be seeded into prompt'
Assert-428Guard ($prompt -notmatch '速乾透氣') 'title/variant-only speed-dry claim must not be seeded as positive prompt fact'

Write-Host 'V4-B 428 apparel factual/label/sparse-surface guard smoke: PASS' -ForegroundColor Green
