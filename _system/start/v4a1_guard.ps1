$ErrorActionPreference = 'Stop'

$corePath = Join-Path $PSScriptRoot 'v4a1_guard_core.ps1'
if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) { throw '缺少 v4a1_guard_core.ps1' }
. $corePath

$visualPath = Join-Path $PSScriptRoot 'v4a1_visual_truth.ps1'
if (Test-Path -LiteralPath $visualPath -PathType Leaf) { . $visualPath }

$referenceSafetyPath = Join-Path $PSScriptRoot 'v4a2_reference_safety.ps1'
if (Test-Path -LiteralPath $referenceSafetyPath -PathType Leaf) { . $referenceSafetyPath }

$referenceHardeningPath = Join-Path $PSScriptRoot 'v4a2_reference_hardening.ps1'
if (Test-Path -LiteralPath $referenceHardeningPath -PathType Leaf) { . $referenceHardeningPath }

$referenceHardeningR2Path = Join-Path $PSScriptRoot 'v4a2_reference_hardening_r2.ps1'
if (Test-Path -LiteralPath $referenceHardeningR2Path -PathType Leaf) { . $referenceHardeningR2Path }

$taiwanLocalizationPath = Join-Path $PSScriptRoot 'v4a2_taiwan_localization.ps1'
if (Test-Path -LiteralPath $taiwanLocalizationPath -PathType Leaf) { . $taiwanLocalizationPath }

$textStabilityPath = Join-Path $PSScriptRoot 'v4a21_text_stability.ps1'
if (Test-Path -LiteralPath $textStabilityPath -PathType Leaf) { . $textStabilityPath }

# V4-A.3 is intentionally loaded after factual/reference/Taiwan/text-stability layers.
# It may plan references/layouts and perform set-level retries, but may not weaken those prior safeguards.
foreach ($v4a3File in @('reference_classifier_v3.ps1','five_image_planner_v3.ps1','layout_memory_v3.ps1','group_validation_v3.ps1')) {
    $v4a3Path = Join-Path $PSScriptRoot $v4a3File
    if (-not (Test-Path -LiteralPath $v4a3Path -PathType Leaf)) { throw ('缺少 V4-A.3 模組：' + $v4a3File) }
    if ($v4a3File -eq 'group_validation_v3.ps1' -and $null -eq (Get-Command Start-SingleProductOptimizationV2 -ErrorAction SilentlyContinue)) {
        continue
    }
    . $v4a3Path
}

$menuUxPath = Join-Path $PSScriptRoot 'v4a2_menu_ux.ps1'
if (Test-Path -LiteralPath $menuUxPath -PathType Leaf) { . $menuUxPath }
