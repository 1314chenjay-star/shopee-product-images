$ErrorActionPreference = 'Stop'

function Get-V4BAllowedSourceModes {
    return [string[]]@('single_original','recomposed_originals','generic_fill')
}

function Test-V4BSourcePlan($Plan, [bool]$RequireFiles) {
    $errors = @()
    $failedSlots = @()
    if ($null -eq $Plan) {
        return [pscustomobject]@{ passed=$false; errors=[string[]]@('缺少 V4-B source plan。'); failed_slots=(Get-V4BSlotNames) }
    }
    $slots = @($Plan.slots)
    if ($slots.Count -ne 5) { $errors += ('必須固定五個 slot，目前為 ' + $slots.Count) }
    $expected = Get-V4BSlotNames
    $actualNames = @($slots | ForEach-Object { [string]$_.slot })
    foreach ($name in $expected) {
        if ($actualNames -notcontains $name) { $errors += ('缺少 slot：' + $name); $failedSlots += $name }
    }
    if (@($actualNames | Select-Object -Unique).Count -ne $actualNames.Count) { $errors += 'slot 名稱重複。' }

    $allowedModes = Get-V4BAllowedSourceModes
    $allGeneric = @(Get-V4BAllSafeGenericCopy)
    foreach ($slotPlan in $slots) {
        $slot = [string](Get-V4A1Property $slotPlan 'slot' '')
        $mode = [string](Get-V4A1Property $slotPlan 'source_mode' '')
        if ($allowedModes -notcontains $mode) {
            $errors += ($slot + ' source_mode 不合法：' + $mode)
            $failedSlots += $slot
        }
        $paths = @($slotPlan.source_paths | ForEach-Object { [string]$_ } | Where-Object { $_ })
        if ($paths.Count -lt 1 -or $paths.Count -gt 2) {
            $errors += ($slot + ' 來源圖必須為 1～2 張。')
            $failedSlots += $slot
        }
        if ($mode -eq 'single_original' -or $mode -eq 'generic_fill') {
            if ($paths.Count -ne 1) { $errors += ($slot + ' 的 ' + $mode + ' 必須只使用一張真實來源圖。'); $failedSlots += $slot }
        }
        if ($mode -eq 'recomposed_originals' -and $paths.Count -lt 1) {
            $errors += ($slot + ' recomposed_originals 缺少來源圖。')
            $failedSlots += $slot
        }
        if ($RequireFiles) {
            foreach ($path in $paths) {
                if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $errors += ($slot + ' 找不到來源圖：' + $path); $failedSlots += $slot }
            }
        }
        foreach ($copy in @($slotPlan.allowed_generic_copy)) {
            $localized = Convert-ToTaiwanCommerceTextV4B ([string]$copy)
            if ($allGeneric -notcontains $localized) {
                $errors += ($slot + ' 使用非白名單通用文案：' + $localized)
                $failedSlots += $slot
            }
        }
        if (-not [bool](Get-V4A1Property $slotPlan 'preserve_existing_content' $false)) {
            $errors += ($slot + ' 未標記 preserve_existing_content。')
            $failedSlots += $slot
        }
    }
    $failedSlots = [string[]]@($failedSlots | Where-Object { $_ } | Select-Object -Unique)
    return [pscustomobject]@{
        passed = ($errors.Count -eq 0)
        errors = [string[]]$errors
        failed_slots = $failedSlots
    }
}

# Disable V4-A.3's visual-novelty retry gate in V4-B. Similarity is not a failure when both
# outputs faithfully preserve their assigned original sources.
function Test-LayoutDiversityV2([string]$CandidatePath, [string[]]$ExistingPaths) {
    return [pscustomobject]@{
        high_similarity = $false
        similarity = 0.0
        compared_path = ''
        policy = 'V4-B source fidelity supersedes layout novelty'
    }
}

# V4-A.3's existing optimization wrapper calls this function by name at runtime. Replacing it
# lets V4-B keep the checkpoint/retry plumbing while validating provenance instead of layout novelty.
function Test-FiveImageGroupV4A3([string]$ProductId, [string]$OutputFolder, $IgnoredPlan) {
    $plan = Get-V4BCurrentSourcePlan
    $sourceValidation = Test-V4BSourcePlan $plan $true
    $failed = @($sourceValidation.failed_slots)
    $reasons = @()
    foreach ($message in @($sourceValidation.errors)) { $reasons += [pscustomobject]@{ slot='source_plan'; reasons=[string[]]@([string]$message) } }

    foreach ($slot in Get-V4BSlotNames) {
        $path = Join-Path $OutputFolder ($ProductId + '_' + $slot + '.jpg')
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $failed += $slot
            $reasons += [pscustomobject]@{ slot=$slot; reasons=[string[]]@('缺少成品圖片。') }
        }
    }
    $failed = [string[]]@($failed | Where-Object { $_ -and $_ -ne 'source_plan' } | Select-Object -Unique)
    return [pscustomobject]@{
        passed = ([bool]$sourceValidation.passed -and $failed.Count -eq 0)
        failed_slots = $failed
        reasons_by_slot = [object[]]$reasons
        group_warnings = [string[]]@('V4-B 不以版型相似度判定失敗；只驗證五圖完整性、真實來源追蹤、來源模式與安全白名單。','本地流程不使用 OCR，不宣稱能逐字驗證成品文字。')
        retry_priority = [string[]]@($failed | Select-Object -First 2)
        similarity_threshold = 'disabled_in_v4b'
        source_validation = $sourceValidation
    }
}

function Save-V4A3GroupValidation([string]$ProductId, $Validation) {
    try {
        $dir = Join-Path (Get-V2Workspace) ('checkpoints\' + $ProductId)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [pscustomobject]@{
            version = 'V4-B'
            product_id = $ProductId
            validated_at = (Get-Date).ToString('o')
            policy = 'source_fidelity_not_layout_novelty'
            validation = $Validation
        } | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath (Join-Path $dir 'source_validation_v4b.json') -Encoding UTF8
    }
    catch {}
}
