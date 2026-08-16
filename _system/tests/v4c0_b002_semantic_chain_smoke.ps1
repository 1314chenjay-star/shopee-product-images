$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'start\v4c_semantic_result_gate.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ("V4-C0 B002 semantic chain smoke failed: {0}" -f $Message) }
}

$priorPath = Join-Path $root 'reports\v4c0_b001_semantic_review_r2.json'
$currentPath = Join-Path $root 'reports\v4c0_b002_semantic_review.json'
$prior = Import-V4CSemanticReview $priorPath
$current = Import-V4CSemanticReview $currentPath

$summary = Assert-V4CSemanticReview $current
Assert-True ($summary.batch_id -eq 'B002') 'batch must be B002.'
Assert-True ($summary.touched_product_count -eq 12) 'B002 must touch 12 products.'
Assert-True ($summary.complete_product_count -eq 12) 'all B002 touched products must be complete after carry-forward.'
Assert-True ($summary.partial_product_count -eq 0) 'B002 must have no partial products.'
Assert-True ($summary.reviewed_source_image_count -eq 54) 'B002 cumulative accounted image count must be 54.'
Assert-True ($summary.batch_source_image_count -eq 50) 'B002 must add exactly 50 newly reviewed source images.'
Assert-True ($summary.carried_forward_source_image_count -eq 4) 'B002 must carry exactly four B001 source reviews.'
Assert-True ($summary.complete_pass_edit_only_count -eq 9) 'B002 must have nine complete PASS_EDIT_ONLY products.'
Assert-True ($summary.complete_blocked_count -eq 3) 'B002 must have three complete blocked products.'
Assert-True ($summary.image_api_called -eq $false) 'B002 semantic review must remain free-analysis only.'
Assert-True ($summary.final_paid_generation_permission -eq 'HOLD') 'B002 may not authorize paid generation.'

$chain = Assert-V4CSemanticReviewChain $prior $current
Assert-True ($chain.valid -eq $true) 'B001 to B002 chain must validate.'
Assert-True ($chain.prior_batch_id -eq 'B001') 'chain prior batch must be B001.'
Assert-True ($chain.current_batch_id -eq 'B002') 'chain current batch must be B002.'
Assert-True ($chain.carried_forward_source_image_count -eq 4) 'chain must verify four carried images.'
Assert-True ($chain.final_paid_generation_permission -eq 'HOLD') 'chain may not authorize payment.'

$fingerTape = Get-V4CSemanticProductGate $current '48365764139'
Assert-True ($fingerTape.product_review_complete -eq $true) 'finger tape must become complete after B002 source 5/5.'
Assert-True ($fingerTape.reviewed_source_image_count -eq 5) 'finger tape cumulative reviewed count must be five.'
Assert-True ($fingerTape.total_source_image_count -eq 5) 'finger tape catalog source count must remain five.'
Assert-True ($fingerTape.newly_reviewed_source_image_count -eq 1) 'finger tape must add exactly one B002 image.'
Assert-True ($fingerTape.carried_forward_source_image_count -eq 4) 'finger tape must carry four B001 images.'
Assert-True ($fingerTape.semantic_verdict -eq 'PASS_EDIT_ONLY') 'finger tape should pass only as edit/preserve/localize.'
Assert-True ($fingerTape.can_enter_v4b -eq $true) 'complete finger tape may become eligible for V4-B handoff.'
Assert-True ($fingerTape.allowed_generation_mode -eq 'EDIT_PRESERVE_LOCALIZE') 'finger tape generation mode mismatch.'
Assert-True ($fingerTape.final_paid_generation_permission -eq 'HOLD') 'finger tape handoff eligibility is not paid-generation authorization.'

$underwear = Get-V4CSemanticProductGate $current '49265607225'
Assert-True ($underwear.can_enter_v4b -eq $true) 'underwear may enter edit-only handoff after full review.'
Assert-True ((@($underwear.blocked_claim_keys) -join ' ') -match 'ice_silk_material') 'underwear must block ice-silk material claim.'
Assert-True ((@($underwear.blocked_claim_keys) -join ' ') -match 'nylon_blend_material') 'underwear must keep nylon material text unverified.'
Assert-True ((@($underwear.blocked_claim_keys) -join ' ') -match 'cotton_crotch_material') 'underwear must keep cotton crotch material unverified.'
Assert-True ((@($underwear.blocked_claim_keys) -join ' ') -match 'latex_pad_presence') 'underwear must block unverified latex-pad presence.'

