$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$root = Split-Path $PSScriptRoot -Parent
$host.UI.RawUI.WindowTitle = '蝦皮商品圖片優化工具 V2'

Import-Module (Join-Path $root 'core\TinySnow.psm1') -Force -DisableNameChecking
. (Join-Path $PSScriptRoot 'excel_reader.ps1')
. (Join-Path $PSScriptRoot 'selection_v2.ps1')
. (Join-Path $PSScriptRoot 'image_pipeline_v2.ps1')

function Pause-Menu {
    Write-Host ''
    Read-Host '按 Enter 回主選單' | Out-Null
}

function Open-Folder([string]$Path) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    Start-Process explorer.exe $Path
}

function Show-Selected {
    try {
        $product = Get-SelectedProduct
        Write-Host "目前商品：$($product.product_id)｜$($product.product_name)" -ForegroundColor Cyan
    }
    catch {
        Write-Host '目前商品：尚未選擇' -ForegroundColor Yellow
    }
}

while ($true) {
    $config = Get-TinySnowConfig
    Clear-Host
    Write-Host '=================================' -ForegroundColor Cyan
    Write-Host '蝦皮商品圖片優化工具 V2'
    Write-Host 'SAFE TEST MODE｜一次一件、最多5張' -ForegroundColor Green
    Write-Host '=================================' -ForegroundColor Cyan
    Show-Selected
    Write-Host ''
    Write-Host '1. 設定 TinySnow API'
    Write-Host '2. 測試 TinySnow API'
    Write-Host '3. 匯入蝦皮 Excel'
    Write-Host '4. 選擇商品（只輸入左側編號）'
    Write-Host '5. 下載並檢查原圖（不花 API 額度）'
    Write-Host '6. 開始優化目前商品（會花 API 額度）'
    Write-Host '7. 查看處理進度'
    Write-Host '8. 打開成品資料夾'
    Write-Host '9. 打包 ZIP'
    Write-Host '0. 離開'
    Write-Host '================================='

    $choice = Read-Host '請輸入編號'

    try {
        switch ($choice) {
            '1' {
                $key = Read-Host '貼上 API Key（儲存後只顯示遮罩）'
                if ($key) { $config.api_key = $key.Trim() }
                $base = Read-Host "Base URL（Enter 保留 $($config.base_url)）"
                if ($base) { $config.base_url = $base.TrimEnd('/') }
                $model = Read-Host "模型（Enter 保留 $($config.model)）"
                if ($model) { $config.model = $model }
                Save-TinySnowConfig $config
                Write-Host "已儲存：$(Mask-ApiKey $config.api_key)" -ForegroundColor Green
                Pause-Menu
            }

            '2' {
                $result = Test-TinySnowApi $config
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
                    Save-TinySnowConfig $config
                    Write-Host "匯入成功，共讀到 $($products.Count) 件商品；原始 Excel 完全未修改。" -ForegroundColor Green
                }
                Pause-Menu
            }

            '4' {
                $catalog = Get-Catalog
                $items = @($catalog.products)
                if ($items.Count -eq 0) { throw '商品清單是空的，請先重新匯入 Excel。' }

                Write-Host ''
                Write-Host '直接輸入左邊的數字即可：' -ForegroundColor Cyan
                for ($index = 0; $index -lt $items.Count; $index++) {
                    Write-Host ("{0}. [{1}] {2}" -f ($index + 1), [string]$items[$index].product_id, [string]$items[$index].product_name)
                }

                $numberText = Read-Host '請輸入商品編號'
                if ($numberText -notmatch '^\d+$') { throw '請只輸入左邊的數字，例如 1、2、3。' }
                $number = [int]$numberText
                if ($number -lt 1 -or $number -gt $items.Count) { throw '商品編號超出清單範圍。' }

                $selectedId = [string]$items[$number - 1].product_id
                $product = Select-ShopeeProduct $selectedId
                $config.selected_product_id = [string]$product.product_id
                Save-TinySnowConfig $config

                Write-Host ''
                Write-Host '已選擇商品：' -ForegroundColor Green
                Write-Host "商品ID：$($product.product_id)"
                Write-Host "商品名稱：$($product.product_name)"
                Write-Host "原始圖片數：$(@($product.image_urls).Count)"
                Write-Host '下一步請回主選單按 5，先下載並檢查原圖。' -ForegroundColor Cyan
                Pause-Menu
            }

            '5' {
                $product = Get-SelectedProduct
                Write-Host "正在檢查：$($product.product_id)｜$($product.product_name)" -ForegroundColor Cyan
                Write-Host '這一步不會呼叫生圖 API。'
                $result = Test-SelectedProductImagesV2
                Write-Host ''
                Write-Host "可用原圖：$(@($result.downloaded).Count) 張" -ForegroundColor Green
                Write-Host "下載失敗：$(@($result.failed_urls).Count) 張"
                Write-Host "檢查資料夾：$($result.folder)"
                Write-Host '已建立 analysis_summary.txt，可查看每張圖尺寸與重複狀態。' -ForegroundColor Cyan
                Write-Host '若這一步正常，再選 6 開始正式生圖。' -ForegroundColor Yellow
                Pause-Menu
            }

            '6' {
                $product = Get-SelectedProduct
                Write-Host "即將生成：$($product.product_id)｜$($product.product_name)" -ForegroundColor Cyan
                $confirm = Read-Host '會消耗 TinySnow 額度。輸入 START 開始生成 1 主圖 + 4 詳情圖'
                if ($confirm -eq 'START') {
                    $result = Start-SingleProductOptimizationV2 $config
                    Write-Host "本次實際生成：$($result.generated_this_run) 張" -ForegroundColor Cyan
                    if ($result.complete) {
                        Write-Host "5張皆完成。ZIP：$($result.zip)" -ForegroundColor Green
                    }
                    else {
                        Write-Host '尚未完成，已保存斷點；修正問題後可再次執行 6 續跑。' -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host '已取消，未呼叫生圖 API。'
                }
                Pause-Menu
            }

            '7' {
                $product = Get-SelectedProduct
                $checkpoint = Get-CheckpointV2 ([string]$product.product_id)
                Write-Host "商品ID：$($product.product_id)"
                foreach ($slot in @('main','detail1','detail2','detail3','detail4')) {
                    $state = $checkpoint.states.$slot
                    Write-Host ("{0}: {1}（重試累計 {2}）" -f $slot, $state.status, $state.retries)
                }
                Pause-Menu
            }

            '8' {
                Open-Folder (Join-Path $root 'workspace\final_images')
            }

            '9' {
                $product = Get-SelectedProduct
                $zip = New-ProductZipV2 ([string]$product.product_id)
                Write-Host "ZIP 已建立：$zip" -ForegroundColor Green
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
        Write-TinySnowLog '主選單' '' "選項=$choice" $false $_.Exception.Message
        Pause-Menu
    }
}
