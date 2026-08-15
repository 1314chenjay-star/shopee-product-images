$ErrorActionPreference = 'Stop'

$script:V4BAnalyzeBase = (Get-Command Analyze-ProductImagesV2 -ErrorAction Stop).ScriptBlock
$script:V4BReferenceSelectorBase = (Get-Command Get-ReferencesForSlotV2 -ErrorAction Stop).ScriptBlock
$script:V4BSourcePlanCache = @{}

function Get-V4BSlotNames {
    return [string[]]@('main','detail1','detail2','detail3','detail4')
}

function Test-V4BQuantityConflict($Product) {
    if ($null -eq $Product) { return $false }
    $flags = Get-V4A1Property $Product 'multi_variant_flags' $null
    return ([bool](Get-V4A1Property $flags 'has_multiple_quantities' $false) -or [bool](Get-V4A1Property $flags 'has_multiple_bundle_counts' $false))
}

function Test-V4BNeedsConflictTextShield($Product, $Analysis, [string]$Slot) {
    if ($Slot -ne 'main' -and $Slot -ne 'detail4') { return $false }
    $highConflict = [bool](Get-V4A1Property $Analysis 'high_variant_conflict' $false)
    if (-not $highConflict) { return $false }
    return (Test-V4BQuantityConflict $Product)
}

function Get-V4BAnalysisCandidates($Analysis) {
    $raw = @()
    if ($null -ne $Analysis -and $Analysis.PSObject.Properties.Name -contains 'reference_safety') {
        $raw = @($Analysis.reference_safety)
    }
    if ($raw.Count -eq 0 -and $null -ne $Analysis -and $Analysis.PSObject.Properties.Name -contains 'images') {
        $raw = @($Analysis.images)
    }
    $seen = @{}
    $result = @()
    foreach ($item in $raw) {
        $path = [string](Get-V4A1Property $item 'path' '')
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if ([bool](Get-V4A1Property $item 'duplicate' $false)) { continue }
        if ($seen.ContainsKey($path)) { continue }
        $seen[$path] = $true
        $center = [double](Get-V4A1Property $item 'center_edge_density' 0.0)
        $outer = [double](Get-V4A1Property $item 'outer_edge_density' 0.0)
        $risk = [double](Get-V4A1Property $item 'local_risk_score' 0.50)
        $safe = [double](Get-V4A1Property $item 'local_safe_score' (1.0 - $risk))
        $centerDominance = [Math]::Max(0.0, $center - $outer)
        $productFocusProxy = 2.5 * $centerDominance + 0.25 * $safe
        $result += [pscustomobject]@{
            path = $path
            position = [int](Get-V4A1Property $item 'position' $result.Count)
            local_risk_score = $risk
            local_safe_score = $safe
            center_edge_density = $center
            outer_edge_density = $outer
            center_dominance = [Math]::Round($centerDominance,4)
            product_focus_proxy = [Math]::Round($productFocusProxy,4)
        }
    }
    return [object[]]@($result | Sort-Object @{Expression='position';Ascending=$true})
}

function Get-V4BSafestCandidate($Candidates) {
    $items = @($Candidates)
    if ($items.Count -eq 0) { return $null }
    return @($items | Sort-Object @{Expression='local_risk_score';Ascending=$true}, @{Expression='position';Ascending=$true} | Select-Object -First 1)[0]
}

function Get-V4BProductFocusCandidate($Candidates) {
    $items = @($Candidates)
    if ($items.Count -eq 0) { return $null }
    # This is deliberately a visual proxy, not semantic recognition or OCR.
    # A detail/spec-friendly source tends to have stronger central structure than outer scene clutter.
    return @($items | Sort-Object @{Expression='product_focus_proxy';Descending=$true}, @{Expression='local_risk_score';Ascending=$true}, @{Expression='position';Ascending=$true} | Select-Object -First 1)[0]
}

function Get-V4BDirectFiveCandidates($Candidates) {
    $items = @($Candidates)
    if ($items.Count -le 5) { return [object[]]@($items | Select-Object -First 5) }
    $picked = @()
    $main = @($items | Where-Object { [int]$_.position -eq 0 } | Select-Object -First 1)
    if ($main.Count -eq 0) { $main = @($items | Select-Object -First 1) }
    if ($main.Count -gt 0) { $picked += $main[0] }
    $rest = @($items | Where-Object { [string]$_.path -ne [string]$picked[0].path } | Sort-Object @{Expression='local_risk_score';Ascending=$true}, @{Expression='position';Ascending=$true})
    foreach ($candidate in $rest) {
        if ($picked.Count -ge 5) { break }
        $picked += $candidate
    }
    return [object[]]$picked
}

