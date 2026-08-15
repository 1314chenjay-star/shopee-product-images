# CODEX TASK — V4-B｜原圖保真台灣化五圖優化版

## 0. 任務定位

這是一個新的開發方向。不要把 V4-B 做成「AI 自由重新設計 5 張商品圖」。

V4-B 的核心是：

**原商品圖 → 保真分析/選圖 → 台灣繁體與台灣賣家用語優化 → 原圖保真編修 → 不足 5 張時從既有內容安全重組補圖 → 固定輸出 5 張。**

原圖是主要視覺與事實來源；AI 是輔助優化工具，不是自由創作工具。

---

## 1. Repository / Branch / Baseline

Repository:

`1314chenjay-star/shopee-product-images`

Target branch:

`v4b-original-image-localization`

V4-B 起始基線：

`075ece972f8185f501236a1d1e30a440f95e470b`

該基線已通過 V4-A.3 Windows CI 與 focused TinySnow live regression。

`V2_BUILD.txt` 起始內容應確認：

- Build: `V4-A.3｜Five-Image Planner 五圖整體規劃版`
- Transport: `API-R3-120S`
- Windows PowerShell 5.1 compatible

`_system/start/api_v2.ps1` transport 不得修改。

官方 API-R3-120S package SHA-256 lock：

`a27d8107b94c7e5d29aa5e170aea1541f7e95cc6cde6a693556d1d0b0b8bdf0f`

Git blob 起始值應保持：

`9e81a9c4a0769d5e41b4c1e7dba4b92266c49187`

### Codex workspace 分支名稱規則

Codex 本地工作分支可以叫 `work`；不要只因本地 branch name 是 `work` 就停止。

真正必須確認的是：

1. HEAD 必須等於上述 baseline，或是該 baseline / `v4b-original-image-localization` 的合法 descendant。
2. repository 必須正確。
3. `V2_BUILD.txt` 與 `API-R3-120S` 必須正確。
4. `api_v2.ps1` fingerprint 必須正確。
5. workspace 必須乾淨，或只有本任務自己產生的已知變更。

如果 HEAD 不在正確 ancestry、Build/Transport/fingerprint 不符，才 STOP。

開始修改前必須執行並記錄：

- `git rev-parse HEAD`
- `git branch --show-current`
- `git status --short --branch`
- `cat V2_BUILD.txt`
- `sha256sum _system/start/api_v2.ps1`
- `git merge-base --is-ancestor 075ece972f8185f501236a1d1e30a440f95e470b HEAD`

---

## 2. 最高產品原則

### 2.1 原圖保真優先

每張成品必須以現有原圖為基礎。

允許：

- 簡體 → 台灣繁體
- 大陸電商用語 → 台灣賣家自然用語
- 文字重新排版
- 版面整理
- 1:1 電商圖片適配
- 清晰度/背景/留白/資訊層級優化
- 從現有原圖中裁切、拆分、重組已存在的內容
- 合理保留原圖已有的規格、尺寸、功能、配件、使用方式、款式資訊

禁止：

- 自行創造新的商品外觀
- 自行增加新人物 / 新手拿商品 / 新使用場景
- 自行增加原圖沒有的商品零件
- 自行增加功能、材質、尺寸、數量、配件、贈品、型號、認證、保固、醫療/安全/性能承諾
- 為了畫面好看而改變商品本體、配色、結構或內容物

### 2.2 原圖不是「只拿來參考外觀」

V4-A 以前偏向把原圖文字視為高風險全部隔離。V4-B 要改成：

**原圖中原本有價值的資訊，要盡量保留與台灣化，而不是全部刪掉。**

例如原圖已有：

- 尺寸圖
- 規格圖
- 功能說明
- 配件/套組內容
- 使用方式
- 款式差異
- 結構細節

如果內容可可靠保留，應優先做翻譯/本土化/排版優化。

但若本地 runtime 無法可靠確認文字內容，不得假裝 OCR/語意理解成功。必須採用可追溯的來源與保守策略；資訊無法確認時寧可保留原圖視覺、少改文字，也不能猜。

### 2.3 Excel / 商品名 / variants 是輔助資料

結構化 Shopee 資料可用來：

- 驗證規格
- 驗證多色/多尺寸/多數量
- 驗證 model / SKU / accessory / common facts
- 判斷 variant 衝突

但不能單靠商品標題中的行銷詞新增圖中不存在的功能或材質。

---

## 3. 固定輸出 5 張

V4-B 最終必須固定輸出：

