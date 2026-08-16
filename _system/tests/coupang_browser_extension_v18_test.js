const assert=require('assert');
const listeners={addListener(){}};
global.chrome={
  storage:{local:{get:async()=>({}),set:async()=>{},clear:async()=>{},remove:async()=>{}}},
  debugger:{attach:async()=>{},detach:async()=>{},sendCommand:async()=>({}),onEvent:listeners,onDetach:listeners},
  tabs:{query:async()=>[],get:async()=>({}),create:async()=>({id:1,url:'https://wing.coupang.com/'}),update:async()=>({})},
  windows:{update:async()=>({})},
  scripting:{executeScript:async()=>[]},
  runtime:{onMessage:listeners,onStartup:listeners,onInstalled:listeners},
  alarms:{get:async()=>null,create:async()=>{},clear:async()=>{},onAlarm:listeners}
};
require('../../coupang_browser_extension/background_v18.js');
const t=global.__TinySnowV18Test;
assert(t,'V1.8 helpers missing');
assert(t.NAV_GROUPS.length>=8,'V1.8 should cover more than six relevant data groups');
const products=t.NAV_GROUPS.find(x=>x.id==='products');
const price=t.NAV_GROUPS.find(x=>x.id==='price');
assert.strictEqual(t.isRelevantLabel('商品查询/修改',products),true);
assert.strictEqual(t.isRelevantLabel('新增商品',products),false);
assert.strictEqual(t.isRelevantLabel('价格竞争力分析',price),true);
assert.strictEqual(t.isRelevantLabel('新增价格活动',price),false);
let c=t.productCompletion(50,9854,'no_next_control',50,50);
assert.strictEqual(c.complete,false,'50/9854 must never be complete');
assert.strictEqual(c.status,'partial');
c=t.productCompletion(9854,9854,'expected_total_reached',50,50);
assert.strictEqual(c.complete,true);
c=t.productCompletion(48,null,'no_next_control',48,50);
assert.strictEqual(c.complete,true);
assert.strictEqual(t.QUICK_INTERVAL_MINUTES,360);
assert.strictEqual(t.isBusinessUrl('https://wing.coupang.com/a'),true);
assert.strictEqual(t.isBusinessUrl('https://xauth.coupang.com/auth/a'),false);
const cleaned=t.sanitizeUrl('https://wing.coupang.com/api?seller=1&token=abc');
assert(cleaned.includes('seller=1'));
assert(!cleaned.includes('token=abc'));
const safe=t.sanitizeObject({sku:'S1',password:'bad',buyerPhone:'0900'});
assert.strictEqual(safe.sku,'S1');
assert.strictEqual(safe.password,'[REDACTED_SECRET]');
assert.strictEqual(safe.buyerPhone,'[REDACTED_PII]');
console.log('ALL COUPANG V1.8 UNIT TESTS PASSED');
