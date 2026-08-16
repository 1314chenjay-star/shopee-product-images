const TARGET_URL = 'https://wing.coupang.com/tenants/sfl-portal/delivery/management';
const STORAGE_KEY = 'tinysnowCoupangCaptureV15';
const MAX_BODY_CHARS = 4_000_000;
const MAX_RECORDS = 500;

let activeSession = {
  tabId: null,
  attached: false,
  startedAt: null,
  pending: new Map()
};

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
    version: '1.5.0',
    createdAt: new Date().toISOString(),
    startedAt: null,
    stoppedAt: null,
    sourceTab: null,
    snapshots: [],
    responses: [],
    notes: [
      'No passwords, cookies, Authorization headers, access tokens, refresh tokens or login credentials are intentionally exported.',
      'Buyer contact/address fields are redacted because they are not required for store-operation analysis.'
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
    capture.notes.push('Response list reached the safety cap; oldest captured responses were dropped.');
  }
  await saveCapture(capture);
}

async function takeSnapshot(tabId) {
  const injection = await chrome.scripting.executeScript({
    target: { tabId },
    func: () => {
      const norm = s => String(s || '').replace(/\r/g, '').trim();
      const tables = [...document.querySelectorAll('table')].map((table, index) => ({
        index,
        headers: [...table.querySelectorAll('thead th')].map(x => norm(x.innerText)),
        rows: [...table.querySelectorAll('tbody tr')].slice(0, 500).map(tr =>
          [...tr.querySelectorAll('th,td')].map(td => norm(td.innerText))
        )
      }));
      const grids = [...document.querySelectorAll('[role="grid"], [role="table"]')].slice(0, 30).map((el, index) => ({
        index,
        role: el.getAttribute('role'),
        text: norm(el.innerText).slice(0, 300000)
      }));
      return {
        capturedAt: new Date().toISOString(),
        title: document.title,
        url: location.href,
        bodyText: norm(document.body ? document.body.innerText : '').slice(0, 1_500_000),
        tables,
        grids
      };
    }
  });
  const value = injection && injection[0] ? injection[0].result : null;
  if (!value) throw new Error('無法讀取目前分頁內容。');
  const capture = await loadCapture();
  capture.snapshots.push(value);
  if (capture.snapshots.length > 30) capture.snapshots = capture.snapshots.slice(-30);
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
  capture.startedAt = activeSession.startedAt;
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
        await takeSnapshot(tab.id);
        return { ok: true, tabId: tab.id };
      }
      case 'snapshot': {
        const wing = await findExistingWingTab();
        const tab = wing || await getActiveTab();
        const snapshot = await takeSnapshot(tab.id);
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
        if (activeSession.attached && activeSession.tabId != null) {
          try { await takeSnapshot(activeSession.tabId); } catch {}
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
          startedAt: capture.startedAt
        };
      }
      case 'exportData': {
        const capture = await loadCapture();
        return { ok: true, data: capture };
      }
      case 'clearData': {
        if (activeSession.attached && activeSession.tabId != null) {
          try { await chrome.debugger.detach({ tabId: activeSession.tabId }); } catch {}
        }
        await chrome.storage.local.remove(STORAGE_KEY);
        activeSession = { tabId: null, attached: false, startedAt: null, pending: new Map() };
        return { ok: true };
      }
      default:
        return { ok: false, error: '未知指令。' };
    }
  })().then(sendResponse).catch(error => sendResponse({ ok: false, error: String(error && error.message || error) }));
  return true;
});

globalThis.__TinySnowV15Test = {
  TARGET_URL,
  isSensitiveEndpoint,
  isCoupangBusinessUrl,
  sanitizeUrl,
  sanitizeObject,
  sanitizeBody
};