$shortSocks = Get-V4CSemanticProductGate $current '50765595494'
Assert-True ($shortSocks.can_enter_v4b -eq $true) 'short yoga socks may enter edit-only handoff.'
Assert-True ((@($shortSocks.variant_constraints) -join ' ') -match 'single_pair_two_pair') 'short yoga socks must isolate single/two-pair quantity variants.'

$knee = Get-V4CSemanticProductGate $current '55565871232'
Assert-True ($knee.can_enter_v4b -eq $false) 'mixed knee-brace source models must stay blocked.'
Assert-True ($knee.semantic_verdict -eq 'BLOCK_VARIANT_MAPPING_REQUIRED') 'mixed knee-brace models require variant mapping.'
Assert-True ((@($knee.variant_constraints) -join ' ') -match 'nailekesi_yanmao_surface_brand_conflict') 'knee brace must retain mixed surface-brand conflict.'

$toeSocks = Get-V4CSemanticProductGate $current '56215585979'
Assert-True ($toeSocks.can_enter_v4b -eq $true) 'toe yoga socks may enter edit-only handoff.'
Assert-True ((@($toeSocks.variant_constraints) -join ' ') -match 'one_pair_two_pair_three_pair') 'toe socks must isolate one/two/three-pair variants.'
Assert-True ((@($toeSocks.blocked_claim_keys) -join ' ') -match 'antibacterial_health_claim') 'toe socks must block antibacterial health claim.'

$repeller1 = Get-V4CSemanticProductGate $current '40583366910'
$repeller2 = Get-V4CSemanticProductGate $current '44965629854'
foreach ($repeller in @($repeller1,$repeller2)) {
    Assert-True ($repeller.can_enter_v4b -eq $false) 'animal repeller efficacy products must stay blocked.'
    Assert-True ($repeller.semantic_verdict -eq 'BLOCK_HIGH_RISK_CLAIMS') 'animal repeller verdict must be high-risk block.'
    Assert-True ((@($repeller.blocked_claim_keys) -join ' ') -match 'animal_repelling_effectiveness') 'animal repeller effectiveness must be blocked.'
    Assert-True ((@($repeller.blocked_claim_keys) -join ' ') -match 'infrared_detection_performance') 'animal repeller sensor performance must be blocked.'
}
Assert-True ((@($repeller1.blocked_claim_keys) -join ' ') -match '129db_sound_level') 'first animal repeller must block 129dB claim.'
Assert-True ((@($repeller2.blocked_claim_keys) -join ' ') -match 'twenty_sound_effects') 'second animal repeller must block exact sound-effect count.'

$wallLight = Get-V4CSemanticProductGate $current '44715637697'
Assert-True ($wallLight.can_enter_v4b -eq $true) 'wall light can use edit-only mode after risky text is blocked.'
Assert-True ((@($wallLight.blocked_claim_keys) -join ' ') -match 'ip65_ip67_rating_conflict') 'wall light must retain IP65/IP67 conflict.'

foreach ($p in @($current.products)) {
    Assert-True ([string]$p.final_paid_generation_permission -eq 'HOLD') ('paid permission escaped HOLD: ' + [string]$p.product_id)
}

# Negative chain test 1: carry count may not differ from the prior reviewed count.
$badCarry = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badFinger = @($badCarry.products | Where-Object { [string]$_.product_id -eq '48365764139' })[0]
$badFinger.carried_forward_source_image_count = 3
$badFinger.newly_reviewed_source_image_count = 2
$badCarry.review_scope.carried_forward_source_image_count = 3
$badCarry.review_scope.batch_source_image_count = 51
$threw = $false
try { $null = Assert-V4CSemanticReviewChain $prior $badCarry } catch { $threw = $true }
Assert-True $threw 'chain must reject a carry count that does not match B001.'

# Negative chain test 2: a carried product may not drop an earlier blocked-claim safeguard.
$badClaims = ($current | ConvertTo-Json -Depth 24 | ConvertFrom-Json)
$badClaimsFinger = @($badClaims.products | Where-Object { [string]$_.product_id -eq '48365764139' })[0]
$badClaimsFinger.blocked_claim_keys = @($badClaimsFinger.blocked_claim_keys | Where-Object { [string]$_ -ne 'medical_injury_prevention' })
$threw = $false
try { $null = Assert-V4CSemanticReviewChain $prior $badClaims } catch { $threw = $true }
Assert-True $threw 'chain must reject loss of prior blocked-claim safeguards.'

Write-Host 'V4-C0 B002 chained semantic gate smoke: PASS'
