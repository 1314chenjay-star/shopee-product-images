const $ = id => document.getElementById(id);

async function send(type) {
  return await chrome.runtime.sendMessage({ type });
}

function showMessage(text, isError = false) {
  const el = $('message');
  el.textContent = text || '';
  el.classList.toggle('error', !!isError);
}

async function refreshStatus() {
  try {
    const res = await send('getStatus');
    if (!res.ok) throw new Error(res.error || '讀取狀態失敗');
    $('status').textContent = [
      `採集中：${res.attached ? '是' : '否'}`,
      `API 回應：${res.responses}`,
      `頁面快照：${res.snapshots}`
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
$('startCapture').addEventListener('click', () => runAction('startCapture', '已開始採集。Chrome 可能顯示「正在偵錯此瀏覽器」提示，這是正常的。'));
$('reloadCapture').addEventListener('click', () => runAction('reloadAndCapture', '已重新整理 WING，開始記錄頁面載入時的 API 回應。'));
$('snapshot').addEventListener('click', () => runAction('snapshot', '目前頁面已加入採集資料。'));
$('stopCapture').addEventListener('click', () => runAction('stopCapture', '已停止採集。'));

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
      filename: `TinySnow_Coupang_capture_${stamp}.json`,
      saveAs: true
    });
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    showMessage('採集資料已匯出。把這個 JSON 傳給 ChatGPT 即可分析。');
  } catch (error) {
    showMessage(String(error.message || error), true);
  }
});

refreshStatus();
