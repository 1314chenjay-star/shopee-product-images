TinySnow Coupang Data Collector V1.4

用途：只處理 Coupang WING 本地數據採集，不包含蝦皮圖片功能。

預設後台入口：
https://wing.coupang.com/tenants/sfl-portal/delivery/management

使用方式：
1. 下載後只需要解壓縮一次。
2. 雙擊 START.bat。
3. 優先選 1：使用目前 Edge/Chrome 已登入狀態。
4. 第一次匯入時選擇你平常已登入 Coupang 的瀏覽器 Profile。
5. TinySnow 之後會直接開啟上面的配送管理後台網址。
6. 在專用瀏覽器中再打開需要採集的商品、訂單、數據分析等頁面。
7. 回工具選 4 採集目前已開啟的 Coupang 頁面。
8. 選 5 打包最新採集資料。

安全原則：
- 不讀取或保存帳號密碼。
- 不修改 Coupang Open API。
- 不影響目前綁定易客的物流串接。
- 本機登入狀態與採集資料保留在 _system\workspace\coupang。

打包規則：
- 發布包不可再內嵌第二層 ZIP。
- 使用者下載後只解壓一次，應直接看到 START.bat、README_COUPANG.txt、_system。
