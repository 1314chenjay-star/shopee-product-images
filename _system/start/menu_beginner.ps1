$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$host.UI.RawUI.WindowTitle = '蝦皮商品圖片優化工具 V2 | V4-A.1 | API-R3-120S'

. (Join-Path $PSScriptRoot 'api_v2.ps1')
. (Join-Path $PSScriptRoot 'excel_reader.ps1')
. (Join-Path $PSScriptRoot 'selection_v2.ps1')
. (Join-Path $PSScriptRoot 'image_pipeline_v2.ps1')
. (Join-Path $PSScriptRoot 'v4a1_guard.ps1')
. (Join-Path $PSScriptRoot 'v4a1_visual_truth.ps1')

function Pause-Menu {
    Write-Host ''
    Read-Host '按 Enter 回主選單' | Out-Null
}

function Open-FolderV2([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Start-Process explorer.exe $Path
}

function Show-SelectedV2 {
    try {
        $product = Get-SelectedProductV2
        Write-Host ("目前商品：{0}｜{1}" -f $product.product_id, $product.product_name) -ForegroundColor Cyan
    }
    catch {
        Write-Host '目前商品：尚未選擇' -ForegroundColor Yellow
    }
}

while ($true) {
    $config = Get-TinySnowConfigV2
    Clear-Host
    Write-Host '=================================' -ForegroundColor Cyan
    Write-Host '蝦皮商品圖片優化工具 V2'
    Write-Host 'Build: V4-A.1｜真實資料＋視覺數量鎖定版' -ForegroundColor Yellow
    Write-Host 'Transport: API-R3-120S' -ForegroundColor Yellow
    Write-Host 'SAFE TEST MODE｜一次一件、最多5張｜每次最多2張壓縮參考圖' -ForegroundColor Green
    Write-Host '=================================' -ForegroundColor Cyan
    Show-SelectedV2
    Write-Host ''
    Write-Host '1. 設定 TinySnow API'
    Write-Host '2. 測試 TinySnow API'
    Write-Host '3. 匯入蝦皮 Excel'
    Write-Host '4. 選擇商品（只輸入左側編號）'
    Write-Host '5. 下載並檢查原圖（不花 API 額度）'
    Write-Host '6. 開始優化目前商品（會花 API 額度）'
    Write-Host '7. 查看處理進度'
    Write-Host '8. 打開「已生成圖片」資料夾'
    Write-Host '9. 進階設定'
    Write-Host '0. 離開'
    Write-Host '================================='

    $choice = Read-Host '請輸入編號'

    try {
        switch ($choice) {
            '1' {
                $key = Read-Host '貼上 API Key（儲存後只顯示遮罩）'
                if ($key) { $config.api_key = $key.Trim() }
                $base = Read-Host ("Base URL（Enter 保留 {0}）" -f $config.base_url)
                if ($base) { $config.base_url = $base.TrimEnd('/') }
                $model = Read-Host ("模型（Enter 保留 {0}）" -f $config.model)
                if ($model) { $config.model = $model }
                Save-TinySnowConfigV2 $config
                Write-Host ("已儲存：{0}" -f (Mask-ApiKeyV2 ([string]$config.api_key))) -ForegroundColor Green
                Pause-Menu
            }

            '2' {
                $result = Test-TinySnowApiV2 $config
                if ($result.Success) { Write-Host $result.Message -ForegroundColor Green }
                else { Write-Host $result.Message -ForegroundColor Red }
                Pause-Menu
            }

            '3' {
                Add-Type -AssemblyName System.Windows.Forms
                $dialog = New-Object Windows.Forms.OpenFileDialog
                $dialog.Title = '選擇蝦皮媒體資訊 Excel'
                $dialog.Filter = 'Excel 活頁簿 (*.xlsx)|*.xlsx'
                if ($dialog.ShowDialog() -eq 'OK') {
                    $products = @(Save-ImportedCatalogV2 $dialog.FileName)
                    $config.imported_excel = $dialog.FileName
                    Save-TinySnowConfigV2 $config
                    Write-Host ("匯入成功，共讀到 {0} 件商品；原始 Excel 完全未修改。" -f $products.Count) -ForegroundColor Green
                }
                Pause-Menu
            }

            '4' {
                $catalog = Get-CatalogV2
                $items = @($catalog.products)
                if ($items.Count -eq 0) { throw '商品清單是空的，請先重新匯入 Excel。' }

                Write-Host ''
                Write-Host '直接輸入左邊的商品編號：' -ForegroundColor Cyan
                for ($index = 0; $index -lt $items.Count; $index++) {
                    Write-Host ("{0}. [{1}] {2}" -f ($index + 1), [string]$items[$index].product_id, [string]$items[$index].product_name)
                }

                $numberText = Read-Host '請輸入商品編號'
                if ($numberText -notmatch '^\d+$') { throw '請只輸入左邊的數字編號，例如 1、2、3。' }
                $number = [int]$numberText
                if ($number -lt 1 -or $number -gt $items.Count) { throw '商品編號超出清單範圍。' }

                $selectedId = [string]$items[$number - 1].product_id
                $product = Select-ShopeeProductV2 $selectedId
                $config.selected_product_id = [string]$product.product_id
                Save-TinySnowConfigV2 $config

                Write-Host ''
                Write-Host ("已選擇：{0}. [{1}] {2}" -f $number, $product.product_id, $product.product_name) -ForegroundColor Green
                Write-Host '下一步按 5，先檢查原圖；不會產生生圖費用。' -ForegroundColor Cyan
                Pause-Menu
            }

            '5' {
                $result = Test-SelectedProductImagesV2
                Write-Host ''
                Write-Host ("原圖檢查完成：{0} 張可用" -f @($result.downloaded).Count) -ForegroundColor Green
                Write-Host ("下載失敗：{0} 張" -f @($result.failed_urls).Count)
                Write-Host ("檢查結果資料夾：{0}" -f $result.folder)
                Write-Host '已建立 analysis_summary.txt，可先查看再決定是否生圖。' -ForegroundColor Cyan
                Pause-Menu
            }

            '6' {
                $product = Get-SelectedProductV2
                Write-Host ("即將處理：{0}｜{1}" -f $product.product_id, $product.product_name) -ForegroundColor Cyan
                $confirm = Read-Host '會依序生成1張主圖＋4張詳情圖並消耗額度。輸入 1 開始'
                if ($confirm -eq '1') {
                    $result = Start-SingleProductOptimizationV2 $config
                    Write-Host ("本次實際生成：{0} 張" -f $result.generated_this_run) -ForegroundColor Cyan
                    if ($result.complete) { Write-Host ("5張皆完成。成品資料夾：{0}" -f $result.output_folder) -ForegroundColor Green }
                    else { Write-Host '尚未完成，已保存斷點；再次執行可續跑。' -ForegroundColor Yellow }
                }
                else {
                    Write-Host '已取消，未呼叫生圖 API。'
                }
                Pause-Menu
            }

            '7' {
                $product = Get-SelectedProductV2
                $progress = Get-ProgressSummaryV2 $product
                $checkpoint = $progress.checkpoint
                Write-Host ("商品 ID：{0}" -f [string]$product.product_id)
                Write-Host ("商品名稱：{0}" -f [string]$product.product_name)
                Write-Host ("目前狀態：{0}" -f [string]$checkpoint.current_status) -ForegroundColor Cyan
                Write-Host ("總進度：{0}/6{1}" -f $progress.completed_steps, $(if ($progress.completed_steps -eq 6) { '（完成）' } else { '' }))
                Write-Host ("已生成圖片：{0} 張" -f $progress.generated)
                Write-Host ("失敗圖片：{0} 張" -f $progress.failed)
                Write-Host ("最後更新時間：{0}" -f ([datetime]$checkpoint.updated_at).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
                Write-Host ("最後日誌：{0}" -f [string]$checkpoint.last_log)
                Pause-Menu
            }

            '8' { Open-FolderV2 (Get-GeneratedImagesDirectoryV2) }

            '9' {
                $newMaximum = Read-Host ("每張成品最多使用幾張參考圖？目前 {0}，請輸入 1 或 2（Enter 保留）" -f $config.max_reference_images)
                if ($newMaximum) {
                    if ($newMaximum -notmatch '^[1-2]$') { throw '120秒超時防護版請輸入 1 或 2。' }
                    $config.max_reference_images = [int]$newMaximum
                    Save-TinySnowConfigV2 $config
                    Write-Host '進階設定已儲存。' -ForegroundColor Green
                }
                Pause-Menu
            }

            '0' { return }

            default {
                Write-Host '沒有這個選項。' -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
        }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
        try { Write-TinySnowLogV2 '主選單' '' ("選項={0}" -f $choice) $false $_.Exception.Message } catch {}
        Pause-Menu
    }
}
