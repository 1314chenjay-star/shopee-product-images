const TARGET_URL = 'https://wing.coupang.com/tenants/sfl-portal/delivery/management';
const STORAGE_KEY = 'tinysnowCoupangCaptureV17';
const PAGE_KEY_PREFIX = 'tinysnowCoupangV17Page:';
const MAX_BODY_CHARS = 4_000_000;
const MAX_RECORDS = 5000;
const MAX_PRODUCT_PAGES = 500;

const AUTO_CRAWL_PLAN = [
  {
    id: 'products',
    label: '商品管理 → 商品列表',
    labels: ['商品列表', '管理商品', '商品查询/修改', '商品查詢/修改', '商品查询', '商品查詢'],
    parentLabels: ['商品管理']
  },
  {
    id: 'orders',
    label: '訂購/配送 → 我的訂單',
    labels: ['我的订单', '我的訂單'],
    parentLabels: ['订购/配送', '訂購/配送', '订购／配送', '訂購／配送']
  },
  {
    id: 'returns',
    label: '退貨/退款/取消',
    labels: ['退货/退款/取消', '退貨/退款/取消', '退货／退款／取消', '退貨／退款／取消'],
    parentLabels: ['订购/配送', '訂購/配送', '订购／配送', '訂購／配送']
  },
  {
    id: 'settlement',
    label: '結算',
    labels: ['结算', '結算'],
    parentLabels: []
  },
  {
    id: 'growth',
    label: '賣家成長',
    labels: ['卖家成长', '賣家成長'],
    parentLabels: []
  },
  {
    id: 'insights',
    label: '商業洞察',
    labels: ['商业洞察', '商業洞察'],
    parentLabels: []
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

function normalizeNavText(value) {
  return String(value || '')
    .replace(/\s+/g, '')
    .replace(/／/g, '/')
    .replace(/[：:]/g, '')
    .trim()
    .toLowerCase();
}

function scoreLabel(text, candidates) {
  const t = normalizeNavText(text);
  if (!t) return -1;
  let best = -1;
  for (const raw of candidates || []) {
    const c = normalizeNavText(raw);
    if (!c) continue;
    if (t === c) best = Math.max(best, 1000 - t.length);
    else if (t.startsWith(c) && t.length <= c.length + 10) best = Math.max(best, 750 - t.length);
    else if (t.includes(c) && t.length <= c.length + 18) best = Math.max(best, 500 - t.length);
  }
  return best;
}

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
      if (SECRET_KEY_RE.test(key)) out[key] = '[REDACTED_SECRET]';
      else if (PII_KEY_RE.test(key)) out[key] = '[REDACTED_PII]';
      else out[key] = sanitizeObject(val, depth + 1);
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
    } catch {}
  }
  return text
    .replace(/("?(?:authorization|cookie|set-cookie|password|secret|access[_-]?token|refresh[_-]?token|session[_-]?token)"?\s*[:=]\s*)[^,;\n\r}]+/gi, '$1[REDACTED]')
    .slice(0, MAX_BODY_CHARS);
}

function defaultCapture() {
  return {
    version: '1.7.0',
    createdAt: new Date().toISOString(),
    startedAt: null,
    stoppedAt: null,
    sourceTab: null,
    snapshots: [],
    responses: [],
    datasets: {
      products: {
        status: 'idle',
        pageCount: 0,
        rowCount: 0,
        expectedTotal: null,
        lastPageNumber: null,
        complete: false,
        stopReason: null,
        pageKeys: [],
        headers: []
      }
    },
    crawl: {
      status: 'idle',
      current: null,
      attempted: 0,
      succeeded: 0,
      total: AUTO_CRAWL_PLAN.length,
      startedAt: null,
      finishedAt: null,
      results: []
    },
    notes: [
      'No passwords, cookies, Authorization headers, access tokens, refresh tokens or login credentials are intentionally exported.',
      'Buyer contact/address fields in structured API data are redacted because they are not required for store-operation analysis.',
      'V1.7 prefers real WING href/routes over simulated menu clicks and fully paginates the product table through the authenticated UI.'
    ]
  };
}

