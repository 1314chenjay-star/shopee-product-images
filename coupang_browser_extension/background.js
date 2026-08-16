const TARGET_URL = 'https://wing.coupang.com/tenants/sfl-portal/delivery/management';
const STORAGE_KEY = 'tinysnowCoupangCaptureV16';
const MAX_BODY_CHARS = 4_000_000;
const MAX_RECORDS = 1000;

const AUTO_CRAWL_PLAN = [
  {
    id: 'products',
    label: '商品管理 → 商品列表',
    path: [
      ['商品管理'],
      ['商品列表', '管理商品', '商品查詢', '商品查詢/修改', '商品查詢／修改']
    ]
  },
  {
    id: 'orders',
    label: '訂購/配送 → 我的訂單',
    path: [
      ['訂購/配送', '訂購／配送'],
      ['我的訂單']
    ]
  },
  {
    id: 'returns',
    label: '退貨/退款/取消',
    path: [
      ['訂購/配送', '訂購／配送'],
      ['退貨/退款/取消', '退貨／退款／取消']
    ]
  },
  {
    id: 'settlement',
    label: '結算',
    path: [['結算']]
  },
  {
    id: 'growth',
    label: '賣家成長',
    path: [['賣家成長']]
  },
  {
    id: 'insights',
    label: '商業洞察',
    path: [['商業洞察']]
  }
];

let activeSession = {
  tabId: null,
  attached: false,
  startedAt: null,
  pending: new Map()
};

let crawlControl = {
  running: false,
  stopRequested: false
};

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function isSensitiveEndpoint(rawUrl) {
  try {
    const url = new URL(String(rawUrl || ''));
    const host = url.hostname.toLowerCase();
    const path = url.pathname.toLowerCase();
    if (host.includes('xauth.') || host.startsWith('auth.') || host.includes('login.')) return true;
    return /(^|\/)(auth|login|logout|oauth|token|signin|sso)(\/|$)/i.test(path);
  } catch {
    return true;
  }
}

function isCoupangBusinessUrl(rawUrl) {
  try {
    const url = new URL(String(rawUrl || ''));
    const host = url.hostname.toLowerCase();
    const allowed = host === 'wing.coupang.com' || host.endsWith('.coupang.com') || host.endsWith('.coupangcdn.com');
    return allowed && !isSensitiveEndpoint(rawUrl);
  } catch {
    return false;
  }
}

function sanitizeUrl(rawUrl) {
  try {
    const url = new URL(String(rawUrl || ''));
    for (const key of [...url.searchParams.keys()]) {
      if (/token|auth|code|session|sid|secret|password|credential|key/i.test(key)) {
        url.searchParams.set(key, '[REDACTED]');
      }
    }
    return url.toString();
  } catch {
    return '';
  }
}

const SECRET_KEY_RE = /^(authorization|cookie|set-cookie|password|passwd|pwd|secret|access.?token|refresh.?token|id.?token|session.?id|session.?token|credential|api.?key)$/i;
const PII_KEY_RE = /(phone|mobile|email|e-mail|address|zipcode|zip_code|postal|recipient|receiver|buyer.?name|customer.?name)/i;

function sanitizeObject(value, depth = 0) {
  if (depth > 20) return '[DEPTH_LIMIT]';
  if (Array.isArray(value)) return value.map(v => sanitizeObject(v, depth + 1));
  if (value && typeof value === 'object') {
    const out = {};
    for (const [key, val] of Object.entries(value)) {
      if (SECRET_KEY_RE.test(key)) {
        out[key] = '[REDACTED_SECRET]';
      } else if (PII_KEY_RE.test(key)) {
        out[key] = '[REDACTED_PII]';
      } else {
        out[key] = sanitizeObject(val, depth + 1);
      }
    }
    return out;
  }
  return value;
}

function sanitizeBody(body, mimeType) {
  if (!body) return '';
  const text = String(body);
  const lowerMime = String(mimeType || '').toLowerCase();
  if (lowerMime.includes('json') || text.trim().startsWith('{') || text.trim().startsWith('[')) {
    try {
      return JSON.stringify(sanitizeObject(JSON.parse(text)));
    } catch {
      // Fall through to bounded text.
    }
  }
  return text
    .replace(/("?(?:authorization|cookie|set-cookie|password|secret|access[_-]?token|refresh[_-]?token|session[_-]?token)"?\s*[:=]\s*)[^,;\n\r}]+/gi, '$1[REDACTED]')
    .slice(0, MAX_BODY_CHARS);
}

