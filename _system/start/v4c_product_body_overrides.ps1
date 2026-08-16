# TinySnow V4-C0
# Narrow product-body overrides discovered by full-catalog/B001 review.
# Secondary use-case words such as "車載" must not override the actual product body.

function Test-V4CPrimaryCampingWaterContainer([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    $clean = $Title.Trim()
    $isContainer = ($clean -match '^(?:.{0,6})?(折疊水桶|折叠水桶|伸縮儲水桶|伸缩储水桶|露營水桶|露营水桶|儲水桶|储水桶|戶外水桶|户外水桶)')
    $hasCampingContext = ($clean -match '露營|露营|野營|野营|帳篷|帐篷')
    return ($isContainer -and $hasCampingContext)
}

function Test-V4CPrimarySportsTowel([string]$Title) {
    if ([string]::IsNullOrWhiteSpace($Title)) { return $false }
    $clean = $Title.Trim()
    return ($clean -match '^(?:.{0,6})?(運動吸汗毛巾|运动吸汗毛巾|運動毛巾|运动毛巾|健身毛巾|跑步毛巾|擦汗巾)')
}

function Resolve-V4CProductBodyOverride($Product, $Evidence, $CurrentRoute) {
    $title = [string](Get-V4CProperty $Evidence 'title' (Get-V4CProperty $Product 'name' ''))

    if (Test-V4CPrimaryCampingWaterContainer $title) {
        return New-V4CRoute 'sports' 'outdoor_camping' 0.97 @(
            'capacity','dimensions','material','closure','tap_or_spout','bundle_count','accessories','leakproof_claims'
        ) 'sports_deep'
    }

    if (Test-V4CPrimarySportsTowel $title) {
        return New-V4CRoute 'sports' 'sports_accessory' 0.97 @(
            'dimensions','material','absorbency_claims','drying_claims','color_variant','bundle_count'
        ) 'sports_deep'
    }

    return $CurrentRoute
}
