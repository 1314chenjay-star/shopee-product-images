const $ = id => document.getElementById(id);

async function send(type) {
  return await chrome.runtime.sendMessage({ type });
}

function showMessage(text, isError = false) {
  const el = $('message');
  el.textContent = text || '';
  el.classList.toggle('error', !!isError);
}

function crawlStatusText(crawl) {
  if (!crawl) return '自動採集：尚未開始';
  const names = {
    idle: '尚未開始',
    running: '執行中',
    stopping: '正在停止',
    stopped: '已停止',
    completed: '已完成',
    completed_with_errors: '完成但有頁面失敗',
    failed: '失敗'
  };
  const lines = [
    `自動採集：${names[crawl.status] || crawl.status || '未知'}`,
    `目標成功：${crawl.succeeded || 0}/${crawl.total || 6}`,
    `已嘗試：${crawl.attempted || 0}/${crawl.total || 6}`
  ];
  if (crawl.current) lines.push(`目前：${crawl.current}`);
  if (crawl.error) lines.push(`錯誤：${crawl.error}`);
  return lines.join('\n');
}

function productStatusText(products) {
  if (!products) return '商品：尚未開始';
  const expected = products.expectedTotal == null ? '?' : products.expectedTotal;
  return [
    `商品狀態：${products.status || 'idle'}`,
    `商品頁數：${products.pageCount || 0}`,
    `商品筆數：${products.rowCount || 0}/${expected}`,
    `最後頁碼：${products.lastPageNumber || '-'}`,
    `完整：${products.complete ? '是' : '否'}`
  ].join('\n');
}

async function refreshStatus() {
  try {
    const res = await send('getStatus');
    if (!res.ok) throw new Error(res.error || '讀取狀態失敗');
    $('status').textContent = [
      `監聽中：${res.attached ? '是' : '否'}`,
      `API 回應：${res.responses}`,
      `頁面快照：${res.snapshots}`,
      crawlStatusText(res.crawl),
      productStatusText(res.products)
    ].join('\n');
  } catch (error) {
    $('status').textContent = '狀態讀取失敗';
    showMessage(String(error.message || error), true);
  }
}

async function runAction(type, successText) {
  showMessage('處理中…');
  try {
    const res = await send(type);
    if (!res || !res.ok) throw new Error((res && res.error) || '操作失敗');
    showMessage(successText);
    await refreshStatus();
    return res;
  } catch (error) {
    showMessage(String(error.message || error), true);
    return null;
  }
}

$('focusWing').addEventListener('click', () => runAction('focusExistingWing', '已切到現有 WING 後台分頁。'));
$('openBackend').addEventListener('click', () => runAction('openBackend', '已前往你指定的配送管理後台。'));
$('stopAutoCrawl').addEventListener('click', () => runAction('stopAutoCrawl', '已送出停止指令，已抓到的頁面會保留。'));

$('autoCrawl').addEventListener('click', async () => {
  showMessage('全店採集已啟動。商品若有 200 頁，TinySnow 會自己逐頁跑，請保持 WING 分頁開啟。');
  const res = await runAction('autoCrawl', '自動採集流程已結束，請先看上方「商品筆數／完整」再匯出。');
  if (res && res.stopped) showMessage('自動採集已停止，已保留目前抓到的資料。');
});

$('clearData').addEventListener('click', async () => {
  if (!confirm('確定清空 TinySnow 在本機保存的採集資料？')) return;
  await runAction('clearData', '本機採集資料已清空。');
});

$('exportData').addEventListener('click', async () => {
  showMessage('正在整理完整匯出檔，商品頁數多時可能需要幾秒…');
  try {
    const res = await send('exportData');
    if (!res || !res.ok) throw new Error((res && res.error) || '匯出失敗');
    const json = JSON.stringify(res.data, null, 2);
    const blob = new Blob([json], { type: 'application/json;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    await chrome.downloads.download({
      url,
      filename: `TinySnow_Coupang_V17_full_capture_${stamp}.json`,
      saveAs: true
    });
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    showMessage('完整採集資料已匯出。把這個 JSON 傳給 ChatGPT。');
  } catch (error) {
    showMessage(String(error.message || error), true);
  }
});

refreshStatus();
setInterval(refreshStatus, 1500);
