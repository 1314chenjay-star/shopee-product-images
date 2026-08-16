const TARGET_URL = 'https://wing.coupang.com/tenants/sfl-portal/delivery/management';
const STORAGE_KEY = 'tinysnowCoupangCaptureV18';
const PAGE_PREFIX = 'tinysnowCoupangV18Page:';
const MONITOR_ALARM = 'tinysnow-coupang-monitor-v18';
const MAX_BODY_CHARS = 4_000_000;
const MAX_RECORDS = 6000;
const MAX_PRODUCT_PAGES = 500;
const QUICK_INTERVAL_MINUTES = 360;
const FULL_INTERVAL_MS = 24 * 60 * 60 * 1000;

const NAV_GROUPS = [
  { id: 'products', parent: ['商品管理'], exact: ['商品列表','管理商品','商品查询/修改','商品查詢/修改','商品查询','商品查詢'], fullProducts: true },
  { id: 'price', parent: ['价格管理','價格管理'], groupKeywords: ['价格','價格','定价','定價','竞争','競爭','价格建议','價格建議'] },
  { id: 'orders', parent: ['订购/配送','訂購/配送','订购／配送','訂購／配送'], exact: ['我的订单','我的訂單'] },
  { id: 'returns', parent: ['订购/配送','訂購/配送','订购／配送','訂購／配送'], exact: ['退货/退款/取消','退貨/退款/取消','退货／退款／取消','退貨／退款／取消'] },
  { id: 'exchange', parent: ['订购/配送','訂購/配送','订购／配送','訂購／配送'], exact: ['换货管理','換貨管理'] },
  { id: 'settlement', parent: ['结算','結算'], groupKeywords: ['结算','結算','销售明细','銷售明細','付款','对账','對帳','税','稅'] },
  { id: 'growth', parent: ['卖家成长','賣家成長'], groupKeywords: ['成长','成長','销售','銷售','表现','表現','诊断','診斷','建议','建議'] },
  { id: 'insights', parent: ['商业洞察','商業洞察'], groupKeywords: ['洞察','分析','流量','转化','轉化','销售','銷售','商品','搜索','搜尋','关键词','關鍵詞'] },
  { id: 'promotions', parent: ['促销活动','促銷活動'], groupKeywords: ['活动列表','活動列表','成效','分析','历史','歷史','优惠券','優惠券','促销记录','促銷記錄'] }
];

const MUTATION_RE = /(新增|新建|注册|註冊|创建|建立|上传|上傳|申请|申請|设置|設定|编辑|編輯|批量修改|建立活动|建立活動|新增活动|新增活動)/i;
const IGNORE_RE = /(客户管理|客戶管理|我的店铺|我的店鋪|卖家信息|賣家信息|公告事项|公告事項|咨询留言|諮詢留言|其他服务|其他服務|coupang\s*api|帮助|幫助)/i;

let session = { tabId: null, attached: false, pending: new Map() };
let control = { running: false, stopRequested: false };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const norm = s => String(s || '').replace(/\s+/g, '').replace(/／/g, '/').replace(/[：:]/g, '').trim().toLowerCase();

function isSensitiveEndpoint(rawUrl) {
  try {
    const u = new URL(String(rawUrl || ''));
    const host = u.hostname.toLowerCase();
    if (host.includes('xauth.') || host.startsWith('auth.') || host.includes('login.')) return true;
    return /(^|\/)(auth|login|logout|oauth|token|signin|sso)(\/|$)/i.test(u.pathname);
  } catch { return true; }
}

function isBusinessUrl(rawUrl) {
  try {
    const u = new URL(String(rawUrl || ''));
    const h = u.hostname.toLowerCase();
    return (h === 'wing.coupang.com' || h.endsWith('.coupang.com') || h.endsWith('.coupangcdn.com')) && !isSensitiveEndpoint(rawUrl);
  } catch { return false; }
}

function sanitizeUrl(rawUrl) {
  try {
    const u = new URL(String(rawUrl || ''));
    for (const k of [...u.searchParams.keys()]) {
      if (/token|auth|code|session|sid|secret|password|credential|key/i.test(k)) u.searchParams.set(k, '[REDACTED]');
    }
    return u.toString();
  } catch { return ''; }
}