function New-V4BSourceImagePlan($Product, $Analysis) {
    if ($null -eq $Analysis) { throw 'V4-B：缺少 Analysis，無法建立原圖保真五圖計畫。' }
    $productId = [string](Get-V4A1Property $Analysis 'product_id' '')
    $candidates = @(Get-V4BAnalysisCandidates $Analysis)
    if ($candidates.Count -eq 0) { throw 'V4-B：沒有可用原圖。' }

    $highConflict = [bool](Get-V4A1Property $Analysis 'high_variant_conflict' $false)
    $quantityConflict = Test-V4BQuantityConflict $Product
    $safest = Get-V4BSafestCandidate $candidates
    $productFocus = Get-V4BProductFocusCandidate $candidates
    $direct = @(Get-V4BDirectFiveCandidates $candidates)
    $slots = Get-V4BSlotNames
    $slotPlans = @()

    for ($i = 0; $i -lt 5; $i++) {
        $slot = [string]$slots[$i]
        $mode = 'single_original'
        $sourceItems = @()
        $reason = '使用現有原圖一對一保真優化。'
        $generic = @()

        if ($i -lt $direct.Count) {
            $sourceItems = @($direct[$i])
        }
        else {
            if ($candidates.Count -eq 1) {
                $sourceItems = @($candidates[0])
                if ($i -eq 4) {
                    $mode = 'generic_fill'
                    $reason = '只有一張原圖；保留同一真實商品視覺，僅加入安全白名單補充文案。'
                    $generic = @(Get-V4BGenericCopyForSlot $Product $slot $true)
                }
                else {
                    $mode = 'single_original'
                    $reason = '只有一張原圖；重複使用同一真實商品來源，不創造新商品畫面。'
                }
            }
            elseif ($highConflict) {
                $sourceItems = @($safest)
                if ($i -eq 4) {
                    $mode = 'generic_fill'
                    $reason = '多規格衝突商品不足五張；使用單一最安全來源與安全白名單，不混合不同規格。'
                    $generic = @(Get-V4BGenericCopyForSlot $Product $slot $true)
                }
                else {
                    $mode = 'single_original'
                    $reason = '多規格衝突商品不足五張；重用單一安全原圖，避免跨規格混圖。'
                }
            }
            elseif ($i -lt 4 -and $candidates.Count -ge 2) {
                $mode = 'recomposed_originals'
                $firstIndex = ($i - $direct.Count) % $candidates.Count
                $secondIndex = ($firstIndex + 1) % $candidates.Count
                $sourceItems = @($candidates[$firstIndex])
                if ([string]$candidates[$secondIndex].path -ne [string]$candidates[$firstIndex].path) { $sourceItems += $candidates[$secondIndex] }
                $reason = '原圖不足五張；只從既有原圖內容重新裁切／整理／組合，不新增商品事實。'
            }
            else {
                $mode = 'generic_fill'
                $sourceItems = @($safest)
                $reason = '原圖內容不足以形成另一張獨立來源圖；保留真實來源，只允許安全白名單補充文案。'
                $generic = @(Get-V4BGenericCopyForSlot $Product $slot $true)
            }
        }

        # For a high-conflict quantity product, detail4 must not default to a busy scene merely because
        # it is next in position/risk order. Prefer a deterministic center-dominant visual source.
        # This remains category-agnostic and does not claim semantic image understanding.
        if ($slot -eq 'detail4' -and $highConflict -and $quantityConflict -and $null -ne $productFocus) {
            $sourceItems = @($productFocus)
            $reason = '多規格數量衝突的規格／補充圖：優先使用中心商品訊號較強、外圍場景較少的真實原圖，再遮蔽衝突文字；不依商品ID或類目硬編碼。'
        }

        $shield = Test-V4BNeedsConflictTextShield $Product $Analysis $slot
        $slotPlans += [pscustomobject]@{
            slot = $slot
            source_mode = $mode
            source_paths = [string[]]@($sourceItems | ForEach-Object { [string]$_.path } | Select-Object -Unique)
            source_indices = [int[]]@($sourceItems | ForEach-Object { [int]$_.position } | Select-Object -Unique)
            fill_reason = $reason
            allowed_generic_copy = [string[]]$generic
            variant_conflict = $highConflict
            preserve_existing_content = $true
            localization_mode = 'taiwan_traditional_commerce'
            semantic_check = 'no_local_ocr_no_fake_semantic_certainty'
            text_shield_required = $shield
            runtime_reference_strategy = $(if ($shield) { 'conflict_text_shield_proxy' } else { 'original_source' })
            visual_proxy_center_dominance = $(if ($sourceItems.Count -gt 0) { [double](Get-V4A1Property $sourceItems[0] 'center_dominance' 0.0) } else { 0.0 })
            visual_proxy_product_focus = $(if ($sourceItems.Count -gt 0) { [double](Get-V4A1Property $sourceItems[0] 'product_focus_proxy' 0.0) } else { 0.0 })
        }
    }

    $plan = [pscustomobject]@{
        version = 'V4-B'
        product_id = $productId
        created_at = (Get-Date).ToString('o')
        original_count = $candidates.Count
        output_count = 5
        high_variant_conflict = $highConflict
        quantity_conflict = $quantityConflict
        strategy = 'edit_preserve_localize_fill_to_five'
        no_ocr_claim = $true
        slots = [object[]]$slotPlans
    }

    if (-not [string]::IsNullOrWhiteSpace($productId)) { $script:V4BSourcePlanCache[$productId] = $plan }
    try {
        $firstPath = [string]$candidates[0].path
        if (-not [string]::IsNullOrWhiteSpace($firstPath)) {
            $folder = Split-Path $firstPath -Parent
            $plan | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $folder 'source_plan_v4b.json') -Encoding UTF8
        }
    }
    catch {}
    return $plan
}

