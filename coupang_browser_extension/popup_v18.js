const $ = id => document.getElementById(id);
const send = (type, extra={}) => chrome.runtime.sendMessage({type,...extra});
function msg(text,err=false){$('message').textContent=text||'';$('message').classList.toggle('error',!!err);}
function fmtTime(v){if(!v)return '—';try{return new Date(v).toLocaleString();}catch{return String(v)}}
async function refresh(){try{const r=await send('getStatus');if(!r.ok)throw new Error(r.error||'讀取失敗');const d=r.datasets?.products||{};const c=r.crawl||{};const m=r.monitor||{};const complete=d.complete?'是':'否';$('status').textContent=[
`監聽中：${r.attached?'是':'否'}`,
`API 回應：${r.responses||0}`,
`智能採集：${c.status||'尚未開始'}`,
`目標成功：${c.succeeded||0}/${c.attempted||0}`,
`選定頁面：${r.routes?.selected?.length||0}`,
`商品頁數：${d.pageCount||0}`,
`商品筆數：${d.rowCount||0}${d.expectedTotal!=null?'/'+d.expectedTotal:''}`,
`最後頁碼：${d.lastPageNumber??'—'}`,
`完整：${complete}${d.stopReason?'（'+d.stopReason+'）':''}`,
`自動監控：${m.enabled?'已開啟':'關閉'}`,
`上次監控：${fmtTime(m.lastRunAt)}`,
`下次監控：${r.nextMonitorAt?fmtTime(r.nextMonitorAt):'—'}`,
`${m.needsLogin?'⚠ WING 登入已失效，需要重新登入':''}`
].filter(Boolean).join('\n');}catch(e){$('status').textContent='狀態讀取失敗';msg(String(e.message||e),true)}}
async function action(type,text,extra={}){msg('處理中…');try{const r=await send(type,extra);if(!r?.ok)throw new Error(r?.error||'操作失敗');msg(text);await refresh();return r}catch(e){msg(String(e.message||e),true);return null}}
$('focusWing').onclick=()=>action('focusWing','已切到 WING。');
$('fullSync').onclick=()=>action('fullSync','全量同步完成。商品未抓滿時會明確標記「完整：否」。');
$('quickSync').onclick=()=>action('quickSync','快速同步完成。');
$('enableMonitor').onclick=()=>action('enableMonitor','已開啟自動監控：每 6 小時快速同步，每 24 小時至少一次完整商品同步。',{intervalMinutes:360});
$('disableMonitor').onclick=()=>action('disableMonitor','自動監控已關閉。');
$('stop').onclick=()=>action('stop','已送出停止指令。');
$('clearData').onclick=async()=>{if(confirm('確定清空 TinySnow 本機採集資料？'))await action('clearData','本機資料已清空。')};
$('exportData').onclick=async()=>{msg('正在整理分析包…');try{const r=await send('exportData');if(!r?.ok)throw new Error(r?.error||'匯出失敗');const blob=new Blob([JSON.stringify(r.data,null,2)],{type:'application/json;charset=utf-8'});const url=URL.createObjectURL(blob);const stamp=new Date().toISOString().replace(/[:.]/g,'-');await chrome.downloads.download({url,filename:`TinySnow_Coupang_analysis_${stamp}.json`,saveAs:true});setTimeout(()=>URL.revokeObjectURL(url),60000);msg('已匯出最新分析包。')}catch(e){msg(String(e.message||e),true)}};
refresh();setInterval(refresh,2000);
