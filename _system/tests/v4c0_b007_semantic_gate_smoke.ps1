$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B007 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b006_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b007_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B007') 'batch must be B007.'
Assert-True ($summary.touched_product_count -eq 8) 'B007 must touch eight products.'
Assert-True ($summary.complete_product_count -eq 7) 'B007 must have seven complete products.'
Assert-True ($summary.partial_product_count -eq 1) 'B007 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 54) 'B007 cumulative accounting must be fifty-four with four carried sources.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B007 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 4) 'B007 must carry exactly four B006 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 0) 'B007 must not pass any complete product to edit-only.'
Assert-True ($summary.complete_blocked_count -eq 7) 'B007 must have seven complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B007 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B007 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B006/B007 validation chain must be structurally valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 4) 'B007 chain must verify exactly four carried sources.'

$kick = Get-V4CSemanticProductGate $current '50565689852'
Assert-True ($kick.product_review_complete -eq $true) 'kick target must become complete in B007.'
Assert-True ($kick.reviewed_source_image_count -eq 7) 'kick target must account for all seven sources.'
Assert-True ($kick.newly_reviewed_source_image_count -eq 3) 'kick target must add three B007 sources.'
Assert-True ($kick.carried_forward_source_image_count -eq 4) 'kick target must carry four B006 sources.'
Assert-True ($kick.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'kick target must remain blocked after full review because red/blue and bundle mappings are unresolved.'
Assert-True ($kick.can_enter_v4b -eq $false) 'kick target may not enter V4-B.'
Assert-True ((@($kick.variant_constraints) -join ' ') -match 'final_source_set_still_does_not_map_red_blue_or_two_piece_options') 'kick target must retain unresolved color/bundle mapping.'

$hand = Get-V4CSemanticProductGate $current '50665689775'
Assert-True ($hand.can_enter_v4b -eq $false) 'curved hand-target listing must stay blocked.'
Assert-True ($hand.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'hand target must require variant mapping.'
Assert-True ((@($hand.variant_constraints) -join ' ') -match 'all_seven_reviewed_sources_show_one_black_gold') 'all reviewed hand-target sources must be recognized as one black/gold structure.'
Assert-True ((@($hand.blocked_claim_keys) -join ' ') -match 'pu_material') 'hand-target PU claim must remain unverified.'

$wrist = Get-V4CSemanticProductGate $current '50815548038'
Assert-True ($wrist.can_enter_v4b -eq $false) 'wrist-wrap source/catalog conflict must stay blocked.'
Assert-True ($wrist.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'wrist wrap must require source/catalog remapping.'
Assert-True ((@($wrist.variant_constraints) -join ' ') -match 'catalog_has_only_one_black_wrap_option_and_title_states_single_piece') 'single black catalog structure must be retained.'
Assert-True ((@($wrist.variant_constraints) -join ' ') -match 'two_piece_configuration') 'two-piece source conflict must be retained.'
Assert-True ((@($wrist.variant_constraints) -join ' ') -match 'black_red_and_blue') 'multi-color source conflict must be retained.'

$balls = Get-V4CSemanticProductGate $current '51165665481'
Assert-True ($balls.can_enter_v4b -eq $false) 'mixed baseball/softball/IP listing must stay blocked.'
Assert-True ($balls.semantic_verdict -eq 'BLOCK_IP_RIGHTS_AND_VARIANT_MAPPING_REQUIRED') 'ball listing must require rights and option mapping.'
Assert-True ((@($balls.blocked_claim_keys) -join ' ') -match 'licensed_character_or_mark_rights') 'licensed-character/mark rights must be verified.'
Assert-True ((@($balls.blocked_claim_keys) -join ' ') -match 'person_likeness_or_endorsement_rights') 'printed person likeness may not imply endorsement.'
Assert-True ((@($balls.variant_constraints) -join ' ') -match 'display_stand') 'display stand must remain a separate catalog option.'

$bag = Get-V4CSemanticProductGate $current '51315693099'
Assert-True ($bag.can_enter_v4b -eq $false) 'inflatable punching-column listing must stay blocked.'
Assert-True ($bag.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'inflatable punching column must require mapping.'
Assert-True ((@($bag.variant_constraints) -join ' ') -match 'fifteen_options') '15-option risk must be preserved.'
Assert-True ((@($bag.blocked_claim_keys) -join ' ') -match 'hand_pump_or_foot_pump_bundle_commonality') 'pump bundle must not be generalized.'

$mouth = Get-V4CSemanticProductGate $current '51765544621'
Assert-True ($mouth.can_enter_v4b -eq $false) 'mouthguard must stay blocked on safety and mapping.'
Assert-True ($mouth.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS_AND_VARIANT_MAPPING_REQUIRED') 'mouthguard must use combined high-risk/mapping block.'
Assert-True ((@($mouth.blocked_claim_keys) -join ' ') -match 'mouth_or_tooth_injury_protection_claim') 'mouth/tooth protection claim must stay blocked.'
Assert-True ((@($mouth.blocked_claim_keys) -join ' ') -match '70_80c_molding_temperature') 'molding temperature must be product-spec verified.'
Assert-True ((@($mouth.variant_constraints) -join ' ') -match 'wrist_guard') 'wrist-guard bundle mismatch must be explicit.'

$leg = Get-V4CSemanticProductGate $current '52915734524'
Assert-True ($leg.can_enter_v4b -eq $false) 'athlete/team-themed leg-sleeve listing must stay blocked.'
Assert-True ($leg.semantic_verdict -eq 'BLOCK_IP_RIGHTS_AND_VARIANT_MAPPING_REQUIRED') 'leg sleeves must require rights and option mapping.'
Assert-True ((@($leg.blocked_claim_keys) -join ' ') -match 'athlete_likeness_or_endorsement_rights') 'athlete-likeness rights must be verified.'
Assert-True ((@($leg.blocked_claim_keys) -join ' ') -match 'wristband_gift_promotion') 'gift promotion must not become bundle evidence.'
Assert-True ((@($leg.variant_constraints) -join ' ') -match 'many_named_athlete_team') 'named-athlete/team option complexity must be retained.'

$partial = Get-V4CSemanticProductGate $current '54265715317'
Assert-True ($partial.product_review_complete -eq $false) 'racket bag must remain incomplete at B007 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 8) 'racket bag must have eight of nine sources reviewed.'
Assert-True ($partial.total_source_image_count -eq 9) 'racket bag total source count must remain nine.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') 'racket bag must use partial-source block.'
Assert-True ($partial.can_enter_v4b -eq $false) 'racket bag may not enter V4-B before B008.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match 'remaining_one_source_image_in_B008') 'racket bag must explicitly request final B008 source.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary test: 8/9 racket-bag sources may never be marked complete.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '54265715317' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 8
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of racket bag at 8/9 sources.'

Write-Host 'V4-C0 B007 semantic gate smoke: PASS'