const SECRET_RE = /^(authorization|cookie|set-cookie|password|passwd|pwd|secret|access.?token|refresh.?token|id.?token|session.?id|session.?token|credential|api.?key)$/i;
const PII_RE = /(phone|mobile|email|e-mail|address|zipcode|zip_code|postal|recipient|receiver|buyer.?name|customer.?name)/i;
function sanitizeObject(v, depth = 0) {
  if (depth > 20) return '[DEPTH_LIMIT]';
  if (Array.isArray(v)) return v.map(x => sanitizeObject(x, depth + 1));
  if (v && typeof v === 'object') {
    const out = {};
    for (const [k, x] of Object.entries(v)) out[k] = SECRET_RE.test(k) ? '[REDACTED_SECRET]' : PII_RE.test(k) ? '[REDACTED_PII]' : sanitizeObject(x, depth + 1);
    return out;
  }
  return v;
}
function sanitizeBody(body, mime) {
  const text = String(body || '');
  if (!text) return '';
  if (/json/i.test(String(mime || '')) || /^[\s]*[\[{]/.test(text)) {
    try { return JSON.stringify(sanitizeObject(JSON.parse(text))); } catch {}
  }
  return text.replace(/("?(?:authorization|cookie|set-cookie|password|secret|access[_-]?token|refresh[_-]?token|session[_-]?token)"?\s*[:=]\s*)[^,;\n\r}]+/gi, '$1[REDACTED]').slice(0, MAX_BODY_CHARS);
}

function defaultCapture() {
  return {
    version: '1.8.0', createdAt: new Date().toISOString(), startedAt: null, sourceTab: null,
    responses: [], snapshots: [], routes: { selected: [], skipped: [] },
    datasets: { products: { status: 'idle', pageCount: 0, rowCount: 0, expectedTotal: null, lastPageNumber: null, complete: false, stopReason: null, pageKeys: [], headers: [] } },
    crawl: { status: 'idle', current: null, attempted: 0, succeeded: 0, total: 0, startedAt: null, finishedAt: null, results: [] },
    monitor: { enabled: false, intervalMinutes: QUICK_INTERVAL_MINUTES, lastRunAt: null, lastFullProductAt: null, lastStatus: null, needsLogin: false, history: [] },
    notes: ['Sensitive login secrets are not intentionally exported.', 'Buyer phone/email/address fields are redacted.', 'V1.8 selects analysis-relevant WING pages and skips account/settings/help pages.']
  };
}
async function loadCapture() { const r = await chrome.storage.local.get(STORAGE_KEY); return r[STORAGE_KEY] || defaultCapture(); }
async function saveCapture(c) { await chrome.storage.local.set({ [STORAGE_KEY]: c }); }

async function appendResponse(record) {
  const c = await loadCapture();
  c.responses.push(record);
  if (c.responses.length > MAX_RECORDS) c.responses = c.responses.slice(-MAX_RECORDS);
  await saveCapture(c);
}

async function attach(tabId) {
  if (session.attached && session.tabId === tabId) return;
  if (session.attached && session.tabId !== tabId) { try { await chrome.debugger.detach({ tabId: session.tabId }); } catch {} }
  await chrome.debugger.attach({ tabId }, '1.3');
  await chrome.debugger.sendCommand({ tabId }, 'Network.enable', { maxTotalBufferSize: 100000000, maxResourceBufferSize: 10000000, maxPostDataSize: 0 });
  session = { tabId, attached: true, pending: new Map() };
  const c = await loadCapture();
  c.startedAt ||= new Date().toISOString();
  const t = await chrome.tabs.get(tabId);
  c.sourceTab = { id: tabId, title: t.title || '', url: sanitizeUrl(t.url || '') };
  await saveCapture(c);
}

chrome.debugger.onEvent.addListener(async (source, method, params) => {
  if (!session.attached || source.tabId !== session.tabId) return;
  try {
    if (method === 'Network.responseReceived') {
      const r = params.response || {}; const url = r.url || ''; const type = params.type || ''; const mime = r.mimeType || '';
      if (!isBusinessUrl(url) || !['XHR','Fetch','Document'].includes(type) || !/(json|text|javascript|xml|csv|html)/i.test(mime)) return;
      session.pending.set(params.requestId, { requestId: params.requestId, capturedAt: new Date().toISOString(), url: sanitizeUrl(url), status: r.status, mimeType: mime, resourceType: type });
    } else if (method === 'Network.loadingFinished') {
      const meta = session.pending.get(params.requestId); if (!meta) return; session.pending.delete(params.requestId);
      let body = '', omitted = null;
      try {
        const r = await chrome.debugger.sendCommand({ tabId: source.tabId }, 'Network.getResponseBody', { requestId: params.requestId });
        if (r.base64Encoded) omitted = 'binary_or_base64_body_not_exported';
        else { body = sanitizeBody(String(r.body || '').slice(0, MAX_BODY_CHARS), meta.mimeType); if (String(r.body || '').length > MAX_BODY_CHARS) omitted = 'body_truncated'; }
      } catch (e) { omitted = `body_unavailable:${String(e?.message || e)}`; }
      await appendResponse({ ...meta, body, omitted, encodedDataLength: params.encodedDataLength || 0 });
    }
  } catch (e) { console.warn('TinySnow network capture failed', e); }
});
chrome.debugger.onDetach.addListener(src => { if (src.tabId === session.tabId) session = { tabId: null, attached: false, pending: new Map() }; });

async function findWingTab() { const tabs = await chrome.tabs.query({}); return tabs.find(t => String(t.url || '').startsWith('https://wing.coupang.com/')) || null; }
async function ensureWingTab() {
  let tab = await findWingTab();
  if (!tab) tab = await chrome.tabs.create({ url: TARGET_URL, active: false });
  await waitStable(tab.id, 18000);
  tab = await chrome.tabs.get(tab.id);
  if (!String(tab.url || '').startsWith('https://wing.coupang.com/')) throw new Error('WING 登入已失效，請先在瀏覽器重新登入。');
  return tab;
}
async function pageSig(tabId) { try { const r = await chrome.scripting.executeScript({ target: { tabId }, func: () => ({ url: location.href, readyState: document.readyState, bodyLength: document.body?.innerText.length || 0 }) }); return r?.[0]?.result || null; } catch { return null; } }
async function waitStable(tabId, timeout = 15000) {
  const start = Date.now(); let last = '', hits = 0; await sleep(700);
  while (Date.now() - start < timeout) { const s = await pageSig(tabId); if (s?.readyState === 'complete') { const k = `${s.url}|${s.bodyLength}`; hits = k === last ? hits + 1 : 0; last = k; if (hits >= 2) return s; } await sleep(700); }
  return pageSig(tabId);
}

async function snapshot(tabId, tag) {
  const r = await chrome.scripting.executeScript({ target: { tabId }, func: snapshotTag => {
    const clean = s => String(s || '').replace(/\r/g, '').trim();
    const pii = /(订货人|訂貨人|收件人|联络|聯絡|电话|電話|手机|手機|email|e-mail|地址|邮递区号|郵遞區號|recipient|receiver|phone|mobile|email|address)/i;
    const tables = [...document.querySelectorAll('table')].map((t, index) => { const headers = [...t.querySelectorAll('thead th')].map(x => clean(x.innerText)); const rows = [...t.querySelectorAll('tbody tr')].slice(0,500).map(tr => [...tr.querySelectorAll('th,td')].map((td,i) => pii.test(headers[i] || '') ? '[REDACTED_PII]' : clean(td.innerText))).filter(row => row.some(Boolean)); return { index, headers, rows }; });
    return { tag: snapshotTag, capturedAt: new Date().toISOString(), title: document.title, url: location.href, bodyText: clean(document.body?.innerText || '').replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi,'[REDACTED_EMAIL]').replace(/(?:\+?\d[\d\s().-]{7,}\d)/g,'[REDACTED_PHONE]').slice(0,1_500_000), tables };
  }, args: [tag] });
  const v = r?.[0]?.result; if (!v) return null; const c = await loadCapture(); c.snapshots.push(v); if (c.snapshots.length > 120) c.snapshots = c.snapshots.slice(-120); await saveCapture(c); return v;
}

