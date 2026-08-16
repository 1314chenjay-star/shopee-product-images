# TinySnow V4-C0
# Free source-image action decision. This layer never calls an image API.

function Get-V4CImageItems($Analysis) {
    if ($null -eq $Analysis) { return [object[]]@() }
    $items = @(Get-V4CProperty $Analysis 'reference_safety' @())
    if ($items.Count -eq 0) { $items = @(Get-V4CProperty $Analysis 'images' @()) }
    return [object[]]$items
}

function Get-V4CImageAction($Item, $Evidence, $Route) {
    $path = [string](Get-V4CProperty $Item 'path' '')
    $risk = [double](Get-V4CProperty $Item 'local_risk_score' 0.50)
    $safe = [double](Get-V4CProperty $Item 'local_safe_score' (1.0 - $risk))
    $duplicate = [bool](Get-V4CProperty $Item 'duplicate' $false)
    $nearSquare = [bool](Get-V4CProperty $Item 'near_square' $false)
    $position = [int](Get-V4CProperty $Item 'position' 0)
    $variantRisk = Get-V4CProperty $Evidence 'variant_risk' $null
    $highConflict = [bool](Get-V4CProperty $variantRisk 'high_conflict' $false)
    $factCount = [int](Get-V4CProperty $Evidence 'verified_fact_count' 0)

    if ($duplicate) {
        return [pscustomobject]@{ path=$path; position=$position; action='BLOCK'; reason='duplicate_source'; confidence=1.0; local_risk_score=$risk }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        return [pscustomobject]@{ path=$path; position=$position; action='BLOCK'; reason='missing_source_path'; confidence=1.0; local_risk_score=$risk }
    }
    if ($highConflict -and $risk -ge 0.55) {
        return [pscustomobject]@{ path=$path; position=$position; action='BLOCK'; reason='high_variant_conflict_and_high_visual_risk'; confidence=0.92; local_risk_score=$risk }
    }

    # Explicit upstream semantic flags may be used if available. V4-C0 itself does not pretend to OCR.
    $needsLocalization = [bool](Get-V4CProperty $Item 'needs_localization' $false)
    $hasPromo = [bool](Get-V4CProperty $Item 'has_promotional_text' $false)
    $hasWatermark = [bool](Get-V4CProperty $Item 'has_seller_watermark' $false)
    $lowQuality = [bool](Get-V4CProperty $Item 'low_quality' $false)

    if ($lowQuality) {
        if ($factCount -gt 0 -and -not $highConflict) {
            return [pscustomobject]@{ path=$path; position=$position; action='REBUILD'; reason='explicit_low_quality_with_verified_evidence'; confidence=0.82; local_risk_score=$risk }
        }
        return [pscustomobject]@{ path=$path; position=$position; action='BLOCK'; reason='low_quality_without_safe_rebuild_evidence'; confidence=0.90; local_risk_score=$risk }
    }
    if ($hasPromo -or $hasWatermark) {
        return [pscustomobject]@{ path=$path; position=$position; action='EDIT'; reason='explicit_cleanup_required'; confidence=0.90; local_risk_score=$risk }
    }
    if ($needsLocalization) {
        return [pscustomobject]@{ path=$path; position=$position; action='LOCALIZE'; reason='explicit_localization_required'; confidence=0.90; local_risk_score=$risk }
    }

    # Without semantic flags, preserve authentic source rather than inventing a reason to modify it.
    if ($risk -le 0.48 -or $nearSquare) {
        return [pscustomobject]@{ path=$path; position=$position; action='PRESERVE'; reason='safe_authentic_source_no_semantic_edit_signal'; confidence=[Math]::Round([Math]::Max(0.55,$safe),2); local_risk_score=$risk }
    }

    # Higher proxy risk is not proof of bad content. Keep source but require downstream cautious handling.
    return [pscustomobject]@{ path=$path; position=$position; action='PRESERVE'; reason='preserve_with_caution_proxy_only'; confidence=0.52; local_risk_score=$risk }
}

function Get-V4CImageDecisions($Analysis, $Evidence, $Route) {
    $items = @(Get-V4CImageItems $Analysis)
    $decisions = @()
    foreach ($item in $items) {
        $decisions += Get-V4CImageAction $item $Evidence $Route
    }
    return [object[]]$decisions
}