async function loadCapture() {
  const result = await chrome.storage.local.get(STORAGE_KEY);
  return result[STORAGE_KEY] || {
    version: '1.6.0',
    createdAt: new Date().toISOString(),
    startedAt: null,
    stoppedAt: null,
    sourceTab: null,
    snapshots: [],
    responses: [],
    crawl: {
      status: 'idle',
      current: null,
      completed: 0,
      total: AUTO_CRAWL_PLAN.length,
      startedAt: null,
      finishedAt: null,
      results: []
    },
    notes: [
      'No passwords, cookies, Authorization headers, access tokens, refresh tokens or login credentials are intentionally exported.',
      'Buyer contact/address fields in structured API data are redacted because they are not required for store-operation analysis.',
      'V1.6 automatically navigates the main WING operation sections to discover real business-data endpoints. Pagination-specific full-history harvesting is intentionally deferred until the first real endpoint map is verified.'
    ]
  };
}

async function saveCapture(capture) {
  await chrome.storage.local.set({ [STORAGE_KEY]: capture });
}

async function appendResponse(record) {
  const capture = await loadCapture();
  capture.responses.push(record);
  if (capture.responses.length > MAX_RECORDS) {
    capture.responses = capture.responses.slice(capture.responses.length - MAX_RECORDS);
    if (!capture.notes.includes('Response list reached the safety cap; oldest captured responses were dropped.')) {
      capture.notes.push('Response list reached the safety cap; oldest captured responses were dropped.');
    }
  }
  await saveCapture(capture);
}

async function takeSnapshot(tabId, tag = '') {
  const injection = await chrome.scripting.executeScript({
    target: { tabId },
    func: (snapshotTag) => {
      const norm = s => String(s || '').replace(/\r/g, '').trim();
      const piiHeader = /(訂貨人|收件人|聯絡|電話|手機|email|e-mail|地址|郵遞區號|recipient|receiver|phone|mobile|email|address)/i;
      const tables = [...document.querySelectorAll('table')].map((table, index) => {
        const headers = [...table.querySelectorAll('thead th')].map(x => norm(x.innerText));
        const rows = [...table.querySelectorAll('tbody tr')].slice(0, 500).map(tr => {
          const cells = [...tr.querySelectorAll('th,td')].map(td => norm(td.innerText));
          return cells.map((value, cellIndex) => {
            const header = headers[cellIndex] || '';
            return piiHeader.test(header) ? '[REDACTED_PII]' : value;
          });
        });
        return { index, headers, rows };
      });
      const grids = [...document.querySelectorAll('[role="grid"], [role="table"]')].slice(0, 30).map((el, index) => ({
        index,
        role: el.getAttribute('role'),
        text: norm(el.innerText)
          .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[REDACTED_EMAIL]')
          .replace(/(?:\+?\d[\d\s().-]{7,}\d)/g, '[REDACTED_PHONE]')
          .slice(0, 300000)
      }));
      return {
        tag: snapshotTag || '',
        capturedAt: new Date().toISOString(),
        title: document.title,
        url: location.href,
        bodyText: norm(document.body ? document.body.innerText : '')
          .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[REDACTED_EMAIL]')
          .replace(/(?:\+?\d[\d\s().-]{7,}\d)/g, '[REDACTED_PHONE]')
          .slice(0, 1_500_000),
        tables,
        grids
      };
    },
    args: [tag]
  });
  const value = injection && injection[0] ? injection[0].result : null;
  if (!value) throw new Error('無法讀取目前分頁內容。');
  const capture = await loadCapture();
  capture.snapshots.push(value);
  if (capture.snapshots.length > 60) capture.snapshots = capture.snapshots.slice(-60);
  await saveCapture(capture);
  return value;
}

async function attachToTab(tabId) {
  if (activeSession.attached && activeSession.tabId === tabId) return;
  if (activeSession.attached && activeSession.tabId !== tabId) {
    try { await chrome.debugger.detach({ tabId: activeSession.tabId }); } catch {}
  }
  await chrome.debugger.attach({ tabId }, '1.3');
  await chrome.debugger.sendCommand({ tabId }, 'Network.enable', {
    maxTotalBufferSize: 100000000,
    maxResourceBufferSize: 10000000,
    maxPostDataSize: 0
  });
  activeSession = { tabId, attached: true, startedAt: new Date().toISOString(), pending: new Map() };
  const capture = await loadCapture();
  capture.startedAt = capture.startedAt || activeSession.startedAt;
  capture.stoppedAt = null;
  const tab = await chrome.tabs.get(tabId);
  capture.sourceTab = { id: tabId, title: tab.title || '', url: sanitizeUrl(tab.url || '') };
  await saveCapture(capture);
}

