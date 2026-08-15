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

# Basic high-conflict shield behavior.
$analysis = [pscustomobject]@{
    product_id='90000030001'
    high_variant_conflict=$true
    reference_safety=[object[]]@([pscustomobject]@{path='C:\refs\conflicted.png';position=0;duplicate=$false;local_risk_score=0.2;local_safe_score=0.8;center_edge_density=0.10;outer_edge_density=0.09})
    images=[object[]]@([pscustomobject]@{path='C:\refs\conflicted.png';position=0;duplicate=$false;local_risk_score=0.2;local_safe_score=0.8;center_edge_density=0.10;outer_edge_density=0.09})
}
$plan = New-V4BSourceImagePlan $product $analysis
Assert-V4BConflict ([bool](Get-V4BPlanSlot $plan 'main').text_shield_required) 'quantity-conflict main must request text shield'
Assert-V4BConflict ([bool](Get-V4BPlanSlot $plan 'detail2').text_shield_required) 'quantity-conflict detail2 must request text shield'
Assert-V4BConflict ([bool](Get-V4BPlanSlot $plan 'detail3').text_shield_required) 'quantity-conflict detail3 must request text shield'
Assert-V4BConflict ([bool](Get-V4BPlanSlot $plan 'detail4').text_shield_required) 'quantity-conflict detail4 must request text shield'
Assert-V4BConflict (-not [bool](Get-V4BPlanSlot $plan 'detail1').text_shield_required) 'detail1 should retain source-text localization ability'
Assert-V4BConflict ([string](Get-V4BPlanSlot $plan 'detail4').runtime_reference_strategy -eq 'conflict_text_shield_proxy') 'detail4 runtime strategy must be conflict_text_shield_proxy'
foreach ($slot in @('main','detail2','detail3','detail4')) {
    $shieldedSlotPlan = Get-V4BPlanSlot $plan $slot
    Assert-V4BConflict ([string]$shieldedSlotPlan.verified_text_policy -eq 'deterministic_overlay_only') ($slot + ' must use deterministic verified text only')
    Assert-V4BConflict ([int]$shieldedSlotPlan.reference_proxy_max_edge -eq 384) ($slot + ' must use the strongest text-shield proxy tier')
}
Assert-V4BConflict ((Get-V4BSourceModePrompt (Get-V4BPlanSlot $plan 'detail4')) -match '不要猜測、還原、補全') 'shielded slot prompt must prohibit reconstruction of blurred source text'

# Slot-aware visual source selection must prefer center-dominant product structure over a safer-looking busy scene.
# These are deterministic proxy values only; the test does not claim semantic image understanding.
$visualCandidates = @(
    [pscustomobject]@{path='C:\refs\scene_main.png';position=0;duplicate=$false;local_risk_score=0.30;local_safe_score=0.70;center_edge_density=0.10;outer_edge_density=0.11},
    [pscustomobject]@{path='C:\refs\scene_safe.png';position=1;duplicate=$false;local_risk_score=0.18;local_safe_score=0.82;center_edge_density=0.08;outer_edge_density=0.10},
    [pscustomobject]@{path='C:\refs\product_center.png';position=2;duplicate=$false;local_risk_score=0.25;local_safe_score=0.75;center_edge_density=0.18;outer_edge_density=0.07},
    [pscustomobject]@{path='C:\refs\multi_object.png';position=3;duplicate=$false;local_risk_score=0.45;local_safe_score=0.55;center_edge_density=0.24;outer_edge_density=0.14},
    [pscustomobject]@{path='C:\refs\package.png';position=4;duplicate=$false;local_risk_score=0.20;local_safe_score=0.80;center_edge_density=0.06;outer_edge_density=0.07}
)
$analysisVisual = [pscustomobject]@{product_id='90000030002';high_variant_conflict=$true;reference_safety=[object[]]$visualCandidates;images=[object[]]$visualCandidates}
$productVisual = $product.PSObject.Copy(); $productVisual.product_id='90000030002'
$planVisual = New-V4BSourceImagePlan $productVisual $analysisVisual
foreach ($slot in @('main','detail2','detail4')) {
    $visual = Get-V4BPlanSlot $planVisual $slot
    Assert-V4BConflict (@($visual.source_indices).Count -eq 1) ($slot + ' product-focus source must remain one source')
    Assert-V4BConflict ([int]$visual.source_indices[0] -eq 2) ($slot + ' should choose center-dominant product source, got position ' + [string]$visual.source_indices[0])
    Assert-V4BConflict ([double]$visual.visual_proxy_center_dominance -gt 0.10) ($slot + ' selected source should expose positive center-dominance proxy')
    Assert-V4BConflict ($visual.fill_reason -match '中心商品訊號') ($slot + ' plan must explain proxy-based source preference')
    Assert-V4BConflict ([string]$visual.source_selection_policy -eq 'product_focus_proxy') ($slot + ' source-selection policy mismatch')
}
Assert-V4BConflict ([bool](Test-V4BSourcePlan $planVisual $false).passed) 'conflict-closure source plan validation failed'