function scoreText(text, labels) { const t = norm(text); let best = -1; for (const x of labels || []) { const n = norm(x); if (t === n) best = Math.max(best,1000); else if (t.includes(n) && t.length <= n.length + 18) best = Math.max(best,500); } return best; }
function isRelevantLabel(text, group) {
  if (!text || IGNORE_RE.test(text)) return false;
  if (group.exact?.length) return scoreText(text, group.exact) >= 0;
  if (MUTATION_RE.test(text)) return false;
  return (group.groupKeywords || []).some(k => norm(text).includes(norm(k)));
}
async function discoverLinks(tabId) {
  const r = await chrome.scripting.executeScript({ target: { tabId }, func: () => [...document.querySelectorAll('a[href]')].map(a => ({ text: String(a.innerText || a.textContent || a.getAttribute('aria-label') || a.title || '').replace(/\s+/g,' ').trim(), href: a.href || '', title: a.title || '', aria: a.getAttribute('aria-label') || '' })).filter(x => x.href.startsWith('https://wing.coupang.com/') && x.text) });
  return r?.[0]?.result || [];
}
async function clickLabel(tabId, labels) {
  const r = await chrome.scripting.executeScript({ target: { tabId }, func: wants => {
    const n = s => String(s || '').replace(/\s+/g,'').replace(/／/g,'/').trim().toLowerCase(); const wanted = wants.map(n); const list=[];
    for (const el of document.querySelectorAll('a,button,[role="button"],[role="menuitem"],li,span,div')) { const text=n(el.innerText||el.textContent||el.getAttribute('aria-label')||''); if (!text) continue; let score=-1; for(const w of wanted){ if(text===w) score=Math.max(score,1000); else if(text.startsWith(w)&&text.length<=w.length+10)score=Math.max(score,700);} if(score<0)continue; const r=el.getBoundingClientRect(); if(r.width<=0||r.height<=0)continue; list.push({el:el.closest('a,button,[role="button"],[role="menuitem"]')||el,score,text}); }
    list.sort((a,b)=>b.score-a.score); const b=list[0]; if(!b)return {clicked:false}; b.el.scrollIntoView({block:'center'}); b.el.click(); return {clicked:true,text:b.text,href:b.el.href||''};
  }, args: [labels] }); return r?.[0]?.result || { clicked:false };
}
async function discoverRelevantRoutes(tabId) {
  const selected = [], skipped = []; const seen = new Set();
  for (const group of NAV_GROUPS) {
    if (control.stopRequested) break;
    await clickLabel(tabId, group.parent); await sleep(800);
    const links = await discoverLinks(tabId);
    let matches = links.filter(l => isRelevantLabel(`${l.text} ${l.title} ${l.aria}`, group));
    if (group.exact?.length) matches = matches.sort((a,b)=>Math.max(scoreText(b.text,group.exact),scoreText(b.title,group.exact))-Math.max(scoreText(a.text,group.exact),scoreText(a.title,group.exact))).slice(0,1);
    for (const l of matches) { if (!l.href || seen.has(l.href)) continue; seen.add(l.href); selected.push({ id: group.id, label: l.text, href: l.href, fullProducts: !!group.fullProducts }); }
    if (!matches.length) skipped.push({ id: group.id, reason: 'no_relevant_route_found' });
  }
  const c = await loadCapture(); c.routes = { selected, skipped }; await saveCapture(c); return { selected, skipped };
}