async function loadCapture() {
  const result = await chrome.storage.local.get(STORAGE_KEY);
  return result[STORAGE_KEY] || defaultCapture();
}

async function saveCapture(capture) {
  await chrome.storage.local.set({ [STORAGE_KEY]: capture });
}

async function appendResponse(record) {
  const capture = await loadCapture();
  capture.responses.push(record);
  if (capture.responses.length > MAX_RECORDS) {
    capture.responses = capture.responses.slice(-MAX_RECORDS);
    if (!capture.notes.includes('Response list reached the safety cap; oldest captured responses were dropped.')) {
      capture.notes.push('Response list reached the safety cap; oldest captured responses were dropped.');
    }
  }
  await saveCapture(capture);
}

async function takeSnapshot(tabId, tag = '') {
  const injection = await chrome.scripting.executeScript({
    target: { tabId },
    func: snapshotTag => {
      const norm = s => String(s || '').replace(/\r/g, '').trim();
      const piiHeader = /(订货人|訂貨人|收件人|联络|聯絡|电话|電話|手机|手機|email|e-mail|地址|邮递区号|郵遞區號|recipient|receiver|phone|mobile|email|address)/i;
      const tables = [...document.querySelectorAll('table')].map((table, index) => {
        const headers = [...table.querySelectorAll('thead th')].map(x => norm(x.innerText));
        const rows = [...table.querySelectorAll('tbody tr')].slice(0, 500).map(tr => {
          const cells = [...tr.querySelectorAll('th,td')].map(td => norm(td.innerText));
          return cells.map((value, cellIndex) => piiHeader.test(headers[cellIndex] || '') ? '[REDACTED_PII]' : value);
        });
        return { index, headers, rows };
      });
      return {
        tag: snapshotTag || '',
        capturedAt: new Date().toISOString(),
        title: document.title,
        url: location.href,
        bodyText: norm(document.body ? document.body.innerText : '')
          .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, '[REDACTED_EMAIL]')
          .replace(/(?:\+?\d[\d\s().-]{7,}\d)/g, '[REDACTED_PHONE]')
          .slice(0, 1_500_000),
        tables
      };
    },
    args: [tag]
  });
  const value = injection?.[0]?.result || null;
  if (!value) throw new Error('無法讀取目前分頁內容。');
  const capture = await loadCapture();
  capture.snapshots.push(value);
  if (capture.snapshots.length > 100) capture.snapshots = capture.snapshots.slice(-100);
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
        if (result.base64Encoded) omitted = 'binary_or_base64_body_not_exported';
        else if (String(result.body || '').length > MAX_BODY_CHARS) {
          body = sanitizeBody(String(result.body || '').slice(0, MAX_BODY_CHARS), meta.mimeType);
          omitted = 'body_truncated_at_4m_chars';
        } else body = sanitizeBody(result.body || '', meta.mimeType);
      } catch (error) {
        omitted = `response_body_unavailable:${String(error?.message || error)}`;
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
  return tabs.find(t => String(t.url || '').startsWith('https://wing.coupang.com/') && !String(t.url || '').includes('/auth/')) || null;
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
    return result?.[0]?.result || null;
  } catch {
    return null;
  }
}

async function waitForPageStable(tabId, timeoutMs = 15000) {
  const started = Date.now();
  let previous = null;
  let stableHits = 0;
  await sleep(800);
  while (Date.now() - started < timeoutMs) {
    const current = await getPageSignature(tabId);
    if (current && current.readyState === 'complete') {
      const signature = `${current.url}|${current.title}|${current.bodyLength}`;
      stableHits = signature === previous ? stableHits + 1 : 0;
      previous = signature;
      if (stableHits >= 2) return current;
    }
    await sleep(700);
  }
  return await getPageSignature(tabId);
}

async function discoverNavigationLinks(tabId) {
  const result = await chrome.scripting.executeScript({
    target: { tabId },
    func: () => {
      const clean = s => String(s || '').replace(/\s+/g, ' ').trim();
      const out = [];
      for (const a of document.querySelectorAll('a[href]')) {
        const href = a.href || '';
        if (!href || !href.startsWith('https://wing.coupang.com/')) continue;
        const text = clean(a.innerText || a.textContent || a.getAttribute('aria-label') || a.title || '');
        if (!text) continue;
        out.push({ text, href, title: a.title || '', ariaLabel: a.getAttribute('aria-label') || '' });
      }
      return out;
    }
  });
  return result?.[0]?.result || [];
}

