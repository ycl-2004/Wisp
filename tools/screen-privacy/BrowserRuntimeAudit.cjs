// Requires Playwright with its Chromium binary; uses only synthetic canvas pixels.
const {chromium}=require('playwright');
const {pathToFileURL}=require('node:url');
const {resolve}=require('node:path');
(async()=>{
 const browser=await chromium.launch({headless:true});
 try {
 const page=await browser.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.addInitScript(()=>{
  Object.defineProperty(navigator,'mediaDevices',{value:{getDisplayMedia:async()=>{
   const canvas=document.createElement('canvas');canvas.width=320;canvas.height=180;
   const ctx=canvas.getContext('2d');const stream=canvas.captureStream(0);const track=stream.getVideoTracks()[0];
   track.getSettings=()=>({displaySurface:'monitor'});
   window.testTrack=track;window.pushFrame=()=>{ctx.fillStyle=`hsl(${Math.random()*360} 100% 50%)`;ctx.fillRect(0,0,320,180);track.requestFrame()};
   window.testCanvas=canvas;return stream;
  }}});
 });
 await page.goto(pathToFileURL(resolve(__dirname, 'browser.html')).href);
 await page.click('#start');
 await page.waitForFunction(()=>typeof window.pushFrame==='function');
 await page.evaluate(()=>window.pushFrame());
 await page.waitForFunction(()=>document.querySelector('#health').textContent.startsWith('已观察到'));
 const fresh=await page.locator('#health').textContent();
 await page.waitForFunction(()=>document.querySelector('#health').textContent.includes('超过 3 秒'),{},{timeout:7000});
 const stale=await page.locator('#health').textContent();
 await page.evaluate(()=>window.pushFrame());
 await page.waitForFunction(()=>document.querySelector('#health').textContent.startsWith('已观察到'));
 const recovered=await page.locator('#health').textContent();
 await page.evaluate(()=>{window.testTrack.stop();window.testTrack.dispatchEvent(new Event('ended'))});
 await page.waitForFunction(()=>document.querySelector('#health').textContent.includes('意外中断'));
 const ended=await page.locator('#health').textContent();
 if(errors.length)throw new Error(errors.join('\n'));
 console.log(JSON.stringify({scope:'Real headless Chromium rendering a local synthetic CanvasCaptureMediaStream; ended event explicitly dispatched, not OS permission revocation',browser:browser.version(),fresh,stale,recovered,ended,pageErrors:errors,pass:true},null,2));
 }finally{await browser.close()}
})().catch(e=>{console.error(e);process.exitCode=1});