async function extractProductPage(tabId) {
  const r = await chrome.scripting.executeScript({ target: { tabId }, func: () => {
    const clean=s=>String(s||'').replace(/\r/g,'').trim(); const pii=/(订货人|訂貨人|收件人|电话|電話|手机|手機|email|地址)/i;
    const tables=[...document.querySelectorAll('table')].map((t,index)=>{let headers=[...t.querySelectorAll('thead th')].map(x=>clean(x.innerText)); const rows=[...t.querySelectorAll('tbody tr')].map(tr=>[...tr.querySelectorAll('th,td')].map((td,i)=>pii.test(headers[i]||'')?'[REDACTED_PII]':clean(td.innerText))).filter(x=>x.some(Boolean)); return {index,headers,rows};});
    const words=/(商品|sku|库存|庫存|售价|售價|价格|價格|销售|銷售|vendor|item|product)/i; const table=tables.map(t=>({...t,score:t.headers.filter(h=>words.test(h)).length*100+t.rows.length})).sort((a,b)=>b.score-a.score)[0]||{headers:[],rows:[],index:null};
    const body=clean(document.body?.innerText||''); let expectedTotal=null; for(const re of [/共\s*([\d,]+)\s*(?:件|个|個|笔|筆|项|項)/,/(?:总计|總計|合计|合計)\s*[:：]?\s*([\d,]+)/,/(?:共|總共|总共)\s*([\d,]+)\s*(?:个商品|個商品|商品)/]){const m=body.match(re);if(m){expectedTotal=Number(m[1].replace(/,/g,''));if(Number.isFinite(expectedTotal))break;}}
    let currentPage=null; const current=document.querySelector('[aria-current="page"]'); if(current&&/^\d+$/.test(clean(current.textContent)))currentPage=Number(clean(current.textContent));
    if(!currentPage){for(const el of document.querySelectorAll('.active,.selected,[class*="active"],[class*="selected"]')){const t=clean(el.textContent);if(/^\d+$/.test(t)){currentPage=Number(t);break;}}}
    let pageSize=null; for(const el of document.querySelectorAll('select,[role="combobox"],button')){const t=clean(el.textContent||el.value||''); if(/^(10|20|30|40|50|100)$/.test(t)){const n=Number(t); if(!pageSize||n>pageSize)pageSize=n;}}
    return { capturedAt:new Date().toISOString(), title:document.title,url:location.href,headers:table.headers,rows:table.rows,tableIndex:table.index,expectedTotal,currentPage,pageSize,bodyHint:body.slice(-12000) };
  }}); return r?.[0]?.result || null;
}
function fp(page){ return JSON.stringify(page?.rows?.[0]||[])+'|'+JSON.stringify(page?.rows?.[page?.rows?.length-1]||[]); }
async function setPageSize50(tabId) {
  const r = await chrome.scripting.executeScript({ target:{tabId}, func:()=>{for(const s of document.querySelectorAll('select')){const o=[...s.options].find(x=>String(x.value)==='50'||/^\s*50\s*(?:个|個|件)?\s*$/.test(String(x.textContent||'')));if(o){if(s.value!==o.value){s.value=o.value;s.dispatchEvent(new Event('change',{bubbles:true}));return {changed:true};}return {changed:false};}} return {changed:false};} }); return r?.[0]?.result||{changed:false};
}
async function goToNextProductPage(tabId, targetPage) {
  const r = await chrome.scripting.executeScript({ target:{tabId}, func:(wantedPage)=>{
    const clean=s=>String(s||'').replace(/\s+/g,'').trim(); const visible=el=>{const r=el.getBoundingClientRect();const st=getComputedStyle(el);return r.width>0&&r.height>0&&st.visibility!=='hidden'&&st.display!=='none';};
    const clickables=[...document.querySelectorAll('button,a,[role="button"],li')].filter(visible); const vw=window.innerWidth; const docH=Math.max(document.body?.scrollHeight||0,document.documentElement.scrollHeight||0); const scored=[];
    for(const el of clickables){const text=clean(el.textContent||'');const aria=clean(el.getAttribute('aria-label')||el.title||'');const data=clean(el.getAttribute('data-page')||el.getAttribute('data-page-number')||'');const rect=el.getBoundingClientRect();let score=-1;
      if(text===String(wantedPage)||data===String(wantedPage))score=1000;
      if(/下一页|下一頁|next/i.test(aria)||/下一页|下一頁|next/i.test(text))score=Math.max(score,850);
      const parent=el.closest('[class*="pagination"],[class*="pager"],nav,[aria-label*="page" i]'); if(parent)score+=180;
      const absY=rect.top+window.scrollY; if(absY>docH*0.55)score+=80; if(rect.left>vw*0.55)score+=50;
      const disabled=el.disabled||el.getAttribute('aria-disabled')==='true'||/disabled/.test(String(el.className||'')); if(score>=0)scored.push({el,score,disabled,text,aria});
    }
    scored.sort((a,b)=>b.score-a.score); const best=scored.find(x=>!x.disabled); if(best){best.el.scrollIntoView({block:'center',inline:'center'});best.el.click();return {found:true,clicked:true,method:best.text===String(wantedPage)?'numeric':'next',label:best.text||best.aria};}
    const clusters=[...document.querySelectorAll('[class*="pagination"],[class*="pager"],nav')].filter(visible); for(const p of clusters){const nums=[...p.querySelectorAll('button,a,[role="button"],li')].filter(visible);const activeIndex=nums.findIndex(x=>x.getAttribute('aria-current')==='page'||/active|selected/.test(String(x.className||'')));if(activeIndex>=0&&nums[activeIndex+1]){const n=nums[activeIndex+1];const dis=n.disabled||n.getAttribute('aria-disabled')==='true'||/disabled/.test(String(n.className||''));if(!dis){n.click();return {found:true,clicked:true,method:'sibling_after_active',label:clean(n.textContent||'')};}}}
    return {found:false,clicked:false};
  }, args:[targetPage] }); return r?.[0]?.result||{found:false,clicked:false};
}
async function waitProductChange(tabId, oldFp, timeout=16000){const start=Date.now();while(Date.now()-start<timeout){await sleep(700);const p=await extractProductPage(tabId);if(p?.rows?.length&&fp(p)!==oldFp)return p;}return extractProductPage(tabId);}
async function resetProductDataset(){const c=await loadCapture();for(const k of c.datasets?.products?.pageKeys||[])await chrome.storage.local.remove(k);c.datasets.products={status:'running',pageCount:0,rowCount:0,expectedTotal:null,lastPageNumber:null,complete:false,stopReason:null,pageKeys:[],headers:[]};await saveCapture(c);}
async function saveProductPage(pageNo,page,uniqueCount){const key=`${PAGE_PREFIX}${String(pageNo).padStart(4,'0')}`;await chrome.storage.local.set({[key]:page});const c=await loadCapture();const d=c.datasets.products;if(!d.pageKeys.includes(key))d.pageKeys.push(key);d.pageCount=d.pageKeys.length;d.rowCount=uniqueCount;d.expectedTotal=page.expectedTotal??d.expectedTotal;d.lastPageNumber=page.currentPage||pageNo;if(page.headers?.length)d.headers=page.headers;await saveCapture(c);}
function productCompletion(rowCount, expectedTotal, endReason, lastPageRows, pageSize=50){if(expectedTotal!=null)return {complete:rowCount>=expectedTotal,status:rowCount>=expectedTotal?'complete':'partial',reason:rowCount>=expectedTotal?'expected_total_reached':endReason||'ended_before_expected_total'};if(endReason==='no_next_control'&&lastPageRows<pageSize)return {complete:true,status:'complete',reason:'short_last_page'};return {complete:false,status:'partial',reason:endReason||'total_unknown'};}
async function harvestProducts(tabId, full=true){await resetProductDataset();const size=await setPageSize50(tabId);if(size.changed){await waitStable(tabId,12000);await sleep(800);}const seen=new Set(), rows=new Set();for(let loop=1;loop<=MAX_PRODUCT_PAGES;loop++){if(control.stopRequested)break;const p=await extractProductPage(tabId);if(!p?.rows?.length)throw new Error('商品列表沒有讀到資料列。');const f=fp(p);if(seen.has(f)){const c=await loadCapture();Object.assign(c.datasets.products,{status:'partial',complete:false,stopReason:'repeated_page_detected'});await saveCapture(c);return c.datasets.products;}seen.add(f);for(const row of p.rows)rows.add(JSON.stringify(row));const pageNo=p.currentPage||loop;await saveProductPage(pageNo,p,rows.size);if(p.expectedTotal!=null&&rows.size>=p.expectedTotal){const c=await loadCapture();Object.assign(c.datasets.products,{status:'complete',complete:true,stopReason:'expected_total_reached'});await saveCapture(c);return c.datasets.products;}if(!full){const c=await loadCapture();Object.assign(c.datasets.products,{status:'quick',complete:false,stopReason:'quick_monitor_first_page_only'});await saveCapture(c);return c.datasets.products;}
    const nextTarget=(p.currentPage||loop)+1;const nav=await goToNextProductPage(tabId,nextTarget);if(!nav.clicked){const end=productCompletion(rows.size,p.expectedTotal,'no_next_control',p.rows.length,p.pageSize||50);const c=await loadCapture();Object.assign(c.datasets.products,{status:end.status,complete:end.complete,stopReason:end.reason});await saveCapture(c);return c.datasets.products;}const changed=await waitProductChange(tabId,f,16000);if(!changed?.rows?.length||fp(changed)===f){const c=await loadCapture();Object.assign(c.datasets.products,{status:'partial',complete:false,stopReason:'next_page_did_not_change_table'});await saveCapture(c);return c.datasets.products;}}
  const c=await loadCapture();Object.assign(c.datasets.products,{status:'partial',complete:false,stopReason:control.stopRequested?'user_stopped':'max_page_guard'});await saveCapture(c);return c.datasets.products;}

