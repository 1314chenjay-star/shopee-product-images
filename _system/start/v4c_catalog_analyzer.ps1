# TinySnow V4-C0
# Full-catalog free analyzer entrypoint.
# Reads Shopee Excel through v4c_excel_adapter and produces route/review/5-slot plans without image API calls.

. (Join-Path $PSScriptRoot 'v4c_product_evidence.ps1')
. (Join-Path $PSScriptRoot 'v4c_category_router.ps1')
. (Join-Path $PSScriptRoot 'v4c_structural_guard.ps1')
. (Join-Path $PSScriptRoot 'v4c_image_decision.ps1')
. (Join-Path $PSScriptRoot 'v4c_adaptive_five_planner.ps1')
. (Join-Path $PSScriptRoot 'v4c_review_gate.ps1')
. (Join-Path $PSScriptRoot 'v4c_excel_adapter.ps1')

function New-V4CExcelOnlyAnalysis($Product) {
    $images = @()
    $urls = @(Get-V4CProperty $Product 'image_urls' @())
    $position = 0
    foreach ($url in $urls) {
        if ([string]::IsNullOrWhiteSpace([string]$url)) { continue }
        $images += [pscustomobject]@{
            path = [string]$url
            position = $position
            duplicate = $false
            local_risk_score = 0.50
            local_safe_score = 0.50
            near_square = $false
            semantic_review_state = 'NOT_RUN'
        }
        $position++
    }
    return [pscustomobject]@{
        product_id = [string](Get-V4CProperty $Product 'product_id' '')
        images = [object[]]$images
        analysis_mode = 'excel_only_no_image_semantics'
    }
}

function Invoke-V4C0CatalogAnalysis($Products) {
    $results = @()
    foreach ($product in @($Products)) {
        $analysis = New-V4CExcelOnlyAnalysis $product
        $baseResult = Invoke-V4C0Analysis $product $analysis
        # Product-body correction has exactly one authority: v4c_structural_guard.ps1.
        # Do not apply a second override layer after this point; duplicate rewrites make full-catalog routing unstable.
        $route = Get-V4CFinalCategoryRoute $product $baseResult.evidence
        $decisions = @(Get-V4CImageDecisions $analysis $baseResult.evidence $route)
        $plan = New-V4CAdaptiveFivePlan $product $baseResult.evidence $route $decisions
        $gate = Get-V4CReviewGate $product $baseResult.evidence $route

        $results += [pscustomobject]@{
            product_id = [string]$baseResult.product_id
            title = [string](Get-V4CProperty $product 'name' '')
            raw_category = [string](Get-V4CProperty $product 'category' '')
            route = $route
            base_route = $baseResult.route
            structural_guard_changed_route = ($route.family -ne $baseResult.route.family -or $route.subfamily -ne $baseResult.route.subfamily)
            evidence = $baseResult.evidence
            review_gate = $gate
            five_image_plan = $plan
            excel_only_image_actions = [object[]]$decisions
            image_semantic_review_completed = $false
            image_api_called = $false
            final_paid_generation_permission = 'HOLD'
        }
    }

    $high = @($results | Where-Object { $_.review_gate.risk_tier -eq 'HIGH' }).Count
    $medium = @($results | Where-Object { $_.review_gate.risk_tier -eq 'MEDIUM' }).Count
    $low = @($results | Where-Object { $_.review_gate.risk_tier -eq 'LOW' }).Count
    $generic = @($results | Where-Object { $_.route.family -eq 'generic' }).Count
    $structuralChanges = @($results | Where-Object { $_.structural_guard_changed_route }).Count

    return [pscustomobject]@{
        engine = 'TinySnow V4-C0'
        mode = 'full_catalog_free_analysis'
        image_api_called = $false
        product_count = @($results).Count
        structural_guard_change_count = $structuralChanges
        risk_summary = [pscustomobject]@{ high=$high; medium=$medium; low=$low; generic=$generic }
        products = [object[]]$results
    }
}

function Invoke-V4C0CatalogAnalysisFromExcel([string]$Path) {
    $import = Import-V4CShopeeExcel $Path
    return Invoke-V4C0CatalogAnalysis $import.products
}
