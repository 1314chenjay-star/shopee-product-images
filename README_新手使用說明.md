# 蝦皮商品圖片優化工具 V2｜新手版

本版本把 **一件** 蝦皮商品從媒體資訊 Excel 處理成 1 張主圖、4 張詳情圖及 ZIP。使用 Windows 內建 PowerShell，不用安裝 Python，也不會修改原始 Excel。

## 開始前

1. 將整個工具解壓縮到一般資料夾，不要直接在 ZIP 裡執行。
2. 如果使用 `release_windows` 交付資料夾，雙擊最外層的 `START.bat`；如果使用專案原始碼，雙擊 `start.bat`。工具會切換 UTF-8，PowerShell 腳本也使用 Windows PowerShell 5.1 可辨識的 UTF-8 BOM，避免繁體中文亂碼。
3. 主選單選 **1**，貼上 TinySnow Key。預設 Base URL 是 `https://tinysnow.one/v1`，模型是 `gpt-image-2`。
4. 選 **2** 測試連線。金鑰只存於被 Git 忽略的 `config/config.json`；畫面及日誌只顯示遮罩。

## 從 Excel 到 ZIP

1. 選 **3 匯入蝦皮 Excel**，選擇後台下載的 `.xlsx`。工具直接讀取 XLSX 內部資料，不依賴 Excel、Python 或 openpyxl，也不讀取容易出問題的 `activePane` 設定。
2. 選 **4 選擇一件商品**。可輸入商品ID，或輸入 `L` 顯示清單再輸入編號。畫面會顯示商品名稱、圖片數、主圖與詳情圖數，輸入大寫 `Y` 才會鎖定。
3. 選 **5 開始優化**，再輸入大寫 `START`。工具下載原圖、分析可開啟性/尺寸/畫質/重複，然後逐張生成 `main → detail1 → detail2 → detail3 → detail4`。
4. 選 **6** 查看斷點進度。若中途關機，再選 5 時只會接續未完成圖片，不重做狀態為 `done` 且仍可開啟的檔案。
5. 全部完成會自動打包；也可選 **8** 手動重建 ZIP。

> 生圖會使用 TinySnow 額度。每次開始前一定要輸入 `START`；預設安全模式一次只處理目前鎖定的一件商品，固定最多 5 張、`medium`、`1024x1024`，完成後停止，不會自動跑下一件。

## 固定輸出

```text
workspace/
  raw_images/商品ID/          # 原始下載圖及 analysis.json
  checkpoints/商品ID/checkpoint.json
  final_images/商品ID/
    商品ID_main.jpg
    商品ID_detail1.jpg
    商品ID_detail2.jpg
    商品ID_detail3.jpg
    商品ID_detail4.jpg
  商品ID_圖片優化完成.zip
reports/商品ID_report.txt
logs/
```

ZIP 只包含上述 5 張 JPG，不包含 Key、設定、日誌、報告或原始圖片。商品ID只能是 5～30 位數字，且所有路徑都會重新驗證，避免 A 商品寫入 B 商品資料夾。

## 圖片與內容保護

- 圖生圖使用 TinySnow `/images/edits` 的 `multipart/form-data`，所有參考圖欄位均為 `image[]`；每次最多參考 4 張，可在進階設定調低。
- 原主圖優先。其餘圖片會檢查尺寸、畫素、1:1 接近度及 SHA256 重複，不是機械式取前 4 張。分析紀錄保存在 `analysis.json`。
- 六種提示詞模板位於 `config/prompt_templates.json`，共同禁止捏造尺寸、材質、功能、品牌、型號、配件、認證、保固、產地、效果或促銷。
- 圖中文字要求台灣自然繁體中文，禁止「爆款、神器、包郵、全網最低」及無證據宣稱。無法確認的資訊採保守處理。
- 每張回傳後立即 Base64 解碼、驗證可開啟性、尺寸、比例、0KB 及完全重複，再轉存 JPG；檢查失敗不會標記完成。

## 斷點、下載與錯誤

- 原圖已存在且可開啟時不重複下載；單張失敗重試 3 次，記錄失敗 URL，但不會因一張失敗而使其他下載崩潰。
- 生圖遇到 HTTP 429、5xx、暫時網路錯誤時最多嘗試 3 次，等待 15 秒、30 秒後再試，不會無限扣費。
- `checkpoint.json` 記錄五張圖的 `pending / generating / done / failed / blocked` 狀態、失敗重試數、最後錯誤及更新時間。
- 每次執行更新 `reports/商品ID_report.txt`；詳細錯誤在 `logs/errors.log`。完整 Key 不會進入日誌、報告或 ZIP。

## 主選單

1. 設定 TinySnow API
2. 測試 TinySnow API
3. 匯入蝦皮 Excel
4. 選擇一件商品
5. 開始優化這件商品
6. 查看處理進度
7. 打開成品資料夾
8. 打包 ZIP
9. 進階設定（參考圖上限）
0. 離開

## 已知限制

- 本階段只允許單商品，不做 100 件批次、網址回填、SEO、類目或其他平台功能。
- 工具可做技術性圖片分析；商品規格是否在不同圖片中語意衝突，仍需要賣家人工判斷。若已知原圖有衝突，請不要按 `START`。
- API 測試使用 OpenAI 相容的 `GET /models`。如果 TinySnow 日後停用此端點，可直接以單張生圖驗證，但會消耗額度。
- TinySnow 實際可用尺寸、品質與模型權限取決於帳戶方案。

## Windows Release 資料夾結構

`release_windows` 最外層只有新手需要看到的兩個檔案及一個系統資料夾：

```text
START.bat
README_新手使用說明.txt
_system/                       # 程式、設定、日誌與成品都在這裡
```

請保留 `_system`，不要只移動 `START.bat`。交付資料夾不包含 `config.json`，因此不可能夾帶開發者的 API Key；第一次啟動後才會在本機建立設定。

如要做完全不呼叫生圖 API 的本機檢查，可在 PowerShell 執行 `_system\tools\自我檢查.ps1`。它只匯入程式模組並檢查設定、端點、商品ID、模板及保留變數，不會連線 TinySnow，也不會產生費用。

## 常見錯誤

- **401 / 403**：Key、帳務或模型權限問題。
- **404**：Base URL 錯誤；請填到 `/v1`，不要填完整圖片接口。
- **400**：模型或請求參數不受支援。
- **429 / 5xx**：工具會有限重試；仍失敗會保存斷點。
- **Excel 找不到欄位**：需要「商品ID、商品名稱、主商品圖片」，及「商品圖片1～8」等蝦皮欄名。
