TinySnow Coupang 現有瀏覽器橋接版 V1.7

目的：
直接工作在你目前已登入 Coupang 的 Chrome / Edge 裡，不複製 Cookie 或密碼。

V1.7 主要改進：
1. 不再只靠模擬點左側選單文字，會優先從 WING 頁面自動尋找真實 href / 路由。
2. 商品列表成功進入後，自動嘗試切到每頁 50 件。
3. 自動按「下一頁」持續採集，最多保護上限 500 頁。
4. 每一頁商品資料立即獨立保存，中途停止也不會丟掉前面已抓到的頁面。
5. 狀態視窗會顯示商品頁數、已抓商品筆數、預期總數與是否完整。
6. 不再把「嘗試 6 個頁面」誤顯示成「6/6 全部成功」；有失敗會顯示完成但有錯誤。

安裝 / 更新：
1. ZIP 只解壓一次。
2. Chrome 輸入 chrome://extensions/；Edge 輸入 edge://extensions/。
3. 開啟「開發人員模式」。
4. 如果舊版 TinySnow 已載入，可以先移除舊版，再點「載入未封裝項目」。
5. 選擇解壓後的 coupang_browser_extension 資料夾。
6. 把 TinySnow Coupang 擴充功能固定在瀏覽器工具列。

使用：
1. 保持你平常已登入 Coupang 的 WING 分頁開著。
2. 點 TinySnow 圖示。
3. 點「2. 一鍵全店採集（商品自動翻到最後一頁）」。
4. 採集期間不要關閉 WING 分頁；商品頁很多時會需要較長時間。
5. 看狀態中的「商品筆數 / 預期總數」與「完整：是/否」。
6. 完成後點「4. 匯出完整採集資料 JSON」。
7. 把 JSON 傳給 ChatGPT。

固定後台入口：
https://wing.coupang.com/tenants/sfl-portal/delivery/management

安全：
- 不複製你的瀏覽器 Profile。
- 不讀取或匯出 Cookie。
- 不匯出密碼、Authorization、Access Token、Refresh Token。
- 買家電話、Email、地址等分析不必要的個資會遮蔽。
- 不修改 Coupang Open API，也不影響易客物流串接。

驗收重點：
如果 WING 顯示商品總數 10000，TinySnow 應該顯示商品筆數 10000/10000 且「完整：是」。若顯示 partial、完整：否、或商品筆數不足，不要把結果當成完整全店資料，請匯出 JSON 交給 ChatGPT 繼續修正。
