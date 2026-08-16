TinySnow Coupang 現有瀏覽器橋接版 V1.6

目的：
直接工作在你目前已登入 Coupang 的 Chrome / Edge 裡，不複製 Cookie 或密碼；改成一鍵自動巡航 WING 主要營運頁面，不需要你逐頁點擊。

安裝（只做一次）：
1. 解壓 ZIP 一次。
2. 保持你平常已登入 Coupang 的 Chrome / Edge Profile 開著。
3. Chrome 輸入 chrome://extensions/；Edge 輸入 edge://extensions/。
4. 開啟「開發人員模式」。
5. 點「載入未封裝項目 / Load unpacked」。
6. 選擇解壓後的 coupang_browser_extension 資料夾。
7. 把 TinySnow Coupang 擴充功能固定在瀏覽器工具列。

V1.6 使用方式：
1. 在原本已登入 Coupang 的同一個瀏覽器 Profile 裡打開 WING。
2. 點 TinySnow 圖示。
3. 點「2. 一鍵自動採集全店主要數據」。
4. 之後不要手動逐頁操作，讓 WING 分頁保持開啟即可。
5. TinySnow 會依序嘗試：
   - 商品管理 → 商品列表
   - 訂購/配送 → 我的訂單
   - 退貨/退款/取消
   - 結算
   - 賣家成長
   - 商業洞察
6. 每一站會自動等待頁面載入、抓 API、保存頁面快照。某一頁找不到時會記錄原因並繼續下一頁。
7. 狀態顯示「自動巡航：已完成」後，點「4. 匯出採集資料 JSON」。
8. 把輸出的 JSON 傳給 ChatGPT。

固定後台入口：
https://wing.coupang.com/tenants/sfl-portal/delivery/management

安全：
- 不複製你的瀏覽器 Profile。
- 不讀取或匯出 Cookie。
- 不匯出密碼、Authorization、Access Token、Refresh Token。
- 結構化 API 資料中的買家電話、Email、地址等分析不必要個資會遮蔽。
- 不修改 Coupang Open API，也不影響易客物流串接。

重要說明：
V1.6 的目標是先自動建立你真實 WING 的頁面與 API 端點地圖，不再需要你手動逐頁點擊。第一份真實 JSON 確認各頁 API、分頁參數與資料結構後，下一階段才會把商品、訂單等「所有分頁／歷史區間」做成真正的全量自動抓取，避免在不知道你帳號實際接口的情況下猜測參數。

Chrome/Edge 會在使用 chrome.debugger 時顯示「此瀏覽器正在被偵錯」之類的提示，這是擴充功能讀取目前 WING 分頁網路回應時的正常安全提示。
