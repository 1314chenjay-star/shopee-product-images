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

# V4-A.3 remains loaded for backwards-compatible analysis/checkpoint plumbing.
foreach ($v4a3File in @('reference_classifier_v3.ps1','five_image_planner_v3.ps1','layout_memory_v3.ps1','group_validation_v3.ps1')) {
    $v4a3Path = Join-Path $PSScriptRoot $v4a3File
    if (-not (Test-Path -LiteralPath $v4a3Path -PathType Leaf)) { throw ('缺少 V4-A.3 模組：' + $v4a3File) }
    if ($v4a3File -eq 'group_validation_v3.ps1' -and $null -eq (Get-Command Start-SingleProductOptimizationV2 -ErrorAction SilentlyContinue)) {
        continue
    }
    . $v4a3Path
}

# V4-B is the final runtime layer. It intentionally supersedes V4-A.3's novelty-first planner:
# source fidelity, Taiwan localization, safe fill-to-five, and deterministic verified overlays are primary.
foreach ($v4bFile in @('v4b_localization.ps1','v4b_fill_to_five.ps1','v4b_source_image_planner.ps1','v4b_original_image_guard.ps1','v4b_verified_overlay.ps1','v4b_output_validator.ps1')) {
    $v4bPath = Join-Path $PSScriptRoot $v4bFile
    if (-not (Test-Path -LiteralPath $v4bPath -PathType Leaf)) { throw ('缺少 V4-B 模組：' + $v4bFile) }
    . $v4bPath
}

$menuUxPath = Join-Path $PSScriptRoot 'v4a2_menu_ux.ps1'
if (Test-Path -LiteralPath $menuUxPath -PathType Leaf) { . $menuUxPath }