function chooseBestLink(links, labels) {
  let best = null;
  for (const link of links || []) {
    const fields = [link.text, link.title, link.ariaLabel];
    const score = Math.max(...fields.map(x => scoreLabel(x, labels)));
    if (score >= 0 && (!best || score > best.score)) best = { ...link, score };
  }
  return best;
}

async function robustClickLabels(tabId, labels) {
  try {
    const result = await chrome.scripting.executeScript({
      target: { tabId },
      func: candidates => {
        const norm = s => String(s || '').replace(/\s+/g, '').replace(/／/g, '/').trim().toLowerCase();
        const wanted = candidates.map(norm);
        const all = [...document.querySelectorAll('a,button,[role="button"],[role="menuitem"],li,span,div')];
        const scored = [];
        for (const el of all) {
          const text = norm(el.innerText || el.textContent || el.getAttribute('aria-label') || '');
          if (!text) continue;
          let score = -1;
          for (const w of wanted) {
            if (text === w) score = Math.max(score, 1000 - text.length);
            else if (text.startsWith(w) && text.length <= w.length + 10) score = Math.max(score, 700 - text.length);
          }
          if (score < 0) continue;
          const r = el.getBoundingClientRect();
          if (r.width <= 0 || r.height <= 0) continue;
          let target = el.closest('a,button,[role="button"],[role="menuitem"]') || el;
          scored.push({ target, score, text });
        }
        scored.sort((a, b) => b.score - a.score);
        const best = scored[0];
        if (!best) return { clicked: false };
        const el = best.target;
        el.scrollIntoView({ block: 'center', inline: 'nearest' });
        for (const type of ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click']) {
          try { el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, view: window })); } catch {}
        }
        try { el.click(); } catch {}
        return { clicked: true, text: best.text, href: el.href || '' };
      },
      args: [labels]
    });
    return result?.[0]?.result || { clicked: false };
  } catch (error) {
    if (/frame|context|navigation/i.test(String(error?.message || error))) return { clicked: true, navigationInterruptedResult: true };
    throw error;
  }
}

async function navigateToTarget(tabId, step) {
  let links = await discoverNavigationLinks(tabId);
  let best = chooseBestLink(links, step.labels);
  if (best?.href) {
    await chrome.tabs.update(tabId, { url: best.href, active: true });
    await waitForPageStable(tabId);
    return { method: 'href', href: sanitizeUrl(best.href), matchedText: best.text };
  }

  if (step.parentLabels?.length) {
    const parentClick = await robustClickLabels(tabId, step.parentLabels);
    if (parentClick.clicked) {
      await sleep(1200);
      links = await discoverNavigationLinks(tabId);
      best = chooseBestLink(links, step.labels);
      if (best?.href) {
        await chrome.tabs.update(tabId, { url: best.href, active: true });
        await waitForPageStable(tabId);
        return { method: 'parent_then_href', href: sanitizeUrl(best.href), matchedText: best.text, parentClick };
      }
    }
  }

  const directClick = await robustClickLabels(tabId, step.labels);
  if (directClick.clicked) {
    await waitForPageStable(tabId);
    return { method: 'click', ...directClick };
  }
  throw new Error(`找不到可用路由：${step.label}`);
}

async function setProductPageSize50(tabId) {
  try {
    const result = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        for (const select of document.querySelectorAll('select')) {
          const options = [...select.options];
          const opt = options.find(o => String(o.value) === '50' || /\b50\b/.test(String(o.textContent || '')));
          if (!opt) continue;
          if (select.value !== opt.value) {
            select.value = opt.value;
            select.dispatchEvent(new Event('input', { bubbles: true }));
            select.dispatchEvent(new Event('change', { bubbles: true }));
            return { changed: true, value: opt.value };
          }
          return { changed: false, value: select.value };
        }
        return { changed: false, value: null };
      }
    });
    return result?.[0]?.result || { changed: false, value: null };
  } catch {
    return { changed: false, value: null };
  }
}