chrome.debugger.onEvent.addListener(async (source, method, params) => {
  if (!activeSession.attached || source.tabId !== activeSession.tabId) return;
  try {
    if (method === 'Network.responseReceived') {
      const response = params.response || {};
      const url = response.url || '';
      const mimeType = response.mimeType || '';
      const type = params.type || '';
      if (!isCoupangBusinessUrl(url)) return;
      if (!['XHR', 'Fetch', 'Document'].includes(type)) return;
      if (!/(json|text|javascript|xml|csv|html)/i.test(mimeType)) return;
      activeSession.pending.set(params.requestId, {
        requestId: params.requestId,
        capturedAt: new Date().toISOString(),
        url: sanitizeUrl(url),
        status: response.status,
        mimeType,
        resourceType: type
      });
    }

    if (method === 'Network.loadingFinished') {
      const meta = activeSession.pending.get(params.requestId);
      if (!meta) return;
      activeSession.pending.delete(params.requestId);
      let body = '';
      let omitted = null;
      try {
        const result = await chrome.debugger.sendCommand({ tabId: source.tabId }, 'Network.getResponseBody', { requestId: params.requestId });
        if (result.base64Encoded) {
          omitted = 'binary_or_base64_body_not_exported';
        } else if (String(result.body || '').length > MAX_BODY_CHARS) {
          body = sanitizeBody(String(result.body || '').slice(0, MAX_BODY_CHARS), meta.mimeType);
          omitted = 'body_truncated_at_4m_chars';
        } else {
          body = sanitizeBody(result.body || '', meta.mimeType);
        }
      } catch (error) {
        omitted = `response_body_unavailable:${String(error && error.message || error)}`;
      }
      await appendResponse({ ...meta, encodedDataLength: params.encodedDataLength || 0, body, omitted });
    }
  } catch (error) {
    console.warn('TinySnow capture event failed', error);
  }
});

chrome.debugger.onDetach.addListener(source => {
  if (source.tabId === activeSession.tabId) {
    activeSession.attached = false;
    activeSession.pending = new Map();
  }
});

async function getActiveTab() {
  const tabs = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tabs.length) throw new Error('找不到目前分頁。');
  return tabs[0];
}

async function findExistingWingTab() {
  const tabs = await chrome.tabs.query({});
  const exact = tabs.find(t => String(t.url || '').startsWith('https://wing.coupang.com/') && !String(t.url || '').includes('/auth/'));
  return exact || null;
}

async function clickMenuCandidates(tabId, candidates) {
  try {
    const result = await chrome.scripting.executeScript({
      target: { tabId },
      func: labels => {
        const norm = s => String(s || '').replace(/\s+/g, '').replace(/／/g, '/').trim();
        const wanted = labels.map(norm);
        const visible = el => {
          const r = el.getBoundingClientRect();
          const style = getComputedStyle(el);
          return r.width > 0 && r.height > 0 && style.display !== 'none' && style.visibility !== 'hidden';
        };
        const selectors = 'a,button,[role="button"],[role="menuitem"],li,span,div';
        const nodes = [...document.querySelectorAll(selectors)].filter(visible);
        const scored = [];
        for (const el of nodes) {
          const text = norm(el.innerText || el.textContent || '');
          if (!text) continue;
          let score = -1;
          for (const label of wanted) {
            if (text === label) score = Math.max(score, 1000 - text.length);
            else if (text.startsWith(label) && text.length <= label.length + 8) score = Math.max(score, 700 - text.length);
          }
          if (score >= 0) {
            let clickable = el.closest('a,button,[role="button"],[role="menuitem"]') || el;
            const clickText = norm(clickable.innerText || clickable.textContent || text);
            if (clickText.length > text.length + 30) clickable = el;
            scored.push({ el, clickable, score, text });
          }
        }
        scored.sort((a, b) => b.score - a.score);
        const best = scored[0];
        if (!best) return { clicked: false, labels };
        best.clickable.scrollIntoView({ block: 'center', inline: 'nearest' });
        best.clickable.click();
        return {
          clicked: true,
          matchedText: best.text,
          href: best.clickable.href || best.el.href || ''
        };
      },
      args: [candidates]
    });
    return result && result[0] && result[0].result ? result[0].result : { clicked: false };
  } catch (error) {
    if (/frame|context|navigation/i.test(String(error && error.message || error))) {
      return { clicked: true, navigationInterruptedResult: true };
    }
    throw error;
  }
}

