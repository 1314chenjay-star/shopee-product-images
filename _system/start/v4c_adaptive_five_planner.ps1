# TinySnow V4-C0
# Adaptive five-image planner + free analysis report. No image API calls.

function Test-V4CHasVerifiedFact($Evidence, [string]$FactName) {
    $facts = Get-V4CProperty $Evidence 'verified_facts' $null
    return (@(Get-V4CProperty $facts $FactName @()).Count -gt 0)
}

function Get-V4CSlotRoles($Route, $Evidence) {
    $family = [string](Get-V4CProperty $Route 'family' 'generic')
    $subfamily = [string](Get-V4CProperty $Route 'subfamily' 'unknown')
    $roles = @('product_main','structure_or_detail','variant_or_detail','verified_feature_or_usage','safe_product_detail')

    if ($family -eq 'sports') {
        switch ($subfamily) {
            'ball_sports' { $roles = @('product_main','surface_and_structure','verified_spec_or_detail','authentic_usage_or_variant','accessory_or_safe_detail') }
            'racket_sports' { $roles = @('product_main','frame_grip_structure','verified_spec_or_detail','authentic_usage_or_variant','accessory_or_safe_detail') }
            'fitness_training' { $roles = @('product_main','structure_detail','verified_resistance_or_weight','authentic_usage','accessory_or_safe_detail') }
            'protective_gear' { $roles = @('product_main','wearing_structure','verified_size_or_detail','authentic_usage','safe_product_detail') }
            'water_safety_gear' { $roles = @('product_main','closure_and_structure','verified_safety_spec_or_detail','authentic_usage','safe_product_detail') }
            'billiards' { $roles = @('product_main','cue_or_product_structure','verified_spec_or_detail','authentic_usage_or_variant','accessory_or_safe_detail') }
            'combat_martial_arts' { $roles = @('product_main','training_or_protection_structure','verified_spec_or_detail','authentic_usage','safe_product_detail') }
            'water_sports' { $roles = @('product_main','structure_detail','verified_dimensions_or_detail','authentic_usage','accessory_or_safe_detail') }
            'fishing' { $roles = @('product_main','structure_detail','verified_spec_or_detail','authentic_usage','accessory_or_safe_detail') }
            'outdoor_survival' { $roles = @('product_main','structure_detail','verified_feature_or_detail','authentic_usage','accessory_or_safe_detail') }
            'outdoor_games' { $roles = @('product_main','game_structure','verified_bundle_or_detail','authentic_usage','accessory_or_safe_detail') }
            'golf' { $roles = @('product_main','structure_detail','verified_spec_or_detail','authentic_usage','accessory_or_safe_detail') }
            'outdoor_camping' { $roles = @('product_main','structure_detail','verified_dimensions_or_detail','authentic_usage','accessory_or_safe_detail') }
            'swimming' { $roles = @('product_main','structure_detail','verified_spec_or_detail','authentic_usage','safe_product_detail') }
            'cycling' { $roles = @('product_main','mounting_structure','verified_compatibility_or_detail','authentic_usage','safe_product_detail') }
        }
    }
    elseif ($family -eq 'apparel') { $roles = @('product_main','construction_detail','print_or_variant_detail','authentic_wear_or_variant','waist_hem_or_safe_detail') }
    elseif ($family -eq 'shoes') { $roles = @('product_main','upper_closure_detail','sole_detail','authentic_wear_or_variant','safe_product_detail') }
    elseif ($family -eq 'bags') { $roles = @('product_main','strap_closure_detail','compartment_or_detail','authentic_usage_or_variant','safe_product_detail') }
    elseif ($family -eq 'electronics') { $roles = @('product_main','connector_structure','verified_spec_or_detail','authentic_usage','compatibility_or_safe_detail') }
    elseif ($family -eq 'home_storage' -or $family -eq 'furniture') { $roles = @('product_main','structure_detail','verified_dimensions_or_detail','authentic_usage','installation_or_safe_detail') }
    elseif ($family -eq 'pet') { $roles = @('product_main','structure_detail','verified_size_or_detail','authentic_usage','safe_product_detail') }

    # A role name containing "verified_" is only legal when some structured verified fact exists.
    # Raw title/description/variant text is evidence to inspect, never automatic permission to print a claim.
    $verifiedFactCount = [int](Get-V4CProperty $Evidence 'verified_fact_count' 0)
    for ($i = 0; $i -lt $roles.Count; $i++) {
        $role = [string]$roles[$i]
        if ($role -match 'verified_' -and $verifiedFactCount -le 0) {
            $roles[$i] = 'safe_product_detail'
            continue
        }
        if ($role -match 'dimensions' -and -not (Test-V4CHasVerifiedFact $Evidence 'dimensions')) { $roles[$i] = 'safe_product_detail' }
        if ($role -match 'size' -and -not (Test-V4CHasVerifiedFact $Evidence 'sizes')) { $roles[$i] = 'safe_product_detail' }
        if ($role -match 'resistance' -and -not (Test-V4CHasVerifiedFact $Evidence 'resistance_levels') -and -not (Test-V4CHasVerifiedFact $Evidence 'features')) { $roles[$i] = 'safe_product_detail' }
        if ($role -match 'compatibility' -and -not (Test-V4CHasVerifiedFact $Evidence 'features')) { $roles[$i] = 'safe_product_detail' }
    }
    return [string[]]$roles
}