async function extractDatasetPage(tabId, targetId) {
  const result = await chrome.scripting.executeScript({
    target: { tabId },
    func: id => {
      const norm = s => String(s || '').replace(/\r/g, '').trim();
      const piiHeader = /(订货人|訂貨人|收件人|联络|聯絡|电话|電話|手机|手機|email|e-mail|地址|邮递区号|郵遞區號|recipient|receiver|phone|mobile|email|address)/i;
      const tables = [...document.querySelectorAll('table')].map((table, index) => {
        let headers = [...table.querySelectorAll('thead th')].map(x => norm(x.innerText));
        const rawRows = [...table.querySelectorAll('tbody tr')];
        if (!headers.length && rawRows.length) headers = [...rawRows[0].querySelectorAll('th')].map(x => norm(x.innerText));
        const rows = rawRows.map(tr => {
          const cells = [...tr.querySelectorAll('th,td')].map(td => norm(td.innerText));
          return cells.map((value, cellIndex) => piiHeader.test(headers[cellIndex] || '') ? '[REDACTED_PII]' : value);
        }).filter(row => row.some(Boolean));
        return { index, headers, rows };
      });

      const productWords = /(商品|sku|库存|庫存|售价|售價|价格|價格|销售|銷售|vendor|item|product)/i;
      let selected = null;
      if (id === 'products') {
        selected = tables
          .map(t => ({ ...t, score: t.headers.filter(h => productWords.test(h)).length * 100 + t.rows.length }))
          .sort((a, b) => b.score - a.score)[0] || null;
      } else {
        selected = tables.slice().sort((a, b) => b.rows.length - a.rows.length)[0] || null;
      }

      const body = norm(document.body ? document.body.innerText : '');
      let expectedTotal = null;
      const totalPatterns = [
        /共\s*([\d,]+)\s*(?:件|个|個|笔|筆|项|項)/,
        /(?:总计|總計|合计|合計)\s*[:：]?\s*([\d,]+)\s*(?:件|个|個|笔|筆|项|項)?/
      ];
      for (const re of totalPatterns) {
        const m = body.match(re);
        if (m) {
          expectedTotal = Number(m[1].replace(/,/g, ''));
          if (Number.isFinite(expectedTotal)) break;
        }
      }

      let currentPage = null;
      const current = document.querySelector('[aria-current="page"]');
      if (current && /^\d+$/.test(norm(current.textContent))) currentPage = Number(norm(current.textContent));
      if (!currentPage) {
        const activeCandidates = [...document.querySelectorAll('.active, .selected, [class*="active"], [class*="selected"]')];
        for (const el of activeCandidates) {
          const t = norm(el.textContent);
          if (/^\d+$/.test(t)) { currentPage = Number(t); break; }
        }
      }

      return {
        targetId: id,
        capturedAt: new Date().toISOString(),
        title: document.title,
        url: location.href,
        headers: selected?.headers || [],
        rows: selected?.rows || [],
        tableIndex: selected?.index ?? null,
        expectedTotal,
        currentPage,
        bodyHint: body.slice(0, 10000)
      };
    },
    args: [targetId]
  });
  return result?.[0]?.result || null;
}

function rowFingerprint(row) {
  return JSON.stringify(row || []);
}

async function saveDatasetPage(targetId, pageNo, pageData) {
  const key = `${PAGE_KEY_PREFIX}${targetId}:${String(pageNo).padStart(4, '0')}`;
  await chrome.storage.local.set({ [key]: pageData });
  const capture = await loadCapture();
  capture.datasets = capture.datasets || {};
  const ds = capture.datasets[targetId] || {
    status: 'running', pageCount: 0, rowCount: 0, expectedTotal: null,
    lastPageNumber: null, complete: false, stopReason: null, pageKeys: [], headers: []
  };
  if (!ds.pageKeys.includes(key)) ds.pageKeys.push(key);
  ds.pageCount = ds.pageKeys.length;
  ds.rowCount += pageData.rows?.length || 0;
  if (pageData.expectedTotal != null) ds.expectedTotal = pageData.expectedTotal;
  if (pageData.headers?.length) ds.headers = pageData.headers;
  ds.lastPageNumber = pageData.currentPage || pageNo;
  ds.status = 'running';
  capture.datasets[targetId] = ds;
  await saveCapture(capture);
  return ds;
}

