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
  tabs: { query: async () => [], get: async () => ({}), update: async () => ({}) },
  windows: { update: async () => ({}) }
};

require('../../coupang_browser_extension/background.js');
const t = global.__TinySnowV17Test;
assert(t, 'V1.7 test helpers should be exposed');

assert.strictEqual(t.TARGET_URL, 'https://wing.coupang.com/tenants/sfl-portal/delivery/management');
assert.strictEqual(Array.isArray(t.AUTO_CRAWL_PLAN), true);
assert.strictEqual(t.AUTO_CRAWL_PLAN.length, 6);
assert.deepStrictEqual(t.AUTO_CRAWL_PLAN.map(x => x.id), ['products','orders','returns','settlement','growth','insights']);
assert(t.AUTO_CRAWL_PLAN[0].labels.some(x => x.includes('商品')));
assert(t.AUTO_CRAWL_PLAN[1].labels.includes('我的订单'));
assert(t.AUTO_CRAWL_PLAN[1].labels.includes('我的訂單'));
assert(t.AUTO_CRAWL_PLAN[2].labels.some(x => x.includes('退货')));
assert(t.AUTO_CRAWL_PLAN[5].labels.includes('商业洞察'));

assert.strictEqual(t.normalizeNavText(' 訂購／配送 '), '訂購/配送');
assert(t.scoreLabel('我的订单', ['我的订单', '我的訂單']) > 0);
assert(t.scoreLabel('商业洞察', ['商業洞察', '商业洞察']) > 0);
assert.strictEqual(t.scoreLabel('完全不同', ['商品列表']), -1);

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

assert.strictEqual(t.rowFingerprint(['A', 1]), '["A",1]');
assert.strictEqual(t.rowFingerprint(['A', 1]), t.rowFingerprint(['A', 1]));
assert.notStrictEqual(t.rowFingerprint(['A', 1]), t.rowFingerprint(['B', 1]));

console.log('ALL COUPANG EXISTING-BROWSER V1.7 UNIT TESTS PASSED');