- `商品ID_main.jpg`
- `商品ID_detail1.jpg`
- `商品ID_detail2.jpg`
- `商品ID_detail3.jpg`
- `商品ID_detail4.jpg`

### 3.1 原圖 > 5 張

從現有原圖中挑選最有價值的 5 個內容來源。

建議優先級：

1. 商品主視覺
2. 尺寸/規格
3. 商品細節/結構
4. 使用方式/情境（僅原圖已有）
5. 配件/包裝/款式/補充資訊

不要為了 layout diversity 犧牲更重要的真實資訊。

### 3.2 原圖 = 5 張

原則上一張對一張保真優化，保持每張原本的資訊角色。

### 3.3 原圖 < 5 張

**必須自動補足到 5 張。**

但補圖不是自由生成。

補圖順序必須是：

#### 第一優先：從既有原圖內容安全重組

例如：

- 一張綜合圖中已有尺寸 + 細節，可拆成兩張重新排版
- 多張原圖已有商品不同角度，可整理成「商品細節展示」
- 原圖已有配件內容，可單獨做配件整理圖
- 原圖已有規格/款式資訊，可做選購整理圖
- 原圖已有使用步驟，可重新排版成使用方式圖

重組不能增加不存在的事實。

#### 第二優先：使用安全白名單通用文字 + 現有商品視覺

只有現有內容確實不足時才能使用。

不得為湊第 5 張而創造新功能/新材質/新場景。

---

## 4. 台灣在地化要求

這一版不是只有「簡轉繁」。

必須建立可維護的台灣電商 localization layer，處理：

- 商品標題片語
- 規格名稱
- 尺寸名稱
- 圖片標題
- 使用說明
- 配件/內容物名稱
- 單位
- 大陸電商常用詞

### 4.1 常見轉換示例

- `2米` → `2公尺`；規格卡需要時可顯示 `200公分`
- `厘米 / cm` → `公分`
- `毫米 / mm` → `公釐`
- `英寸 / inch` → `吋`
- `尺码` → `尺寸`
- `颜色分类` → `顏色` / `款式`
- `产品参数` → `規格資訊`
- `产品展示` → `商品展示`
- `细节展示` → `細節展示`
- `使用说明` → `使用方式`
- `适用人群` → `適用對象`
- `下单` → `下單`
- `发货` → `出貨`
- `赠品` → `贈品`
- `材质` → `材質`
- `可拆卸` → `可拆式`
- `组合套装` → `組合內容` / `套組內容`
- `购买须知` → `選購須知`
- `联系客服` → `聯絡客服`
- `双肩包` → `後背包`
- `斜挎包` → `斜背包`
- `羽毛球` → `羽球`
- `乒乓球` → `桌球`

### 4.2 Localization 安全規則

- Brand / model / SKU 不得翻譯或改寫。
- 數值事實不得因本土化改義。
- 不確定是否同義的詞不要強改。
- 單位轉換可換顯示方式，但不得改數值含義。
- 不要使用中國大陸電商浮誇詞或批發語氣。
- 生成文字要像台灣蝦皮賣家自然會使用的短文案，而不是機翻繁中。

### 4.3 建議新增/擴充設定檔

優先擴充成獨立、可維護 JSON/PS module，例如：

- `_system/config/taiwan_terms_v4b.json`
- `_system/config/v4b_safe_generic_copy.json`
- `_system/start/v4b_localization.ps1`

不要把大量 mapping 散落硬寫在多個 runtime 檔案。

---

## 5. 補圖安全白名單

當原內容不足、需要補到 5 張時，只有安全低風險文字可使用。

### 5.1 無條件低風險候選

可依版面選擇使用：

- 商品展示
- 商品細節
- 細節展示
- 使用方式參考
- 選購前請確認規格
- 實際規格請依商品選項為準
- 商品外觀請以實際收到商品為準
- 圖片僅供商品資訊整理參考
- 不同規格內容可能略有差異

### 5.2 條件式白名單

只有結構化資料真正支持才可使用：

- `多色可選` → 必須確認 has_multiple_colors
- `多尺寸可選` → 必須確認 has_multiple_sizes
- `多款式可選` / `多規格可選` → 必須確認 multiple variants
- `數量規格可選` → 必須確認 multiple quantities
- `尺寸資訊請參考圖示` → 必須真的有可靠尺寸資訊來源

白名單表示「可以使用」，不是「必須使用」。

### 5.3 禁止拿白名單當功能文案產生器

以下不是通用白名單，不得無來源加入：

- 防滑
- 防水
- 防汗
- 透氣
- 親膚
- 耐磨
- 彈力
- 加厚
- 減震
- 支撐
- 穩定
- 矯正
- 保護關節
- 提升表現
- 專業級
- 安全無毒