async function clickNextPage(tabId) {
  const result = await chrome.scripting.executeScript({
    target: { tabId },
    func: () => {
      const norm = s => String(s || '').replace(/\s+/g, '').trim().toLowerCase();
      const nextWords = ['下一页', '下一頁', '下页', '下頁', 'next', '›', '»', '>'];
      const nodes = [...document.querySelectorAll('button,a,[role="button"],li')];
      const candidates = [];
      for (const el of nodes) {
        const label = norm(el.getAttribute('aria-label') || el.title || el.textContent || '');
        if (!nextWords.includes(label) && !nextWords.some(w => label === w || label.startsWith(w))) continue;
        const r = el.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0) continue;
        const cls = String(el.className || '').toLowerCase();
        const disabled = el.disabled || el.getAttribute('aria-disabled') === 'true' || /\bdisabled\b/.test(cls);
        let score = 0;
        if (/下一|next/.test(label)) score += 100;
        if (el.closest('[class*="pagination"], [class*="pager"], nav')) score += 50;
        candidates.push({ el, label, disabled, score });
      }
      candidates.sort((a, b) => b.score - a.score);
      const best = candidates[0];
      if (!best) return { found: false, clicked: false, disabled: false };
      if (best.disabled) return { found: true, clicked: false, disabled: true, label: best.label };
      best.el.scrollIntoView({ block: 'center', inline: 'nearest' });
      best.el.click();
      return { found: true, clicked: true, disabled: false, label: best.label };
    }
  });
  return result?.[0]?.result || { found: false, clicked: false, disabled: false };
}

async function waitForTableChange(tabId, oldFingerprint, timeoutMs = 15000) {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    await sleep(700);
    const page = await extractDatasetPage(tabId, 'products');
    const fp = rowFingerprint(page?.rows?.[0] || []) + '|' + rowFingerprint(page?.rows?.[page?.rows?.length - 1] || []);
    if (page && fp !== oldFingerprint && page.rows.length) return page;
  }
  return await extractDatasetPage(tabId, 'products');
}

