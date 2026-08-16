TinySnow Coupang 現有瀏覽器橋接版 V1.5

目的：
直接工作在你目前已登入 Coupang 的 Chrome / Edge Profile 裡，不再複製 Cookie 或密碼。

安裝（只做一次）：
1. 解壓 ZIP 一次。
2. 保持你平常已登入 Coupang 的 Chrome / Edge Profile 開著。
3. Chrome 輸入 chrome://extensions/；Edge 輸入 edge://extensions/。
4. 開啟「開發人員模式」。
5. 點「載入未封裝項目 / Load unpacked」。
6. 選擇解壓後的 coupang_browser_extension 資料夾。
7. 把 TinySnow Coupang 擴充功能固定在瀏覽器工具列。

使用：
1. 在「原本就已登入 Coupang」的同一個瀏覽器 Profile 裡點 TinySnow 圖示。
2. 點「切到已登入的 WING 分頁」；若尚未開後台，點「直接進配送管理後台」。
3. 點「開始採集後台資料」。
4. 點「重新整理並抓取 API」。
5. 在 WING 正常瀏覽商品、訂單、庫存、退貨、數據分析頁面。TinySnow 會記錄頁面與讀取型 API 回應。
6. 完成後點「停止採集」→「匯出採集資料 JSON」。
7. 把輸出的 JSON 傳給 ChatGPT。

固定後台入口：
https://wing.coupang.com/tenants/sfl-portal/delivery/management

安全：
- 不複製你的瀏覽器 Profile。
- 不讀取或匯出 Cookie。
- 不匯出密碼、Authorization、Access Token、Refresh Token。
- 買家電話、Email、地址等分析不必要的個資會遮蔽。
- 不修改 Coupang Open API，也不影響易客物流串接。

注意：
Chrome/Edge 會在使用 chrome.debugger 時顯示「此瀏覽器正在被偵錯」之類的提示，這是擴充功能讀取目前 WING 分頁網路回應時的正常安全提示。