async function visitRoute(tabId, route, fullProducts){await chrome.tabs.update(tabId,{url:route.href,active:true});await waitStable(tabId,18000);await sleep(800);await snapshot(tabId,`smart_${route.id}_${Date.now()}`);if(route.id==='products')return harvestProducts(tabId,fullProducts);return null;}
async function runSmartCrawl({ fullProducts=true, monitorRun=false }={}){
  if(control.running)return {ok:false,error:'已有採集工作正在執行。'};control={running:true,stopRequested:false};let tab;
  try{tab=await ensureWingTab();await attach(tab.id);const c=await loadCapture();c.crawl={status:'running',current:'智能辨識頁面',attempted:0,succeeded:0,total:0,startedAt:new Date().toISOString(),finishedAt:null,results:[]};await saveCapture(c);const routes=await discoverRelevantRoutes(tab.id);const c2=await loadCapture();c2.crawl.total=routes.selected.length;await saveCapture(c2);
    for(const route of routes.selected){if(control.stopRequested)break;const before=await loadCapture();const startResponses=before.responses.length;let ok=true,error=null;try{await visitRoute(tab.id,route,fullProducts);}catch(e){ok=false;error=String(e?.message||e);}const after=await loadCapture();after.crawl.attempted+=1;if(ok)after.crawl.succeeded+=1;after.crawl.current=route.label;after.crawl.results.push({id:route.id,label:route.label,href:sanitizeUrl(route.href),ok,error,newResponses:Math.max(0,after.responses.length-startResponses),capturedAt:new Date().toISOString()});await saveCapture(after);}
    const done=await loadCapture();done.crawl.status=control.stopRequested?'stopped':done.crawl.results.some(x=>!x.ok)?'completed_with_errors':'completed';done.crawl.current=null;done.crawl.finishedAt=new Date().toISOString();if(monitorRun){done.monitor.lastRunAt=done.crawl.finishedAt;done.monitor.lastStatus=done.crawl.status;done.monitor.needsLogin=false;if(fullProducts)done.monitor.lastFullProductAt=done.crawl.finishedAt;done.monitor.history.push({at:done.crawl.finishedAt,status:done.crawl.status,fullProducts,products:done.datasets.products.rowCount,expected:done.datasets.products.expectedTotal});done.monitor.history=done.monitor.history.slice(-100);}await saveCapture(done);return {ok:true,status:done.crawl.status,attempted:done.crawl.attempted,succeeded:done.crawl.succeeded,products:done.datasets.products};
  }catch(e){const c=await loadCapture();c.crawl.status='failed';c.crawl.finishedAt=new Date().toISOString();c.crawl.error=String(e?.message||e);if(monitorRun){c.monitor.lastRunAt=c.crawl.finishedAt;c.monitor.lastStatus='failed';c.monitor.needsLogin=/登入|login/i.test(c.crawl.error);c.monitor.history.push({at:c.crawl.finishedAt,status:'failed',error:c.crawl.error});c.monitor.history=c.monitor.history.slice(-100);}await saveCapture(c);return {ok:false,error:c.crawl.error};}finally{control.running=false;}}