async function getPageSignature(tabId) {
  try {
    const result = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => ({
        url: location.href,
        title: document.title,
        readyState: document.readyState,
        bodyLength: document.body ? document.body.innerText.length : 0
      })
    });
    return result && result[0] ? result[0].result : null;
  } catch {
    return null;
  }
}

async function waitForPageStable(tabId, timeoutMs = 12000) {
  const started = Date.now();
  let previous = null;
  let stableHits = 0;
  await sleep(900);
  while (Date.now() - started < timeoutMs) {
    const current = await getPageSignature(tabId);
    if (current && current.readyState === 'complete') {
      const signature = `${current.url}|${current.title}|${current.bodyLength}`;
      if (signature === previous) stableHits += 1;
      else stableHits = 0;
      previous = signature;
      if (stableHits >= 2) return current;
    }
    await sleep(800);
  }
  return await getPageSignature(tabId);
}

async function setCrawlState(patch) {
  const capture = await loadCapture();
  capture.crawl = { ...(capture.crawl || {}), ...patch };
  await saveCapture(capture);
  return capture.crawl;
}

async function appendCrawlResult(result) {
  const capture = await loadCapture();
  capture.crawl = capture.crawl || {};
  capture.crawl.results = Array.isArray(capture.crawl.results) ? capture.crawl.results : [];
  capture.crawl.results.push(result);
  capture.crawl.completed = capture.crawl.results.length;
  await saveCapture(capture);
}