function Get-V4BPlanSlot($Plan, [string]$Slot) {
    if ($null -eq $Plan) { return $null }
    $match = @($Plan.slots | Where-Object { [string]$_.slot -eq $Slot } | Select-Object -First 1)
    if ($match.Count -eq 0) { return $null }
    return $match[0]
}

function Get-V4BCurrentSourcePlan {
    try {
        $product = Get-V4A2ResolvedProduct $null
        $productId = [string](Get-V4A1Property $product 'product_id' '')
        if ($productId -and $script:V4BSourcePlanCache.ContainsKey($productId)) { return $script:V4BSourcePlanCache[$productId] }
    }
    catch {}
    return $null
}

function Analyze-ProductImagesV2([string]$ProductId, [string[]]$Paths) {
    $analysis = & $script:V4BAnalyzeBase $ProductId $Paths
    $product = Get-V4A2ResolvedProduct $null
    $plan = New-V4BSourceImagePlan $product $analysis
    Add-Member -InputObject $analysis -NotePropertyName 'v4b_source_plan' -NotePropertyValue $plan -Force
    return $analysis
}

function Get-V4BReferenceRisk($Analysis, [string]$Path) {
    foreach ($item in @(Get-V4A1Property $Analysis 'reference_safety' @())) {
        if ([string](Get-V4A1Property $item 'path' '') -eq $Path) { return [double](Get-V4A1Property $item 'local_risk_score' 0.50) }
    }
    return 0.50
}

function Get-ReferencesForSlotV2($Analysis, [string]$Slot, [int]$Maximum) {
    try {
        $productId = [string](Get-V4A1Property $Analysis 'product_id' '')
        $product = Get-V4A2ResolvedProduct $null
        $plan = $null
        if ($productId -and $script:V4BSourcePlanCache.ContainsKey($productId)) { $plan = $script:V4BSourcePlanCache[$productId] }
        if ($null -eq $plan) { $plan = New-V4BSourceImagePlan $product $Analysis }
        $slotPlan = Get-V4BPlanSlot $plan $Slot
        if ($null -eq $slotPlan) { throw 'V4-B：找不到 slot source plan。' }
        $limit = [Math]::Min(2, [Math]::Max(1,$Maximum))
        $paths = @($slotPlan.source_paths | ForEach-Object { [string]$_ } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First $limit)
        if ($paths.Count -gt 0) {
            if ([bool](Get-V4A1Property $slotPlan 'text_shield_required' $false)) {
                $shielded = @()
                foreach ($path in $paths) {
                    $risk = Get-V4BReferenceRisk $Analysis $path
                    $proxy = New-V4A2ReferenceProxy $productId $path $risk $true
                    if ($shielded -notcontains $proxy) { $shielded += $proxy }
                }
                if ($shielded.Count -gt 0) { return [string[]]$shielded }
            }
            return [string[]]$paths
        }
    }
    catch {}
    return [string[]]@(& $script:V4BReferenceSelectorBase $Analysis $Slot $Maximum)
}