async function ensureMonitorAlarm(){const c=await loadCapture();if(!c.monitor.enabled)return;const existing=await chrome.alarms.get(MONITOR_ALARM);if(!existing)await chrome.alarms.create(MONITOR_ALARM,{delayInMinutes:1,periodInMinutes:c.monitor.intervalMinutes||QUICK_INTERVAL_MINUTES});}
async function enableMonitor(intervalMinutes=QUICK_INTERVAL_MINUTES){const c=await loadCapture();c.monitor.enabled=true;c.monitor.intervalMinutes=Math.max(30,Number(intervalMinutes)||QUICK_INTERVAL_MINUTES);await saveCapture(c);await chrome.alarms.clear(MONITOR_ALARM);await chrome.alarms.create(MONITOR_ALARM,{delayInMinutes:1,periodInMinutes:c.monitor.intervalMinutes});return c.monitor;}
async function disableMonitor(){const c=await loadCapture();c.monitor.enabled=false;await saveCapture(c);await chrome.alarms.clear(MONITOR_ALARM);return c.monitor;}
chrome.runtime.onStartup.addListener(()=>{ensureMonitorAlarm().catch(()=>{});});
chrome.runtime.onInstalled.addListener(()=>{ensureMonitorAlarm().catch(()=>{});});
chrome.alarms.onAlarm.addListener(async alarm=>{if(alarm.name!==MONITOR_ALARM||control.running)return;const c=await loadCapture();if(!c.monitor.enabled)return;const lastFull=c.monitor.lastFullProductAt?Date.parse(c.monitor.lastFullProductAt):0;const full=!lastFull||Date.now()-lastFull>=FULL_INTERVAL_MS;await runSmartCrawl({fullProducts:full,monitorRun:true});});

