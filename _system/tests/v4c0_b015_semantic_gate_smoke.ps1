$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B015 semantic gate smoke failed: {0}" -f $Message) }
}

$prior = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b014_semantic_review.json')
$current = Import-V4CSemanticReview (Join-Path $root 'reports\v4c0_b015_semantic_review.json')
$summary = Assert-V4CSemanticReview $current

Assert-True ($summary.batch_id -eq 'B015') 'batch must be B015.'
Assert-True ($summary.touched_product_count -eq 12) 'B015 must touch twelve products.'
Assert-True ($summary.complete_product_count -eq 11) 'B015 must complete eleven products.'
Assert-True ($summary.partial_product_count -eq 1) 'B015 must preserve one partial boundary product.'
Assert-True ($summary.reviewed_source_image_count -eq 58) 'B015 must account for 50 new + 8 carried images.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B015 must add exactly fifty new source reviews.'
Assert-True ($summary.carried_forward_source_image_count -eq 8) 'B015 must carry exactly eight B014 sources.'
Assert-True ($summary.complete_pass_edit_only_count -eq 3) 'B015 must have three edit-only passes.'
Assert-True ($summary.complete_blocked_count -eq 8) 'B015 must have eight complete blocked products.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B015 may not authorize paid generation.'
Assert-True ($summary.image_api_called -eq $false) 'B015 must remain free-analysis only.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B014/B015 chain must be valid.'
Assert-True ($chain.carried_forward_source_image_count -eq 8) 'B015 chain must verify eight carried sources.'

$cartoon = Get-V4CSemanticProductGate $current '47515718388'
Assert-True ($cartoon.product_review_complete -eq $true) '47515718388 must complete 9/9.'
Assert-True ($cartoon.reviewed_source_image_count -eq 9) '47515718388 must have nine reviewed sources.'
Assert-True ($cartoon.newly_reviewed_source_image_count -eq 1) '47515718388 must add sequence 701 only.'
Assert-True ($cartoon.carried_forward_source_image_count -eq 8) '47515718388 must carry eight B014 sources.'
Assert-True ($cartoon.can_enter_v4b -eq $false) '47515718388 must stay blocked after full review.'
Assert-True ((@($cartoon.blocked_claim_keys) -join ' ') -match 'cartoon_character_IP_rights') 'prior IP block must be preserved.'
Assert-True ((@($cartoon.variant_constraints) -join ' ') -match 'reviewed_sources_show_childlike_cartoon_paddle_family_not_catalog_professional_racket_identity') 'prior identity constraint must be preserved.'

$sleep = Get-V4CSemanticProductGate $current '47565681387'
Assert-True ($sleep.can_enter_v4b -eq $false) '5cm vs 8cm camping mat must stay blocked.'
Assert-True ((@($sleep.variant_constraints) -join ' ') -match '5cm_thickness_conflicts_with_source_8cm') 'thickness conflict must remain explicit.'

$squash = Get-V4CSemanticProductGate $current '48465673133'
Assert-True ($squash.can_enter_v4b -eq $false) 'SKY.X/nylon vs 40T/SY1027 source must stay blocked.'
Assert-True ((@($squash.variant_constraints) -join ' ') -match 'SKY_X_and_nylon') 'material/brand conflict must remain explicit.'

$volley = Get-V4CSemanticProductGate $current '48465764224'
Assert-True ($volley.can_enter_v4b -eq $false) 'ANISIA surface-brand volleyball listing must stay blocked.'
Assert-True ((@($volley.blocked_claim_keys) -join ' ') -match 'ANISIA_surface_brand_authenticity') 'ANISIA surface-brand risk must remain explicit.'

$eagle = Get-V4CSemanticProductGate $current '48665673034'
Assert-True ($eagle.can_enter_v4b -eq $false) 'SALYWE/EAGLE racket must stay blocked pending mapping.'
Assert-True ((@($eagle.blocked_claim_keys) -join ' ') -match 'SALYWE_surface_brand_authenticity') 'SALYWE brand risk must remain explicit.'

