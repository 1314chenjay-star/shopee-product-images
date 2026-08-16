const assert = require('assert');

const noopListener = { addListener() {} };
global.chrome = {
  storage: { local: { get: async () => ({}), set: async () => {}, remove: async () => {} } },
  scripting: { executeScript: async () => [] },
  debugger: {
    attach: async () => {},
    detach: async () => {},
    sendCommand: async () => ({}),
    onEvent: noopListener,
    onDetach: noopListener
  },
  runtime: { onMessage: noopListener },
  tabs: { query: async () => [], get: async () => ({}), update: async () => ({}), reload: async () => {} },
  windows: { update: async () => ({}) }
};

require('../../coupang_browser_extension/background.js');
const t = global.__TinySnowV15Test;
assert(t, 'test helpers should be exposed');

assert.strictEqual(t.TARGET_URL, 'https://wing.coupang.com/tenants/sfl-portal/delivery/management');
assert.strictEqual(t.isCoupangBusinessUrl('https://wing.coupang.com/tenants/sfl-portal/delivery/management'), true);
assert.strictEqual(t.isCoupangBusinessUrl('https://xauth.coupang.com/auth/realms/seller'), false);
assert.strictEqual(t.isCoupangBusinessUrl('https://example.com/data'), false);

const cleaned = t.sanitizeUrl('https://wing.coupang.com/api/orders?token=abc&sellerId=123&session_id=xyz');
assert(cleaned.includes('sellerId=123'), 'business query value should be preserved');
assert(!cleaned.includes('token=abc'), 'token must be redacted');
assert(!cleaned.includes('session_id=xyz'), 'session id must be redacted');

const sanitized = t.sanitizeObject({
  sku: 'SKU-1',
  price: 199,
  password: 'secret',
  accessToken: 'token',
  buyerPhone: '0900000000',
  shippingAddress: 'private',
  nested: { inventory: 8 }
});
assert.strictEqual(sanitized.sku, 'SKU-1');
assert.strictEqual(sanitized.price, 199);
assert.strictEqual(sanitized.password, '[REDACTED_SECRET]');
assert.strictEqual(sanitized.accessToken, '[REDACTED_SECRET]');
assert.strictEqual(sanitized.buyerPhone, '[REDACTED_PII]');
assert.strictEqual(sanitized.shippingAddress, '[REDACTED_PII]');
assert.strictEqual(sanitized.nested.inventory, 8);

const body = t.sanitizeBody(JSON.stringify({ orderId: 'O1', email: 'a@example.com', stock: 4, refresh_token: 'bad' }), 'application/json');
const parsed = JSON.parse(body);
assert.strictEqual(parsed.orderId, 'O1');
assert.strictEqual(parsed.stock, 4);
assert.strictEqual(parsed.email, '[REDACTED_PII]');
assert.strictEqual(parsed.refresh_token, '[REDACTED_SECRET]');

console.log('ALL COUPANG EXISTING-BROWSER V1.5 UNIT TESTS PASSED');
