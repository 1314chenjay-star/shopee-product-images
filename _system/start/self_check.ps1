$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$runtimeFiles = @(
    'api_v2.ps1',
    'excel_reader.ps1',
    'selection_v2.ps1',
    'image_pipeline_v2.ps1',
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
        foreach ($err in $parseErrors) {
            Write-Host ('  Line ' + $err.Extent.StartLineNumber + ': ' + $err.Message) -ForegroundColor Red
        }
        $failed = $true
    }
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
    foreach ($check in $forbiddenChecks) {
        if ($content -match $check.Pattern) {
            Write-Host ('[FAIL] ' + $name + '：' + $check.Label) -ForegroundColor Red
            $failed = $true
        }
    }
}

if ($failed) {
    Write-Host ''
    Write-Host '啟動前自我檢查未通過。為避免反覆報錯，工具已停止。' -ForegroundColor Red
    exit 1
}

Write-Host '啟動前自我檢查：通過。' -ForegroundColor Green
exit 0
