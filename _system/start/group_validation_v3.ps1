$ErrorActionPreference = 'Stop'

$script:V4A3StartOptimizationBase = (Get-Command Start-SingleProductOptimizationV2 -ErrorAction Stop).ScriptBlock

function Get-V4A3GroupSimilarityThreshold {
    return 0.88
}

function Get-V4A3SlotOrder([string]$Slot) {
    switch ($Slot) {
        'main' { return 0 }
        'detail1' { return 1 }
        'detail2' { return 2 }
        'detail3' { return 3 }
        'detail4' { return 4 }
        default { return 99 }
    }
}

function Add-V4A3FailureReason($ReasonMap, [string]$Slot, [string]$Reason) {
    if (-not $ReasonMap.ContainsKey($Slot)) { $ReasonMap[$Slot] = @() }
    $ReasonMap[$Slot] = @($ReasonMap[$Slot]) + $Reason
}

function Test-FiveImageGroupV4A3([string]$ProductId, [string]$OutputFolder, $Plan) {
    $slots = @('main','detail1','detail2','detail3','detail4')
    $failed = @()
    $reasons = @{}
    $warnings = @('本地整組驗收不使用 OCR，因此不宣稱能逐字判斷成品內文案；文字真實性仍由既有 exact-text allowlist 與人工看圖確認。')
    $paths = @{}

    foreach ($slot in $slots) {
        $path = Join-Path $OutputFolder ($ProductId + '_' + $slot + '.jpg')
        if (Test-Path -LiteralPath $path -PathType Leaf) { $paths[$slot] = $path }
        else {
            $failed += $slot
            Add-V4A3FailureReason $reasons $slot '缺少成品圖片。'
        }
    }

    # Actual image-level duplicate/layout check. Fail the later slot only, never both.
    for ($i = 0; $i -lt $slots.Count; $i++) {
        $firstSlot = $slots[$i]
        if (-not $paths.ContainsKey($firstSlot)) { continue }
        for ($j = $i + 1; $j -lt $slots.Count; $j++) {
            $secondSlot = $slots[$j]
            if (-not $paths.ContainsKey($secondSlot)) { continue }
            try {
                $similarity = Get-LayoutSimilarityV2 ([string]$paths[$firstSlot]) ([string]$paths[$secondSlot])
                if ($similarity -ge (Get-V4A3GroupSimilarityThreshold)) {
                    $failed += $secondSlot
                    Add-V4A3FailureReason $reasons $secondSlot ("與 {0} 整體版型相似度 {1:P1} 過高。" -f $firstSlot,$similarity)
                }
            }
            catch { $warnings += ('無法比較 ' + $firstSlot + '/' + $secondSlot + '：' + $_.Exception.Message) }
        }
    }

    if ($null -ne $Plan) {
        $slotPlans = @($Plan.slots)
        $families = @{}
        foreach ($slotPlan in $slotPlans) {
            $slot = [string]$slotPlan.slot
            $family = [string]$slotPlan.preferred_layout_family
            if (-not [string]::IsNullOrWhiteSpace($family)) {
                if ($families.ContainsKey($family)) {
                    $failed += $slot
                    Add-V4A3FailureReason $reasons $slot ('規劃層重複使用版型家族：' + $family)
                }
                else { $families[$family] = $slot }
            }
        }

        # Reusing a primary reference is acceptable when safety/high-conflict forces it.
        # Otherwise, 3+ uses of one source indicates unnecessary set-level repetition.
        if (-not [bool](Get-V4A1Property $Plan 'high_variant_conflict' $false) -and [int](Get-V4A1Property $Plan 'analyzed_reference_count' 0) -gt 2) {
            $groups = @{}
            foreach ($slotPlan in $slotPlans) {
                $source = [string](Get-V4A1Property $slotPlan 'primary_reference_source' '')
                if ([string]::IsNullOrWhiteSpace($source)) { continue }
                if (-not $groups.ContainsKey($source)) { $groups[$source] = @() }
                $groups[$source] = @($groups[$source]) + [string]$slotPlan.slot
            }
            foreach ($source in @($groups.Keys)) {
                $usingSlots = @($groups[$source])
                if ($usingSlots.Count -ge 3) {
                    $ordered = @($usingSlots | Sort-Object { Get-V4A3SlotOrder ([string]$_) })
                    foreach ($slot in @($ordered | Select-Object -Skip 2)) {
                        $failed += [string]$slot
                        Add-V4A3FailureReason $reasons ([string]$slot) '同一 primary reference 在五圖中被不必要地重複使用 3 次以上。'
                    }
                }
            }
        }
    }

    $failed = @($failed | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique | Sort-Object { Get-V4A3SlotOrder ([string]$_) })
    $reasonObjects = @()
    foreach ($slot in $failed) {
        $reasonObjects += [pscustomobject]@{ slot=[string]$slot; reasons=[string[]]@($reasons[[string]$slot]) }
    }

    return [pscustomobject]@{
        passed = ($failed.Count -eq 0)
        failed_slots = [string[]]$failed
        reasons_by_slot = [object[]]$reasonObjects
        group_warnings = [string[]]@($warnings | Select-Object -Unique)
        retry_priority = [string[]]@($failed | Select-Object -First 2)
        similarity_threshold = (Get-V4A3GroupSimilarityThreshold)
    }
}