只有原圖/可靠結構化資料明確支持時才能保留。

---

## 6. V4-B 圖片角色規劃

仍固定輸出 5 張，但角色是「整理/保留」，不是「自由新創」。

### main

- 選現有最適合主圖的商品視覺
- 保留商品本體
- 只做台灣化、排版、背景/清晰度/1:1 優化
- 不增加人物或新情境

### detail1

- 優先保留現有重點/細節資訊
- 可以把原圖已有的多個細節重新排成台灣電商版面

### detail2

- 優先結構 / 配件 / 內容物 / 局部細節
- 只能使用既有內容
- 不得自行命名未知零件

### detail3

- 原圖已有使用方式/場景：保留並優化
- 原圖沒有：不要自己生人物場景；改由既有內容做另一種資訊整理圖

### detail4

- 優先尺寸 / 規格 / 款式 / 型號 / 選購補充
- 沒有可靠規格時使用安全補充文案，不填假數字

角色可根據原圖資訊互換優先順序；重點是 5 張資訊互補，不是硬湊模板。

---

## 7. 建議架構

不要大改 API transport。優先在上層新增 V4-B 模組。

建議：

- `_system/start/v4b_source_image_planner.ps1`
  - 決定每個 output slot 對應哪個原始來源/重組來源
- `_system/start/v4b_original_image_guard.ps1`
  - 強制「編修原圖，不自由創作」prompt hardening
- `_system/start/v4b_localization.ps1`
  - 台灣化文字處理
- `_system/start/v4b_fill_to_five.ps1`
  - 不足 5 張的安全重組補圖策略
- `_system/start/v4b_output_validator.ps1`
  - 驗證 5 張、來源追蹤、補圖理由、禁止事實
- `_system/config/taiwan_terms_v4b.json`
- `_system/config/v4b_safe_generic_copy.json`

可重用 V4-A.1 / V4-A.2 / V4-A.2.1 的：

- verified facts
- multi-variant guard
- Taiwan unit conversion
- exact-text safety concepts
- API-R3 transport

可重用 V4-A.3 的：

- 5 slot output/checkpoint
- group-level orchestration
- source reference metadata

但必須移除/壓低 V4-A.3 中會鼓勵「重新發明視覺」的規則，例如：

- 為了五張差異而強迫新人物/新情境
- 為了 layout diversity 換掉更真實的原圖來源
- 強制每個 slot 一種自由設計 layout family

**Safety / truth / source preservation > diversity。**

---

## 8. Source Provenance 必須可追蹤

每個 output slot 建議保存：

- output_slot
- source_mode: `single_original` / `recomposed_originals` / `generic_fill`
- source_original_paths
- source_original_indices
- retained_fact_sources
- localization_changes
- generic_copy_used
- fill_reason
- variant_conflict_status

目的是未來發現亂生成時可以知道是哪一張原圖、哪個補圖策略造成。

---

## 9. 不得假裝 OCR/vision 能力

目前本地 Windows runtime 沒有可靠完整 OCR/semantic vision。

所以：

- 不得在報告中宣稱「已完整讀取圖片文字」除非真的有可靠來源。
- deterministic visual proxies 只能當圖像選擇輔助，不能當文字事實來源。
- 如果 TinySnow/模型在 edit prompt 中能看見原圖，prompt 應要求保留已存在內容並轉繁體，但後驗程式不得假裝已 OCR 驗證每一個字。
- 有結構化 Shopee variant facts 可驗證時，才可用它強化文字真實性。

---

## 10. TinySnow 編修 prompt 原則

V4-B prompt 必須從「generate a new ecommerce image」改成偏「edit / preserve / localize」。

核心指令應包含：

- 以提供的原圖為主要畫面基礎
- 保留商品本體、配色、比例、結構、配件與原本可見資訊
- 不新增原圖不存在的商品元素
- 將可處理的簡體/大陸電商說法改為自然台灣繁體
- 只整理版面，不擴寫功能
- 看不清楚的規格不要猜
- generic_fill 也必須使用現有商品視覺，禁止從零發明另一張商品照片

---

## 11. 測試策略：先不花 API

必須 incremental testing。

### Phase 1 — Static / Windows smoke

先驗證：

