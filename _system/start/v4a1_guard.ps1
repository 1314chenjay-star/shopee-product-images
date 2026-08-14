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