async function harvestAllProductPages(tabId) {
  const capture = await loadCapture();
  capture.datasets.products = {
    status: 'running',
    pageCount: 0,
    rowCount: 0,
    expectedTotal: null,
    lastPageNumber: null,
    complete: false,
    stopReason: null,
    pageKeys: [],
    headers: []
  };
  await saveCapture(capture);

  const sizeResult = await setProductPageSize50(tabId);
  if (sizeResult.changed) {
    await waitForPageStable(tabId, 12000);
    await sleep(1000);
  }

  const seenPageFingerprints = new Set();
  const uniqueRows = new Set();

  for (let loop = 1; loop <= MAX_PRODUCT_PAGES; loop++) {
    if (crawlControl.stopRequested) {
      const c = await loadCapture();
      c.datasets.products.status = 'stopped';
      c.datasets.products.stopReason = 'user_stopped';
      await saveCapture(c);
      return c.datasets.products;
    }

    const page = await extractDatasetPage(tabId, 'products');
    if (!page) throw new Error('商品頁讀取失敗。');
    if (!page.rows.length) throw new Error('商品列表沒有讀到任何資料列，無法安全翻頁。');

    const pageFingerprint = rowFingerprint(page.rows[0]) + '|' + rowFingerprint(page.rows[page.rows.length - 1]);
    if (seenPageFingerprints.has(pageFingerprint)) {
      const c = await loadCapture();
      c.datasets.products.status = 'partial';
      c.datasets.products.stopReason = 'repeated_page_detected';
      await saveCapture(c);
      return c.datasets.products;
    }
    seenPageFingerprints.add(pageFingerprint);

    for (const row of page.rows) uniqueRows.add(rowFingerprint(row));
    const pageNo = page.currentPage || loop;
    await saveDatasetPage('products', pageNo, page);

    const c1 = await loadCapture();
    c1.datasets.products.uniqueRowCount = uniqueRows.size;
    c1.datasets.products.rowCount = uniqueRows.size;
    await saveCapture(c1);

    if (page.expectedTotal != null && uniqueRows.size >= page.expectedTotal) {
      const c = await loadCapture();
      c.datasets.products.status = 'complete';
      c.datasets.products.complete = true;
      c.datasets.products.stopReason = 'expected_total_reached';
      await saveCapture(c);
      return c.datasets.products;
    }

    const next = await clickNextPage(tabId);
    if (!next.found || next.disabled || !next.clicked) {
      const c = await loadCapture();
      c.datasets.products.status = 'complete';
      c.datasets.products.complete = true;
      c.datasets.products.stopReason = next.disabled ? 'next_disabled' : 'no_next_control';
      await saveCapture(c);
      return c.datasets.products;
    }

    const changed = await waitForTableChange(tabId, pageFingerprint, 15000);
    if (!changed?.rows?.length) {
      const c = await loadCapture();
      c.datasets.products.status = 'partial';
      c.datasets.products.stopReason = 'next_page_did_not_load';
      await saveCapture(c);
      return c.datasets.products;
    }
  }

  const c = await loadCapture();
  c.datasets.products.status = 'partial';
  c.datasets.products.stopReason = 'max_page_guard_reached';
  await saveCapture(c);
  return c.datasets.products;
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
  capture.crawl.attempted = capture.crawl.results.length;
  capture.crawl.succeeded = capture.crawl.results.filter(x => x.ok).length;
  await saveCapture(capture);
}

async function runAutoCrawl() {
  if (crawlControl.running) return { ok: false, error: '自動採集已經在執行中。' };
  const wing = await findExistingWingTab();
  const tab = wing || await getActiveTab();
  if (!String(tab.url || '').startsWith('https://wing.coupang.com/')) {
    return { ok: false, error: '請先開啟你已登入的 WING 後台分頁。' };
  }

  crawlControl = { running: true, stopRequested: false };
  await attachToTab(tab.id);

  const capture = await loadCapture();
  capture.crawl = {
    status: 'running',
    current: null,
    attempted: 0,
    succeeded: 0,
    total: AUTO_CRAWL_PLAN.length,
    startedAt: new Date().toISOString(),
    finishedAt: null,
    results: []
  };
  await saveCapture(capture);

  try {
    try { await takeSnapshot(tab.id, 'v17_initial'); } catch {}

    for (const step of AUTO_CRAWL_PLAN) {
      if (crawlControl.stopRequested) break;
      await setCrawlState({ current: step.label });
      const before = await loadCapture();
      const responseStart = before.responses.length;
      try {
        const navigation = await navigateToTarget(tab.id, step);
        await waitForPageStable(tab.id, 15000);
        await sleep(1000);
        const snapshot = await takeSnapshot(tab.id, `v17_${step.id}`);

        let dataset = null;
        if (step.id === 'products') dataset = await harvestAllProductPages(tab.id);

        const after = await loadCapture();
        await appendCrawlResult({
          id: step.id,
          label: step.label,
          ok: true,
          capturedAt: new Date().toISOString(),
          url: sanitizeUrl(snapshot.url || ''),
          title: snapshot.title || '',
          newResponses: Math.max(0, after.responses.length - responseStart),
          navigation,
          dataset
        });
      } catch (error) {
        const sig = await getPageSignature(tab.id);
        const after = await loadCapture();
        await appendCrawlResult({
          id: step.id,
          label: step.label,
          ok: false,
          capturedAt: new Date().toISOString(),
          url: sanitizeUrl(sig?.url || ''),
          title: sig?.title || '',
          newResponses: Math.max(0, after.responses.length - responseStart),
          error: String(error?.message || error)
        });
      }
      await sleep(500);
    }

    const finalCapture = await loadCapture();
    const stopped = crawlControl.stopRequested;
    const failed = finalCapture.crawl.results.filter(x => !x.ok).length;
    finalCapture.crawl.status = stopped ? 'stopped' : (failed ? 'completed_with_errors' : 'completed');
    finalCapture.crawl.current = null;
    finalCapture.crawl.finishedAt = new Date().toISOString();
    finalCapture.crawl.attempted = finalCapture.crawl.results.length;
    finalCapture.crawl.succeeded = finalCapture.crawl.results.filter(x => x.ok).length;
    await saveCapture(finalCapture);

    return {
      ok: true,
      stopped,
      attempted: finalCapture.crawl.attempted,
      succeeded: finalCapture.crawl.succeeded,
      total: finalCapture.crawl.total,
      responses: finalCapture.responses.length,
      snapshots: finalCapture.snapshots.length,
      products: finalCapture.datasets?.products || null
    };
  } catch (error) {
    await setCrawlState({
      status: 'failed',
      current: null,
      finishedAt: new Date().toISOString(),
      error: String(error?.message || error)
    });
    return { ok: false, error: String(error?.message || error) };
  } finally {
    crawlControl.running = false;
  }
}