1. loader 正確載入 V4-B final layer
2. `api_v2.ps1` byte identity / package SHA lock 不變
3. 11-digit product ID 仍為 string
4. selection 仍保留完整 structured variants / verified facts
5. >5 / =5 / <5 原圖 planning 都能產生 5 slots
6. <5 時 fill plan 優先 reuse/recompose originals
7. generic white copy 有 condition guard
8. 台灣 localization mappings 正確
9. 多 variant 特有尺寸/顏色/數量不得升格成共同事實
10. production modules 不得 hardcode fixture product IDs

### Phase 2 — No-API planner inspection

至少建立 synthetic fixtures：

- 8 張原圖 → 選 5 張
- 5 張原圖 → 1:1 對應
- 3 張原圖 → 安全補到 5 張
- 1 張原圖 → 允許重組同一真實視覺 + generic safe copy 補滿，但不能自由造新場景

### Phase 3 — 最小 TinySnow live

不要全量跑。

#### Regression A — `58015741169`

驗證：

- 保留共同真實資訊：`2公尺`, `30磅`, `腰帶`, `黑色`
- 不得出現 `2米`
- 不得把 `5組` / 五人 / 五套升格成共同事實
- 不得新增尼龍、橡膠、金屬等材質
- 不得新增未知零件名稱
- 圖片應看起來是原圖優化，不是全新發明商品場景

#### Regression B — `52915734564`

驗證：

- 不把 10/20/40 片或不同顏色寫成共同規格
- 不新增防汗防水、親膚、護膝功效等
- 以原圖視覺為主，不再為 layout diversity 自行發明手拿/人物場景

#### Regression C — 原圖少於 5 張 fixture

挑一件真實商品（不要 hardcode production logic），驗證：

- 最終固定 5 張
- 補出的圖能指出來源
- 優先由原有內容拆分/重組
- 真的不足時才使用 safe generic copy
- 沒有虛構功能/材質/尺寸/配件

每次只生最少必要的 slot。若修改只影響 fill_to_five，不要重跑 580 全套。

---

## 12. Windows / PowerShell safeguards

全部延續：

- Windows PowerShell 5.1 compatible
- executable `.ps1` UTF-8 BOM
- `START.bat` 先跑 encoding fix + self check
- 11-digit product ID 永遠 `[string]`
- avoid `$PID`
- StrictMode response property guard
- 不增加 Python runtime dependency
- API key 不顯示、不 commit
- Shopee Excel header dynamic scan / fallback 保持

---

## 13. Build / UI

完成後 Build 應升級為：

`V4-B｜原圖保真台灣化五圖優化版`

Transport 必須仍顯示：

`API-R3-120S`

Beginner menu 不需要變複雜。使用者仍應能：

1. 設 API
2. 測 API
3. 匯入 Excel
4. 選商品
5. 原圖檢查（不花 API）
6. 開始優化（花 API）
7. 看進度
8. 開成品資料夾

第 5 步的 analysis/report 應新增 V4-B source plan 摘要，清楚顯示：

- 原圖幾張
- 採用哪些來源
- 哪些 slot 是 direct original edit
- 哪些 slot 是 recompose
- 哪些 slot 是 generic fill

---

## 14. 完成條件

V4-B 只有同時滿足以下條件才算 candidate：

1. 核心模式已從「自由重生成」改成「原圖保真編修」。
2. 圖片中的既有有價值資訊會被優先保留，而不是全部隔離刪掉。
3. 簡體與大陸電商詞會被盡量轉成自然台灣賣家用語。
4. 不足 5 張能固定補到 5 張。
5. 補圖優先重組原內容；不足才使用條件式白名單。
6. 不虛構功能、材質、尺寸、數量、配件、贈品、認證、功效。
7. multi-variant 安全不退步。
8. API-R3 transport 完全不變。
9. Windows CI 全綠。
10. minimum focused TinySnow live gate 通過。
11. 不 merge stable/canonical branch。
12. 不建立與任務無關的 PR。

---

## 15. 最終回報

完成後請回報：

1. HEAD SHA
2. branch / workspace context
3. `V2_BUILD.txt`
4. 修改檔案列表
5. V4-B 新模組與設定檔
6. 原圖保真流程摘要
7. 台灣 localization 規則摘要
8. fill-to-five 規則摘要
9. source provenance 設計
10. static / Windows CI 結果
11. TinySnow live 使用幾張、測了哪些 slot、結果
12. `api_v2.ps1` Git blob + SHA-256 / package lock
13. `git status --short --branch`
14. 是否建立 PR
15. 是否 merge（必須是 NO）

不要產生 final release package 來宣稱正式版，除非 Windows CI + focused TinySnow live 已通過。即使通過，也只能標記 candidate，等使用者 Windows 實機確認後才能考慮 merge/promote。