async function exportBundle(){const c=await loadCapture();const pages={};for(const k of c.datasets?.products?.pageKeys||[]){const r=await chrome.storage.local.get(k);pages[k]=r[k];}return {...c,productPages:pages};}

chrome.runtime.onMessage.addListener((m,s,sendResponse)=>{(async()=>{switch(m?.type){
  case 'focusWing':{const t=await ensureWingTab();if(t.windowId!=null)await chrome.windows.update(t.windowId,{focused:true});await chrome.tabs.update(t.id,{active:true});return {ok:true};}
  case 'fullSync':return runSmartCrawl({fullProducts:true,monitorRun:false});
  case 'quickSync':return runSmartCrawl({fullProducts:false,monitorRun:false});
  case 'stop':control.stopRequested=true;return {ok:true};
  case 'enableMonitor':return {ok:true,monitor:await enableMonitor(m.intervalMinutes)};
  case 'disableMonitor':return {ok:true,monitor:await disableMonitor()};
  case 'getStatus':{const c=await loadCapture();const alarm=await chrome.alarms.get(MONITOR_ALARM);return {ok:true,attached:session.attached,responses:c.responses.length,snapshots:c.snapshots.length,crawl:c.crawl,datasets:c.datasets,routes:c.routes,monitor:c.monitor,nextMonitorAt:alarm?.scheduledTime||null};}
  case 'exportData':return {ok:true,data:await exportBundle()};
  case 'clearData':{await chrome.storage.local.clear();session={tabId:null,attached:false,pending:new Map()};control={running:false,stopRequested:false};return {ok:true};}
  default:return {ok:false,error:'未知指令。'};}})().then(sendResponse).catch(e=>sendResponse({ok:false,error:String(e?.message||e)}));return true;});

globalThis.__TinySnowV18Test={norm,isRelevantLabel,productCompletion,isSensitiveEndpoint,isBusinessUrl,sanitizeUrl,sanitizeObject,NAV_GROUPS,QUICK_INTERVAL_MINUTES};
