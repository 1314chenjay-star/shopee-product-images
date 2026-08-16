$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$startDir = Join-Path $repoRoot '_system\start'

. (Join-Path $startDir 'coupang_local_collector.ps1')
. (Join-Path $startDir 'coupang_existing_session.ps1')
. (Join-Path $startDir 'coupang_v13_hardening.ps1')

function Assert-EqualV14($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "ASSERT FAILED: $Message | expected=[$Expected] actual=[$Actual]"
    }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

function Assert-TrueV14([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "ASSERT FAILED: $Message" }
    Write-Host "PASS: $Message" -ForegroundColor Green
}

Write-Host '=== TinySnow Coupang V1.4 self-test ===' -ForegroundColor Cyan

$expectedUrl = 'https://wing.coupang.com/tenants/sfl-portal/delivery/management'
Assert-TrueV14 ([bool](Get-Command Get-CoupangStartUrlV4 -ErrorAction SilentlyContinue)) 'direct backend URL function is loaded'
Assert-EqualV14 $expectedUrl (Get-CoupangStartUrlV4) 'default URL is the saved Coupang delivery management backend'

$hardeningText = Get-Content -LiteralPath (Join-Path $startDir 'coupang_v13_hardening.ps1') -Raw -Encoding UTF8
Assert-TrueV14 ($hardeningText -match [regex]::Escape($expectedUrl)) 'direct backend URL is embedded in runtime startup layer'
Assert-TrueV14 ($hardeningText -match 'Start-CoupangImportedProfileV2') 'existing-session startup override remains present'
Assert-TrueV14 ($hardeningText -match 'Start-CoupangBrowserV1') 'fresh-browser startup override remains present'

$menuText = Get-Content -LiteralPath (Join-Path $startDir 'coupang_only.ps1') -Raw -Encoding UTF8
Assert-TrueV14 ($menuText -match 'V1\.4') 'menu reports V1.4'
Assert-TrueV14 ($menuText -match '預設入口：配送管理後台') 'menu tells user the direct backend entry behavior'

$launcherText = Get-Content -LiteralPath (Join-Path $repoRoot 'START.bat') -Raw -Encoding UTF8
Assert-TrueV14 ($launcherText -match 'V1\.4') 'START.bat reports V1.4'

Write-Host '=== ALL COUPANG V1.4 SELF-TESTS PASSED ===' -ForegroundColor Green