$balls = Get-V4CSemanticProductGate $current '48665673037'
Assert-True ($balls.can_enter_v4b -eq $false) 'Teloon 3-can bundle must stay blocked pending quantity verification.'
Assert-True ((@($balls.blocked_claim_keys) -join ' ') -match 'three_can_bundle_commonality') '3-can bundle must not be inferred.'

$tent = Get-V4CSemanticProductGate $current '48765681437'
Assert-True ($tent.can_enter_v4b -eq $false) 'tent weather/capacity bundle must stay blocked.'
Assert-True ((@($tent.blocked_claim_keys) -join ' ') -match '2000_3000mm_waterproof_rating') 'waterproof rating must remain blocked.'

$teloon = Get-V4CSemanticProductGate $current '48865673105'
Assert-True ($teloon.can_enter_v4b -eq $false) 'generic catalog vs Teloon model/bundle must stay blocked.'
Assert-True ((@($teloon.variant_constraints) -join ' ') -match 'Y_TEC_Ultra_II_TOUR170_TOUR171') 'Teloon model comparison must remain explicit.'

foreach ($id in @('49015609654','49115619683','49565735774')) {
    $g = Get-V4CSemanticProductGate $current $id
    Assert-True ($g.can_enter_v4b -eq $true) ('edit-only product should enter V4-B handoff: ' + $id)
    Assert-True ($g.semantic_verdict -eq 'PASS_EDIT_ONLY') ('pass product must be PASS_EDIT_ONLY: ' + $id)
    Assert-True ($g.allowed_generation_mode -eq 'EDIT_PRESERVE_LOCALIZE') ('pass product must stay edit/preserve/localize: ' + $id)
}

$bag = Get-V4CSemanticProductGate $current '49015609654'
Assert-True ((@($bag.blocked_claim_keys) -join ' ') -match 'IPX6_waterproof_claim') 'IPX6 claim must be stripped from edit-only handoff.'

$cleaner = Get-V4CSemanticProductGate $current '49115619683'
Assert-True ((@($cleaner.blocked_claim_keys) -join ' ') -match 'static_removal_claim') 'static-removal claim must remain unverified.'

$net = Get-V4CSemanticProductGate $current '49565735774'
Assert-True ((@($net.blocked_claim_keys) -join ' ') -match 'storage_bag_inclusion') 'storage bag must not be inferred.'

$partial = Get-V4CSemanticProductGate $current '49615708782'
Assert-True ($partial.product_review_complete -eq $false) '49615708782 must remain incomplete at B015 boundary.'
Assert-True ($partial.reviewed_source_image_count -eq 5) '49615708782 must have five reviewed sources in B015.'
Assert-True ($partial.total_source_image_count -eq 9) '49615708782 total source count must remain nine.'
Assert-True ($partial.semantic_verdict -eq 'BLOCK_PARTIAL_SOURCE_SET') '49615708782 must use partial-source block.'
Assert-True ($partial.can_enter_v4b -eq $false) '49615708782 may not enter V4-B before B016.'
Assert-True ((@($partial.next_evidence_required) -join ' ') -match '751_754') '49615708782 must explicitly request B016 sequences 751-754.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative boundary: 5/9 may never be false-completed.
$bad = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badPartial = @($bad.products | Where-Object { [string]$_.product_id -eq '49615708782' })[0]
$badPartial.product_review_complete = $true
$badPartial.verdict = 'PASS_EDIT_ONLY'
$badPartial.eligible_for_v4b = $true
$badPartial.source_action = 'EDIT'
$bad.review_scope.complete_product_count = 12
$bad.review_scope.partial_product_count = 0
$threw = $false
try { $null = Assert-V4CSemanticReview $bad } catch { $threw = $true }
Assert-True $threw 'gate must reject false completion of 49615708782 at 5/9 sources.'

Write-Host 'V4-C0 B015 semantic gate smoke: PASS'
