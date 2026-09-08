// Deterministic event/clock tests of the actual browser.html script.
// No browser, OS permission changes, model CLI or external monitor is involved.
const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync('tools/screen-privacy/browser.html', 'utf8').match(/<script>([\s\S]*?)<\/script>/)[1];
function fixture(options = {}) {
  const elements = Object.fromEntries(['start','stop','preview','status','health'].map(id => [id, {textContent:'',disabled:false,srcObject:null}]));
  const events = {}, timers = new Map(), callbacks = new Map();
  let now = 0, nextID = 0, resolve;
  const track = {readyState:'live', muted:!!options.muted, stop(){this.readyState='ended'}, getSettings(){return {displaySurface:options.surface || 'monitor'}}};
  const stream = {getTracks:()=>[track],getVideoTracks:()=>[track]};
  if (!options.unsupported) {
    elements.preview.requestVideoFrameCallback = f => { callbacks.set(++nextID, f); return nextID; };
    elements.preview.cancelVideoFrameCallback = id => callbacks.delete(id);
  }
  const document = {querySelector:s=>elements[s.slice(1)],hasFocus:()=>true,visibilityState:'visible',addEventListener(n,f){events[n]=f}};
  const context = {
    window:{isSecureContext:true,addEventListener(n,f){events[n]=f}}, document,
    navigator:{userAgent:'synthetic audit',userActivation:{isActive:true},mediaDevices:{getDisplayMedia:async()=>{
      if(options.reject)throw Object.assign(new Error('injected failure'),{name:options.reject});
      if(options.pending)await new Promise(r=>resolve=r);
      return stream;
    }}}, Date, performance:{now:()=>now},
    setInterval:f=>{timers.set(++nextID,f);return nextID},clearInterval:id=>timers.delete(id)
  };
  vm.runInNewContext(source,context);
  return {
    elements,track,events,timers,callbacks,document,
    start:()=>elements.start.onclick({isTrusted:true}),stop:()=>elements.stop.onclick(),resolve:()=>resolve(),
    tick(ms){now+=ms;for(const timer of [...timers.values()])timer()},
    frame(){const pending=[...callbacks.values()];callbacks.clear();for(const f of pending)f(now,{presentedFrames:1})},
    log:()=>elements.status.textContent,health:()=>elements.health.textContent
  };
}
(async()=>{
 const rows=[];
 async function check(name, test, options={}) {
   const f=fixture(options);
   try {await f.start();await test(f);rows.push({name,pass:true,health:f.health()})}
   catch(e){rows.push({name,pass:false,error:e.message,health:f.health()})}
 }
 const warning=f=>assert.match(f.health(),/报警/);
 const waiting=f=>assert.match(f.health(),/待确认/);
 const fresh=f=>assert.match(f.health(),/^已观察到预览帧更新/);
 await check('capture rejection is explicit and retry is enabled',f=>{warning(f);assert.match(f.health(),/NotAllowedError/);assert.equal(f.elements.start.disabled,false)}, {reject:'NotAllowedError'});
 await check('no success before first frame',waiting);
 await check('first frame observed',f=>{f.frame();fresh(f)});
 await check('startup without frames warns after deadline',f=>{f.tick(3000);warning(f)});
 await check('frame updates cease: alarm replaces fresh status',f=>{f.frame();f.tick(3000);warning(f)});
 await check('fresh frames recover missing-frame warning',f=>{f.tick(3000);f.frame();fresh(f)});
 await check('muted track warns immediately',f=>{f.track.muted=true;f.track.onmute();warning(f)});
 await check('already muted capture warns immediately',warning,{muted:true});
 await check('unmute waits for a fresh frame',f=>{f.frame();f.track.muted=true;f.track.onmute();f.track.muted=false;f.track.onunmute();waiting(f);f.frame();fresh(f)});
 await check('frames while muted cannot clear warning',f=>{f.track.muted=true;f.track.onmute();f.frame();warning(f)});
 await check('unexpected end alarms and clears resources',f=>{f.track.readyState='ended';f.track.onended();warning(f);assert.equal(f.elements.preview.srcObject,null);assert.equal(f.timers.size,0);assert.equal(f.callbacks.size,0)});
 await check('watchdog also detects ended without event',f=>{f.track.readyState='ended';f.tick(500);warning(f)});
 await check('explicit stop is not an alarm',f=>{f.stop();assert.match(f.health(),/主动停止/);assert.doesNotMatch(f.health(),/报警/);assert.equal(f.track.readyState,'ended');assert.equal(f.callbacks.size,0);assert.equal(f.timers.size,0)});
 await check('blur and focus preserve fresh status, never classify violation',f=>{f.frame();f.events.blur();f.events.focus();fresh(f);assert.match(f.log(),/window blur/);assert.doesNotMatch(f.log(),/违规/)});
 await check('background is unknown; return requires new frame',f=>{f.frame();f.document.visibilityState='hidden';f.events.visibilitychange();waiting(f);f.tick(10000);waiting(f);f.document.visibilityState='visible';f.events.visibilitychange();waiting(f);f.frame();fresh(f)});
 await check('unsupported frame API cannot report healthy',waiting,{unsupported:true});
 await check('wrong capture surface is invalid and released',f=>{assert.match(f.health(),/无效测试/);assert.equal(f.track.readyState,'ended');assert.equal(f.elements.preview.srcObject,null)}, {surface:'window'});
 await check('queued stale callbacks cannot revive stopped session',f=>{const cb=[...f.callbacks.values()][0],ended=f.track.onended;f.stop();cb();ended();assert.match(f.health(),/主动停止/);assert.equal(f.callbacks.size,0)});
 await check('pagehide cleans up capture',f=>{f.events.pagehide();assert.equal(f.track.readyState,'ended');assert.equal(f.timers.size,0);assert.equal(f.callbacks.size,0)});
 await check('repeated warning does not flood log',f=>{f.tick(3000);const log=f.log();f.tick(5000);assert.equal(f.log(),log)});
 // Picker resolution after stop must not resurrect the capture.
 for (const action of ['stop','pagehide']) {
   const f=fixture({pending:true});
   try {const pending=f.start();action==='stop'?f.stop():f.events.pagehide();f.resolve();await pending;assert.equal(f.elements.preview.srcObject,null);assert.equal(f.track.readyState,'ended');assert.equal(f.timers.size,0);rows.push({name:`pending picker after ${action} is discarded`,pass:true})}
   catch(e){rows.push({name:`pending picker after ${action} is discarded`,pass:false,error:e.message})}
 }
 const report={scope:'synthetic DOM, media events and monotonic clock; not real browser/OS revocation or external monitor',results:rows,passed:rows.filter(r=>r.pass).length,failed:rows.filter(r=>!r.pass).length};
 console.log(JSON.stringify(report,null,2));process.exitCode=report.failed?1:0;
})().catch(e=>{console.error(e);process.exitCode=2});
