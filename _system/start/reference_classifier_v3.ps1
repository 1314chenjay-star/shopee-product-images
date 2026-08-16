$ErrorActionPreference = 'Stop'

function Get-V4A3Clamp01([double]$Value) {
    return [Math]::Max(0.0, [Math]::Min(1.0, $Value))
}

function Get-V4A3ReferenceClassifications($Analysis) {
    if ($null -eq $Analysis) { throw 'V4-A.3：缺少原圖分析資料。' }

    $items = @(Get-V4A1Property $Analysis 'reference_safety' @())
    if ($items.Count -eq 0) { $items = @(Get-V4A1Property $Analysis 'images' @()) }
    if ($items.Count -eq 0) { throw 'V4-A.3：沒有可分類的參考圖。' }

    $highConflict = [bool](Get-V4A1Property $Analysis 'high_variant_conflict' $false)
    $classified = @()

    foreach ($item in $items) {
        $path = [string](Get-V4A1Property $item 'path' '')
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $position = [int](Get-V4A1Property $item 'position' 0)
        $risk = [double](Get-V4A1Property $item 'local_risk_score' 0.50)
        $safe = [double](Get-V4A1Property $item 'local_safe_score' (1.0 - $risk))
        $edge = [double](Get-V4A1Property $item 'edge_density' 0.0)
        $outer = [double](Get-V4A1Property $item 'outer_edge_density' 0.0)
        $nearSquare = [bool](Get-V4A1Property $item 'near_square' $false)

        # These are deliberately conservative visual/use proxies, not OCR or semantic claims.
        # Every class exists as a score so downstream planning can make safe fallback decisions.
        $pureProduct = 0.20
        if ($position -eq 0) { $pureProduct = 0.88 }
        elseif ($nearSquare -and $risk -lt 0.42) { $pureProduct = 0.58 }
        elseif ($risk -lt 0.30) { $pureProduct = 0.48 }

        $detailStructure = 0.28
        if ($position -gt 0) { $detailStructure += 0.18 }
        $detailStructure += [Math]::Min(0.24, $edge * 1.6)
        if ($risk -gt 0.58) { $detailStructure -= 0.12 }

        $usageScene = 0.18
        if ($position -ge 2) { $usageScene += 0.18 }
        if ($outer -lt 0.09) { $usageScene += 0.12 }
        if ($risk -gt 0.56) { $usageScene -= 0.08 }

        # Text/spec/size/accessory/packaging cannot be known reliably without semantic vision.
        # Keep these low-confidence fallback scores and let safety outrank them.
        $informationPanel = 0.14
        if ($edge -gt 0.09 -or $outer -gt 0.08) { $informationPanel += 0.16 }
        if ($position -ge 2) { $informationPanel += 0.06 }

        $accessory = 0.16
        if ($position -ge 1) { $accessory += 0.12 }
        if ($detailStructure -gt 0.52) { $accessory += 0.08 }

        $packaging = 0.12
        if ($position -ge 3) { $packaging += 0.12 }

        $multiVariant = if ($highConflict) { 0.72 } else { 0.10 }
        $promoRisky = Get-V4A3Clamp01 $risk
        $singleVariantRisky = if ($highConflict) { Get-V4A3Clamp01 (0.58 + 0.25 * $risk) } else { 0.08 }

        $scores = [ordered]@{
            pure_product = (Get-V4A3Clamp01 $pureProduct)
            detail_structure = (Get-V4A3Clamp01 $detailStructure)
            usage_scene = (Get-V4A3Clamp01 $usageScene)
            spec_info = (Get-V4A3Clamp01 $informationPanel)
            size_info = (Get-V4A3Clamp01 ($informationPanel * 0.95))
            accessory = (Get-V4A3Clamp01 $accessory)
            packaging = (Get-V4A3Clamp01 $packaging)
            multi_variant = (Get-V4A3Clamp01 $multiVariant)
            promo_risky = (Get-V4A3Clamp01 $promoRisky)
            single_variant_risky = (Get-V4A3Clamp01 $singleVariantRisky)
        }

        $classes = @()
        foreach ($name in @('pure_product','detail_structure','usage_scene','spec_info','size_info','accessory','packaging','multi_variant','promo_risky','single_variant_risky')) {
            $threshold = 0.55
            if ($name -eq 'promo_risky' -or $name -eq 'single_variant_risky') { $threshold = 0.50 }
            if ([double]$scores[$name] -ge $threshold) { $classes += $name }
        }
        if ($classes.Count -eq 0) { $classes += 'unknown' }

        $classified += [pscustomobject]@{
            path = $path
            position = $position
            local_risk_score = [Math]::Round($risk,4)
            local_safe_score = [Math]::Round($safe,4)
            classes = [string[]]$classes
            class_scores = [pscustomobject]$scores
            semantic_confidence = 'proxy_only_no_ocr'
        }
    }

    return [object[]]$classified
}