function Get-V4CSafeDecisions($ImageDecisions) {
    return [object[]]@($ImageDecisions | Where-Object { [string]$_.action -ne 'BLOCK' } | Sort-Object @{Expression='position';Ascending=$true})
}

function New-V4CAdaptiveFivePlan($Product, $Evidence, $Route, $ImageDecisions) {
    $safe = @(Get-V4CSafeDecisions $ImageDecisions)
    $roles = @(Get-V4CSlotRoles $Route $Evidence)
    $slots = @('main','detail1','detail2','detail3','detail4')
    $plans = @()

    if ($safe.Count -eq 0) {
        return [pscustomobject]@{
            slots = @()
            can_enter_v4b = $false
            block_reason = 'no_safe_source_image'
            required_human_review = $true
        }
    }

    for ($i = 0; $i -lt 5; $i++) {
        $source = $safe[$i % $safe.Count]
        $reused = ($i -ge $safe.Count)
        $role = [string]$roles[$i]
        $plans += [pscustomobject]@{
            slot = [string]$slots[$i]
            role = $role
            source_path = [string]$source.path
            source_action = [string]$source.action
            source_reused = $reused
            allow_verified_dimensions = (Test-V4CHasVerifiedFact $Evidence 'dimensions')
            allow_verified_materials = (Test-V4CHasVerifiedFact $Evidence 'materials')
            allow_verified_features = (Test-V4CHasVerifiedFact $Evidence 'features')
            forbid_unverified_claims = $true
            forbid_variant_generalization = $true
        }
    }

    $routeConfidence = [double](Get-V4CProperty $Route 'confidence' 0.0)
    $unknownRoute = ([string](Get-V4CProperty $Route 'family' 'generic') -eq 'generic')
    $sparse = ([string](Get-V4CProperty $Evidence 'evidence_state' 'sparse') -eq 'sparse')
    $requiresReview = ($unknownRoute -or ($routeConfidence -lt 0.55) -or ($sparse -and $safe.Count -lt 2))

    return [pscustomobject]@{
        slots = [object[]]$plans
        can_enter_v4b = (-not $requiresReview)
        block_reason = if ($requiresReview) { 'needs_human_review_before_paid_generation' } else { '' }
        required_human_review = $requiresReview
    }
}

function Invoke-V4C0Analysis($Product, $Analysis) {
    $evidence = New-V4CProductEvidence $Product $Analysis
    $route = Get-V4CCategoryRoute $Product $evidence
    $decisions = @(Get-V4CImageDecisions $Analysis $evidence $route)
    $plan = New-V4CAdaptiveFivePlan $Product $evidence $route $decisions

    return [pscustomobject]@{
        engine = 'TinySnow V4-C0'
        mode = 'free_analysis_only'
        image_api_called = $false
        product_id = [string]$evidence.product_id
        evidence = $evidence
        route = $route
        image_decisions = [object[]]$decisions
        five_image_plan = $plan
        can_enter_paid_generation = [bool]$plan.can_enter_v4b
    }
}
