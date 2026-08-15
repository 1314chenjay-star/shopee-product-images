$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$runtimeFiles = @(
    'api_v2.ps1',
    'excel_reader.ps1',
    'selection_v2.ps1',
    'image_pipeline_v2.ps1',
    'v4a1_guard.ps1',
    'v4a1_guard_core.ps1',
    'v4a1_visual_truth.ps1',
    'v4a2_reference_safety.ps1',
    'v4a2_reference_hardening.ps1',
    'v4a2_reference_hardening_r2.ps1',
    'v4a2_taiwan_localization.ps1',
    'v4a21_text_stability.ps1',
    'reference_classifier_v3.ps1',
    'five_image_planner_v3.ps1',
    'layout_memory_v3.ps1',
    'group_validation_v3.ps1',
    'v4b_localization.ps1',
    'v4b_fill_to_five.ps1',
    'v4b_source_image_planner.ps1',
    'v4b_original_image_guard.ps1',
    'v4b_verified_overlay.ps1',
    'v4b_output_validator.ps1',
    'v4a2_menu_ux.ps1',
    'menu_beginner.ps1'
)

$failed = $false
foreach ($name in $runtimeFiles) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host ('[FAIL] 缺少檔案：' + $name) -ForegroundColor Red
        $failed = $true
        continue
    }

    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) {
        Write-Host ('[FAIL] PowerShell 語法錯誤：' + $name) -ForegroundColor Red
        foreach ($err in $parseErrors) { Write-Host ('  Line ' + $err.Extent.StartLineNumber + ': ' + $err.Message) -ForegroundColor Red }
        $failed = $true
    }
}

$configRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'config'
$configFiles = @('factual_rules_v4a1.json','taiwan_terms_v4a2.json','taiwan_terms_v4b.json','v4b_safe_generic_copy.json')
foreach ($configName in $configFiles) {
    $configPath = Join-Path $configRoot $configName
    if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        Write-Host ('[FAIL] 缺少 ' + $configName) -ForegroundColor Red
        $failed = $true
        continue
    }
    try {
        $configText = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8
        $configText | ConvertFrom-Json | Out-Null
        if ($configText.Contains([char]0xFFFD)) { throw '包含 U+FFFD replacement character' }
    }
    catch { Write-Host ('[FAIL] ' + $configName + '：' + $_.Exception.Message) -ForegroundColor Red; $failed = $true }
}

$forbiddenChecks = @(
    @{ Pattern='Import-Module.+ShopeeWorkflow'; Label='仍載入舊 ShopeeWorkflow 模組' },
    @{ Pattern='Import-Module.+TinySnow\.psm1'; Label='仍載入舊 TinySnow 模組' },
    @{ Pattern='\breturn\['; Label='存在 return[... 缺空格風險' },
    @{ Pattern='\breturn\$'; Label='存在 return$... 缺空格風險' },
    @{ Pattern='Collections\.Generic\.List'; Label='仍使用 Generic.List，相容性風險' }
)

foreach ($name in $runtimeFiles) {
    $path = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $path)) { continue }
    $content = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    if ($content.Contains([char]0xFFFD)) { Write-Host ('[FAIL] ' + $name + '：包含 U+FFFD replacement character') -ForegroundColor Red; $failed = $true }
    foreach ($check in $forbiddenChecks) {
        if ($content -match $check.Pattern) { Write-Host ('[FAIL] ' + $name + '：' + $check.Label) -ForegroundColor Red; $failed = $true }
    }
}

if ($failed) {
    Write-Host ''
    Write-Host '啟動前自我檢查未通過。為避免反覆報錯，工具已停止。' -ForegroundColor Red
    exit 1
}

Write-Host '啟動前自我檢查：通過。' -ForegroundColor Green
exit 0