$selDir = Get-SelectionWorkspaceV2
New-Item -ItemType Directory -Path $selDir -Force | Out-Null
$product | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$script:V4BSourcePlanCache[[string]$product.product_id] = $plan
$prompt = Get-PromptV2 'detail4' $product
Assert-V4BConflict ($prompt -match '來源賣家促銷／承諾清理') 'seller-policy cleanup section missing from prompt'
Assert-V4BConflict ($prompt -match '圖示與單位文字硬限制') 'unit-icon cleanup section missing from prompt'
Assert-V4BConflict ($prompt -match '來源文字遮蔽|衝突文字遮蔽') 'shield directive missing from final prompt'
Assert-V4BConflict ($prompt -match '數量／套組數有差異') 'quantity-conflict section missing from prompt'
Assert-V4BConflict ($prompt -notmatch '各5組') 'variant-specific quantity must not be seeded into prompt'
Assert-V4BConflict ($prompt -match '2公尺' -and $prompt -match '30磅' -and $prompt -match '腰帶' -and $prompt -match '黑色') 'common verified facts were lost while suppressing quantity conflict'
$detail3Prompt = Get-PromptV2 'detail3' $product
Assert-V4BConflict ($detail3Prompt -match '程式化驗證文字覆蓋') 'detail3 conflict output must be generated text-free before deterministic overlay'
Assert-V4BConflict ($detail3Prompt -notmatch '區域聯防') 'unsupported source phrase must not be seeded into detail3 prompt'

# A single-variant detail1 can still reconstruct source dimensions/material/performance text even
# without a variant conflict. When structured claim facts are sparse and the selected source has
# moderate visual risk, route through the same text-free + deterministic-overlay closure.
$productSparse = [pscustomobject]@{
    product_id='90000030003';product_name='排球訓練器材';product_category='Sports/Volleyball';variation_name='款式';variants=[object[]]@();
    verified_facts=[pscustomobject]@{verified_numbers=[string[]]@();verified_dimensions=[string[]]@();verified_materials=[string[]]@();verified_accessories=[string[]]@();verified_gifts=[string[]]@();verified_bundle_contents=[string[]]@();verified_colors=[string[]]@();verified_sizes=[string[]]@();verified_models=[string[]]@('VZJ-004S');verified_quantities=[string[]]@();verified_resistance_levels=[string[]]@();verified_features=[string[]]@();verified_use_cases=[string[]]@();verified_certifications=[string[]]@();verified_origin=[string[]]@()};
    multi_variant_flags=[pscustomobject]@{variant_count=1;has_multiple_variants=$false;has_multiple_sizes=$false;has_multiple_colors=$false;has_multiple_quantities=$false;has_multiple_bundle_counts=$false;has_multiple_models=$false;has_multiple_resistance_levels=$false}
}
$sparseCandidates = @(
    [pscustomobject]@{path='C:\refs\cover.png';position=0;duplicate=$false;local_risk_score=0.12;local_safe_score=0.88;center_edge_density=0.10;outer_edge_density=0.08},
    [pscustomobject]@{path='C:\refs\source_text.png';position=1;duplicate=$false;local_risk_score=0.28;local_safe_score=0.72;center_edge_density=0.14;outer_edge_density=0.09}
)
$sparseAnalysis = [pscustomobject]@{product_id='90000030003';high_variant_conflict=$false;reference_safety=[object[]]$sparseCandidates;images=[object[]]$sparseCandidates}
$sparsePlan = New-V4BSourceImagePlan $productSparse $sparseAnalysis
$sparseDetail1 = Get-V4BPlanSlot $sparsePlan 'detail1'
Assert-V4BConflict ([bool]$sparseDetail1.text_shield_required) 'sparse-fact risky detail1 must use source text shield'
Assert-V4BConflict ([string]$sparseDetail1.text_shield_reason -eq 'sparse_verified_facts_source_text_risk') 'sparse detail1 shield reason mismatch'
Assert-V4BConflict ([string]$sparseDetail1.verified_text_policy -eq 'deterministic_overlay_only') 'sparse detail1 must use deterministic overlay'
Assert-V4BConflict ([int]$sparseDetail1.reference_proxy_max_edge -eq 384) 'sparse detail1 must use 384px proxy'
Assert-V4BConflict ([bool](Test-V4BSourcePlan $sparsePlan $false).passed) 'sparse-fact source text closure plan validation failed'
$selDir = Get-SelectionWorkspaceV2;New-Item -ItemType Directory -Path $selDir -Force|Out-Null
$productSparse|ConvertTo-Json -Depth 14|Set-Content -LiteralPath (Join-Path $selDir 'selected_product.json') -Encoding UTF8
$script:V4BSourcePlanCache[[string]$productSparse.product_id]=$sparsePlan
$sparsePrompt = Get-PromptV2 'detail1' $productSparse
Assert-V4BConflict ($sparsePrompt -match '不要生成任何可辨識文字') 'sparse-fact risky detail1 TinySnow stage must be text-free'
Assert-V4BConflict ($sparsePrompt -match 'sparse_verified_facts_source_text_risk') 'sparse detail1 prompt must record shield reason'
$sparseContent = Get-V4BVerifiedOverlayContent $productSparse 'detail1'
Assert-V4BConflict ([string]$sparseContent.secondary -match 'VZJ-004S') 'sparse detail1 overlay must retain verified model'
Assert-V4BConflict ([string]$sparseContent.secondary -notmatch '公分|尼龍|耐用|穩固') 'sparse detail1 overlay invented claims'

Write-Host 'V4-B conflict cleanup, product-focus routing, quantity/sparse-fact text shields, and deterministic-overlay policy smoke: PASS' -ForegroundColor Green