async function runAutoCrawl() {
  if (crawlControl.running) return { ok: false, error: '自動巡航已經在執行中。' };
  const wing = await findExistingWingTab();
  const tab = wing || await getActiveTab();
  if (!String(tab.url || '').startsWith('https://wing.coupang.com/')) {
    return { ok: false, error: '請先開啟你已登入的 WING 後台分頁，再執行一鍵採集。' };
  }

  crawlControl = { running: true, stopRequested: false };
  await attachToTab(tab.id);

  const capture = await loadCapture();
  capture.crawl = {
    status: 'running',
    current: '目前頁面',
    completed: 0,
    total: AUTO_CRAWL_PLAN.length,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    results: []
  };
  await saveCapture(capture);

  try {
    try { await takeSnapshot(tab.id, 'auto_crawl_initial'); } catch {}

    for (let index = 0; index < AUTO_CRAWL_PLAN.length; index++) {
      if (crawlControl.stopRequested) break;
      const step = AUTO_CRAWL_PLAN[index];
      await setCrawlState({ current: step.label, completed: index });
      const before = await loadCapture();
      const responseStart = before.responses.length;
      let failure = null;
      const clicks = [];

      try {
        for (let depth = 0; depth < step.path.length; depth++) {
          if (crawlControl.stopRequested) break;
          const candidates = step.path[depth];
          const clicked = await clickMenuCandidates(tab.id, candidates);
          clicks.push({ candidates, ...clicked });
          if (!clicked.clicked) {
            throw new Error(`找不到選單：${candidates.join(' / ')}`);
          }
          await sleep(depth === step.path.length - 1 ? 1200 : 650);
        }

        if (!crawlControl.stopRequested) {
          await waitForPageStable(tab.id, 12000);
          await sleep(1200);
          const snapshot = await takeSnapshot(tab.id, `auto_${step.id}`);
          const after = await loadCapture();
          await appendCrawlResult({
            id: step.id,
            label: step.label,
            ok: true,
            capturedAt: new Date().toISOString(),
            url: sanitizeUrl(snapshot.url || ''),
            title: snapshot.title || '',
            newResponses: Math.max(0, after.responses.length - responseStart),
            clicks
          });
        }
      } catch (error) {
        failure = String(error && error.message || error);
        const sig = await getPageSignature(tab.id);
        const after = await loadCapture();
        await appendCrawlResult({
          id: step.id,
          label: step.label,
          ok: false,
          capturedAt: new Date().toISOString(),
          url: sanitizeUrl(sig && sig.url || ''),
          title: sig && sig.title || '',
          newResponses: Math.max(0, after.responses.length - responseStart),
          error: failure,
          clicks
        });
      }

      if (crawlControl.stopRequested) break;
      await sleep(500);
    }

    const stopped = crawlControl.stopRequested;
    const finalCapture = await loadCapture();
    finalCapture.crawl.status = stopped ? 'stopped' : 'completed';
    finalCapture.crawl.current = null;
    finalCapture.crawl.finishedAt = new Date().toISOString();
    finalCapture.crawl.completed = finalCapture.crawl.results.length;
    await saveCapture(finalCapture);
    return {
      ok: true,
      stopped,
      completed: finalCapture.crawl.completed,
      total: finalCapture.crawl.total,
      responses: finalCapture.responses.length,
      snapshots: finalCapture.snapshots.length
    };
  } catch (error) {
    await setCrawlState({
      status: 'failed',
      current: null,
      finishedAt: new Date().toISOString(),
      error: String(error && error.message || error)
    });
    return { ok: false, error: String(error && error.message || error) };
  } finally {
    crawlControl.running = false;
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    switch (message && message.type) {
      case 'focusExistingWing': {
        const tab = await findExistingWingTab();
        if (!tab) return { ok: false, error: '目前沒有找到已開啟的 WING 後台分頁。請先在你平常已登入的瀏覽器打開 WING。' };
        if (tab.windowId != null) await chrome.windows.update(tab.windowId, { focused: true });
        await chrome.tabs.update(tab.id, { active: true });
        return { ok: true, tabId: tab.id, url: tab.url };
      }
      case 'openBackend': {
        const wing = await findExistingWingTab();
        const tab = wing || await getActiveTab();
        await chrome.tabs.update(tab.id, { url: TARGET_URL, active: true });
        if (tab.windowId != null) await chrome.windows.update(tab.windowId, { focused: true });
        return { ok: true, tabId: tab.id, url: TARGET_URL };
      }
      case 'startCapture': {
        const wing = await findExistingWingTab();
        const tab = wing || await getActiveTab();
        if (!String(tab.url || '').startsWith('https://wing.coupang.com/')) {
          return { ok: false, error: '請先切到你已登入的 wing.coupang.com 後台分頁，再開始採集。' };
        }
        await attachToTab(tab.id);
        await takeSnapshot(tab.id, 'manual_start');
        return { ok: true, tabId: tab.id };
      }
      case 'autoCrawl': {
        return await runAutoCrawl();
      }
      case 'stopAutoCrawl': {
        crawlControl.stopRequested = true;
        await setCrawlState({ status: crawlControl.running ? 'stopping' : 'stopped' });
        return { ok: true };
      }
      case 'snapshot': {
        const wing = await findExistingWingTab();
        const tab = wing || await getActiveTab();
        const snapshot = await takeSnapshot(tab.id, 'manual_snapshot');
        return { ok: true, snapshot };
      }
      case 'reloadAndCapture': {
        const wing = await findExistingWingTab();
        const tab = wing || await getActiveTab();
        await attachToTab(tab.id);
        await chrome.tabs.reload(tab.id, { bypassCache: false });
        return { ok: true, tabId: tab.id };
      }
      case 'stopCapture': {
        crawlControl.stopRequested = true;
        if (activeSession.attached && activeSession.tabId != null) {
          try { await takeSnapshot(activeSession.tabId, 'manual_stop'); } catch {}
          try { await chrome.debugger.detach({ tabId: activeSession.tabId }); } catch {}
        }
        const capture = await loadCapture();
        capture.stoppedAt = new Date().toISOString();
        await saveCapture(capture);
        activeSession = { tabId: null, attached: false, startedAt: null, pending: new Map() };
        return { ok: true };
      }
      case 'getStatus': {
        const capture = await loadCapture();
        return {
          ok: true,
          attached: activeSession.attached,
          tabId: activeSession.tabId,
          responses: capture.responses.length,
          snapshots: capture.snapshots.length,
          startedAt: capture.startedAt,
          crawl: capture.crawl || null
        };
      }
      case 'exportData': {
        const capture = await loadCapture();
        return { ok: true, data: capture };
      }
      case 'clearData': {
        crawlControl.stopRequested = true;
        if (activeSession.attached && activeSession.tabId != null) {
          try { await chrome.debugger.detach({ tabId: activeSession.tabId }); } catch {}
        }
        await chrome.storage.local.remove(STORAGE_KEY);
        activeSession = { tabId: null, attached: false, startedAt: null, pending: new Map() };
        crawlControl = { running: false, stopRequested: false };
        return { ok: true };
      }
      default:
        return { ok: false, error: '未知指令。' };
    }
  })().then(sendResponse).catch(error => sendResponse({ ok: false, error: String(error && error.message || error) }));
  return true;
});

globalThis.__TinySnowV16Test = {
  TARGET_URL,
  AUTO_CRAWL_PLAN,
  isSensitiveEndpoint,
  isCoupangBusinessUrl,
  sanitizeUrl,
  sanitizeObject,
  sanitizeBody
};
