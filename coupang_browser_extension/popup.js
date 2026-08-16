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
  if (!crawl) return '自動巡航：尚未開始';
  const names = {
    idle: '尚未開始',
    running: '執行中',
    stopping: '正在停止',
    stopped: '已停止',
    completed: '已完成',
    failed: '失敗'
  };
  const lines = [
    `自動巡航：${names[crawl.status] || crawl.status || '未知'}`,
    `進度：${crawl.completed || 0}/${crawl.total || 6}`
  ];
  if (crawl.current) lines.push(`目前：${crawl.current}`);
  if (crawl.error) lines.push(`錯誤：${crawl.error}`);
  return lines.join('\n');
}

async function refreshStatus() {
  try {
    const res = await send('getStatus');
    if (!res.ok) throw new Error(res.error || '讀取狀態失敗');
    $('status').textContent = [
      `採集中：${res.attached ? '是' : '否'}`,
      `API 回應：${res.responses}`,
      `頁面快照：${res.snapshots}`,
      crawlStatusText(res.crawl)
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
$('startCapture').addEventListener('click', () => runAction('startCapture', '已開始監聽目前分頁。'));
$('reloadCapture').addEventListener('click', () => runAction('reloadAndCapture', '已重新整理目前頁並開始抓 API。'));
$('snapshot').addEventListener('click', () => runAction('snapshot', '目前頁面已加入採集資料。'));
$('stopCapture').addEventListener('click', () => runAction('stopCapture', '已停止全部採集。'));
$('stopAutoCrawl').addEventListener('click', () => runAction('stopAutoCrawl', '已送出停止指令。'));

$('autoCrawl').addEventListener('click', async () => {
  showMessage('自動巡航已啟動。你不用再一頁一頁點，請讓 WING 分頁保持開啟。');
  const res = await runAction('autoCrawl', '自動巡航已完成。現在可以直接匯出 JSON。');
  if (res && res.stopped) showMessage('自動巡航已停止，已保留目前採集到的資料。');
});

$('clearData').addEventListener('click', async () => {
  if (!confirm('確定清空 TinySnow 在本機保存的採集資料？')) return;
  await runAction('clearData', '本機採集資料已清空。');
});

$('exportData').addEventListener('click', async () => {
  showMessage('正在整理匯出檔…');
  try {
    const res = await send('exportData');
    if (!res || !res.ok) throw new Error((res && res.error) || '匯出失敗');
    const json = JSON.stringify(res.data, null, 2);
    const blob = new Blob([json], { type: 'application/json;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    await chrome.downloads.download({
      url,
      filename: `TinySnow_Coupang_auto_capture_${stamp}.json`,
      saveAs: true
    });
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    showMessage('採集資料已匯出。把這個 JSON 傳給 ChatGPT 即可分析。');
  } catch (error) {
    showMessage(String(error.message || error), true);
  }
});

refreshStatus();
setInterval(refreshStatus, 1500);