async function exportCaptureData() {
  const capture = await loadCapture();
  const out = structuredClone(capture);
  const pageKeys = [];
  for (const ds of Object.values(capture.datasets || {})) {
    if (Array.isArray(ds?.pageKeys)) pageKeys.push(...ds.pageKeys);
  }
  if (pageKeys.length) {
    const pages = await chrome.storage.local.get(pageKeys);
    out.datasetPages = {};
    for (const key of pageKeys) out.datasetPages[key] = pages[key] || null;
  }
  return out;
}

async function clearAllData() {
  crawlControl.stopRequested = true;
  if (activeSession.attached && activeSession.tabId != null) {
    try { await chrome.debugger.detach({ tabId: activeSession.tabId }); } catch {}
  }
  const all = await chrome.storage.local.get(null);
  const keys = Object.keys(all).filter(k => k === STORAGE_KEY || k.startsWith(PAGE_KEY_PREFIX));
  if (keys.length) await chrome.storage.local.remove(keys);
  activeSession = { tabId: null, attached: false, startedAt: null, pending: new Map() };
  crawlControl = { running: false, stopRequested: false };
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  (async () => {
    switch (message?.type) {
      case 'focusExistingWing': {
        const tab = await findExistingWingTab();
        if (!tab) return { ok: false, error: '目前沒有找到已開啟的 WING 後台分頁。' };
        if (tab.windowId != null) await chrome.windows.update(tab.windowId, { focused: true });
        await chrome.tabs.update(tab.id, { active: true });
        return { ok: true, tabId: tab.id, url: tab.url };
      }
      case 'openBackend': {
        const wing = await findExistingWingTab();
        const tab = wing || await getActiveTab();
        await chrome.tabs.update(tab.id, { url: TARGET_URL, active: true });
        return { ok: true, tabId: tab.id, url: TARGET_URL };
      }
      case 'autoCrawl':
        return await runAutoCrawl();
      case 'stopAutoCrawl':
        crawlControl.stopRequested = true;
        await setCrawlState({ status: crawlControl.running ? 'stopping' : 'stopped' });
        return { ok: true };
      case 'getStatus': {
        const capture = await loadCapture();
        return {
          ok: true,
          attached: activeSession.attached,
          responses: capture.responses.length,
          snapshots: capture.snapshots.length,
          crawl: capture.crawl,
          products: capture.datasets?.products || null
        };
      }
      case 'exportData':
        return { ok: true, data: await exportCaptureData() };
      case 'clearData':
        await clearAllData();
        return { ok: true };
      default:
        return { ok: false, error: '未知指令。' };
    }
  })().then(sendResponse).catch(error => sendResponse({ ok: false, error: String(error?.message || error) }));
  return true;
});

globalThis.__TinySnowV17Test = {
  TARGET_URL,
  AUTO_CRAWL_PLAN,
  normalizeNavText,
  scoreLabel,
  isSensitiveEndpoint,
  isCoupangBusinessUrl,
  sanitizeUrl,
  sanitizeObject,
  sanitizeBody,
  rowFingerprint
};
