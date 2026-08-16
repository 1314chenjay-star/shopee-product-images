$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$host.UI.RawUI.WindowTitle = 'TinySnow Coupang 數據採集工具 V1.4'

. (Join-Path $PSScriptRoot 'coupang_local_collector.ps1')
. (Join-Path $PSScriptRoot 'coupang_existing_session.ps1')
. (Join-Path $PSScriptRoot 'coupang_v13_hardening.ps1')

while ($true) {
    Clear-Host
    Write-Host '=================================' -ForegroundColor Cyan
    Write-Host 'TinySnow｜Coupang 數據採集工具 V1.4'
    Write-Host '純酷澎版｜不修改 Open API｜不保存帳號密碼' -ForegroundColor Green
    Write-Host '預設入口：配送管理後台' -ForegroundColor Cyan
    Write-Host '=================================' -ForegroundColor Cyan
    Write-Host '1. 使用目前 Edge/Chrome 已登入狀態（推薦）'
    Write-Host '2. 開啟已複製的 Coupang 登入狀態'
    Write-Host '3. 重新登入專用瀏覽器（備用）'
    Write-Host '4. 採集目前已開啟的 Coupang 頁面'
    Write-Host '5. 打包最新採集資料（ZIP）'
    Write-Host '6. 打開 Coupang 本地資料夾'
    Write-Host '0. 離開'
    Write-Host '================================='

    $choice = Read-Host '請輸入編號'
    try {
        switch ($choice) {
            '1' {
                Import-AndStart-CoupangExistingSessionV2
                Write-Host ''
                Read-Host '完成後按 Enter' | Out-Null
            }
            '2' {
                Start-CoupangImportedProfileV2
                Write-Host ''
                Read-Host '完成後按 Enter' | Out-Null
            }
            '3' {
                Start-CoupangBrowserV1
                Write-Host ''
                Read-Host '完成後按 Enter' | Out-Null
            }
            '4' {
                Save-CoupangSnapshotsV1 | Out-Null
                Write-Host ''
                Write-Host '採集完成。商品、訂單、庫存、營運頁面開得越完整，第一次取樣越有價值。' -ForegroundColor Cyan
                Read-Host '按 Enter' | Out-Null
            }
            '5' {
                Export-CoupangCaptureBundleV1 | Out-Null
                Write-Host ''
                Read-Host '按 Enter' | Out-Null
            }
            '6' { Open-CoupangWorkspaceV1 }
            '0' { return }
            default {
                Write-Host '沒有這個選項。' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
    catch {
        Write-Host ''
        Write-Host $_.Exception.Message -ForegroundColor Red
        Write-Host ''
        Read-Host '按 Enter' | Out-Null
    }
}
