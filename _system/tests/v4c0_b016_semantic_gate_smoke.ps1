$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B016 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b015_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b016_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B016') 'batch must be B016.'
Assert-True ($summary.touched_product_count -eq 10) 'B016 must touch ten products.'
Assert-True ($summary.complete_product_count -eq 9) 'B016 must complete nine products.'
Assert-True ($summary.partial_product_count -eq 1) 'B016 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 55) 'B016 must account for 50 new + 5 carried images.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B016 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 5) 'B016 must carry exactly five B015 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 1) 'B016 must have one edit-only pass.'
Assert-True ($summary.complete_blocked_count -eq 8) 'B016 must have eight complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B016 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B016 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B015/B016 chain must be valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 5) 'B016 chain must verify five carried sources.'

$target = Get-V4CSemanticProductGate $current '49615708782'
Assert-True ($target.product_review_complete -eq $true) '49615708782 must complete 9/9.'
Assert-True ($target.reviewed_source_image_count -eq 9) '49615708782 must have nine reviewed sources.'
Assert-True ($target.newly_reviewed_source_image_count -eq 4) '49615708782 must add sequences 751-754.'
Assert-True ($target.carried_forward_source_image_count -eq 5) '49615708782 must carry five B015 sources.'
Assert-True ($target.can_enter_v4b -eq $false) '49615708782 must stay blocked after complete review.'
Assert-True ((@($target.blocked_claim_keys) -join ' ') -match 'MENGHU_surface_brand_authenticity') 'B015 brand block must be preserved exactly.'
Assert-True ((@($target.variant_constraints) -join ' ') -match 'B015_reviews_only_first_five_of_nine') 'B015 partial constraint must be preserved exactly.'
Assert-True ((@($target.blocked_claim_keys) -join ' ') -match 'safety_protection_claim') 'safety-protection claim must remain blocked.'

foreach ($id in @('49815620676','50165595515','50465698921','50565615202','50615605689','50715745127','50765595492')) {
    $g = Get-V4CSemanticProductGate $current $id
    Assert-True ($g.can_enter_v4b -eq $false) ('blocked product may not enter V4-B: ' + $id)
    Assert-True ($g.source_action -eq 'BLOCK') ('blocked product must keep BLOCK source action: ' + $id)
}

$gloves = Get-V4CSemanticProductGate $current '49815620676'
Assert-True ((@($gloves.blocked_claim_keys) -join ' ') -match 'safety_for_climbing_or_work_claim') 'climbing/work safety claim must stay blocked.'

$slider = Get-V4CSemanticProductGate $current '50165595515'
Assert-True ((@($slider.variant_constraints) -join ' ') -match 'six_catalog_style_options_require_bundle_mapping') 'fitness slider bundle mapping must stay explicit.'

$paddle = Get-V4CSemanticProductGate $current '50465698921'
Assert-True ((@($paddle.variant_constraints) -join ' ') -match 'twenty_catalog_style_options_require_exact_mapping') 'table-tennis 20-option mapping must stay explicit.'
Assert-True ((@($paddle.blocked_claim_keys) -join ' ') -match 'PEAK_surface_brand_authenticity') 'PEAK surface-brand risk must stay blocked.'

$cue = Get-V4CSemanticProductGate $current '50565615202'
Assert-True ((@($cue.variant_constraints) -join ' ') -match 'catalog_options_沧海_and_狼牙_are_not_mapped_to_reviewed_source') 'cue source/catalog model conflict must stay explicit.'

$chalk = Get-V4CSemanticProductGate $current '50615605689'
Assert-True ((@($chalk.blocked_claim_keys) -join ' ') -match 'OLIPHANT_surface_brand_authenticity') 'OLIPHANT surface-brand risk must stay blocked.'
Assert-True ((@($chalk.blocked_claim_keys) -join ' ') -match '144_piece_quantity_commonality') '144-piece quantity must not be generalized.'

$squash = Get-V4CSemanticProductGate $current '50665653092'
Assert-True ($squash.can_enter_v4b -eq $true) '50665653092 should be the single edit-only handoff.'
Assert-True ($squash.semantic_verdict -eq 'PASS_EDIT_ONLY') '50665653092 must be PASS_EDIT_ONLY.'
Assert-True ($squash.allowed_generation_mode -eq 'EDIT_PRESERVE_LOCALIZE') '50665653092 must stay edit/preserve/localize.'
Assert-True ((@($squash.blocked_claim_keys) -join ' ') -match 'carbon_composite_material') 'carbon material claim must remain stripped.'

$jersey = Get-V4CSemanticProductGate $current '50715745127'
Assert-True ((@($jersey.variant_constraints) -join ' ') -match 'twenty_eight_catalog_color_options_require_exact_mapping') '28-option jersey mapping must stay explicit.'
Assert-True ((@($jersey.blocked_claim_keys) -join ' ') -match 'team_school_logo_rights') 'team/school logo rights must stay blocked.'

$mat = Get-V4CSemanticProductGate $current '50765595492'
Assert-True ((@($mat.variant_constraints) -join ' ') -match 'fifteen_catalog_style_options_require_mapping') '15-option mat mapping must stay explicit.'
Assert-True ((@($mat.blocked_claim_keys) -join ' ') -match '60x40x6cm_dimension_commonality') '60x40x6cm must not be generalized.'

$partial = Get-V4CSemanticProductGate $current '50765665403'
Assert-True ($partial.product_review_complete -eq $false) '50765665403 must remain incomplete at B016 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 4) '50765665403 must have four reviewed sources in B016.'
Assert-True ($partial.total_source_image_count -eq 6) '50765665403 total source count must remain six.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '50765665403 must use partial-source block.'
Assert-True ($partial.can_enter_v4b -eq $false) '50765665403 may not enter V4-B before B017.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match '801_802') '50765665403 must explicitly request B017 sequences 801-802.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary: 4/6 may never be false-completed.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '50765665403' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 10
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 50765665403 at 4/6 sources.'

Write-Host 'V4-C0 B016 semantic gate smoke: PASS'