function Save-V4A3GroupValidation([string]$ProductId, $Validation) {
    try {
        $dir = Join-Path (Get-V2Workspace) ('checkpoints\' + $ProductId)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $payload = [pscustomobject]@{
            version = 'V4-A.3'
            product_id = $ProductId
            validated_at = (Get-Date).ToString('o')
            validation = $Validation
        }
        $payload | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $dir 'group_validation_v4a3.json') -Encoding UTF8
    }
    catch {}
}

function Set-V4A3SlotsForRetry([string]$ProductId, [string[]]$Slots, [string]$Reason) {
    $checkpoint = Get-CheckpointV2 $ProductId
    foreach ($slot in @($Slots | Select-Object -Unique)) {
        if (@('main','detail1','detail2','detail3','detail4') -notcontains [string]$slot) { continue }
        $checkpoint.states.$slot.status = 'pending'
        $checkpoint.states.$slot.last_error = $Reason
    }
    $checkpoint.finalization_complete = $false
    $checkpoint.current_status = '整組驗收需局部重生'
    $checkpoint.last_log = ('V4-A.3 只重生：' + (@($Slots) -join '、'))
    Save-CheckpointV2 $checkpoint
}

function Mark-V4A3ValidationFailure([string]$ProductId, [string[]]$Slots) {
    $checkpoint = Get-CheckpointV2 $ProductId
    foreach ($slot in @($Slots | Select-Object -Unique)) {
        if (@('main','detail1','detail2','detail3','detail4') -notcontains [string]$slot) { continue }
        $checkpoint.states.$slot.status = 'failed'
        $checkpoint.states.$slot.last_error = 'V4-A.3 整組五圖驗收仍未通過。'
    }
    $checkpoint.finalization_complete = $false
    $checkpoint.current_status = '整組驗收未通過'
    $checkpoint.last_log = ('請只重做失敗 slot：' + (@($Slots) -join '、'))
    Save-CheckpointV2 $checkpoint
}

function Start-SingleProductOptimizationV2($Config) {
    $first = & $script:V4A3StartOptimizationBase $Config
    $productId = [string]$first.product_id
    if (-not [bool]$first.complete) {
        return [pscustomobject]@{
            product_id=$productId; generated_this_run=[int]$first.generated_this_run; complete=$false;
            output_folder=[string]$first.output_folder; failed_urls=@($first.failed_urls); group_validation='skipped_generation_incomplete'; group_retry_slots=@()
        }
    }

    $plan = Get-V4A3CurrentPlan
    Save-V4A3LayoutMemoryFromPlan $plan
    $validation = Test-FiveImageGroupV4A3 $productId ([string]$first.output_folder) $plan
    Save-V4A3GroupValidation $productId $validation
    if ([bool]$validation.passed) {
        return [pscustomobject]@{
            product_id=$productId; generated_this_run=[int]$first.generated_this_run; complete=$true;
            output_folder=[string]$first.output_folder; failed_urls=@($first.failed_urls); group_validation=$validation; group_retry_slots=@()
        }
    }

    $retrySlots = [string[]]@($validation.retry_priority)
    if ($retrySlots.Count -eq 0) {
        Mark-V4A3ValidationFailure $productId ([string[]]$validation.failed_slots)
        return [pscustomobject]@{
            product_id=$productId; generated_this_run=[int]$first.generated_this_run; complete=$false;
            output_folder=[string]$first.output_folder; failed_urls=@($first.failed_urls); group_validation=$validation; group_retry_slots=@()
        }
    }

    # One focused group retry only. The base pipeline skips every slot still marked done,
    # so API quota is spent solely on the failed slots selected above.
    Set-V4A3SlotsForRetry $productId $retrySlots 'V4-A.3 整組驗收：版型／reference 重複，僅局部重生。'
    Write-Host ('V4-A.3 整組驗收：只重生 ' + ($retrySlots -join '、')) -ForegroundColor Yellow
    $second = & $script:V4A3StartOptimizationBase $Config
    $secondPlan = Get-V4A3CurrentPlan
    Save-V4A3LayoutMemoryFromPlan $secondPlan

    $secondValidation = $null
    if ([bool]$second.complete) {
        $secondValidation = Test-FiveImageGroupV4A3 $productId ([string]$second.output_folder) $secondPlan
        Save-V4A3GroupValidation $productId $secondValidation
        if (-not [bool]$secondValidation.passed) { Mark-V4A3ValidationFailure $productId ([string[]]$secondValidation.failed_slots) }
    }

    $finalComplete = ([bool]$second.complete -and $null -ne $secondValidation -and [bool]$secondValidation.passed)
    return [pscustomobject]@{
        product_id = $productId
        generated_this_run = ([int]$first.generated_this_run + [int]$second.generated_this_run)
        complete = $finalComplete
        output_folder = [string]$second.output_folder
        failed_urls = @($first.failed_urls + $second.failed_urls | Select-Object -Unique)
        group_validation = $secondValidation
        group_retry_slots = [string[]]$retrySlots
    }
}
