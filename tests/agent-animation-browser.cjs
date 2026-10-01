// Requires a running Emacs with Excalimacs and an installed Playwright Chromium.
// PLAYWRIGHT_MODULE can point to an existing Playwright installation.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { execFileSync, spawn } = require('node:child_process');
const assert = require('node:assert/strict');
const { resolve, join } = require('node:path');
const { mkdtempSync } = require('node:fs');
const { tmpdir } = require('node:os');
const ROOT=resolve(__dirname, '..');
const scratch=mkdtempSync(join(tmpdir(), 'excalimacs-animation-'));
const DRAW=join(scratch, 'drawing.excalidraw.png');
const emacs=(code)=>execFileSync('emacsclient',['--eval',code],{encoding:'utf8'}).trim();
const wait=(ms)=>new Promise(r=>setTimeout(r,ms));
const cli=(op,payload,immediate=false)=>new Promise((resolve,reject)=>{
 const p=spawn(ROOT+'/bin/excalimacs',[...(immediate?['--immediate']:[]),op,DRAW]); let out='',err='';
 p.stdout.on('data',d=>out+=d);p.stderr.on('data',d=>err+=d);p.on('close',code=>code?reject(Error(out+err)):resolve(JSON.parse(out)));p.stdin.end(JSON.stringify(payload));
});
(async()=>{
 const source=JSON.parse(emacs(`(let ((browse-url-browser-function (lambda (url &rest _) url))) (excalimacs-open "${DRAW}"))`));
 const target=new URL(source).origin;
 const { createServer }=await import(ROOT+'/node_modules/vite/dist/node/index.js');
 const server=await createServer({root:ROOT,server:{port:5199,host:'127.0.0.1',proxy:{'/api':{target,ws:true,changeOrigin:true,configure(proxy){
  proxy.on('proxyReq',req=>req.setHeader('Origin',target));proxy.on('proxyReqWs',req=>req.setHeader('Origin',target));
 }}}}});await server.listen();
 const browser=await chromium.launch();let errors=[];
 try {
  const pages=[];
  for(let i=0;i<2;i++){
   const page=await browser.newPage({viewport:{width:1400,height:900}});page.on('pageerror',e=>errors.push(e.message));
   await page.route('**/src/main.jsx',async route=>{
    const res=await route.fetch();let body=await res.text();
    body=body.replace('const animator = createAgentAnimator(', 'const animator = window.__animator = createAgentAnimator(');
    body=body.replace('onExcalidrawAPI: setExcalidrawAPI','onExcalidrawAPI: (api) => { window.__api = api; setExcalidrawAPI(api); }');
    await route.fulfill({response:res,body});
   });
   const url=new URL(source);url.host=new URL(server.resolvedUrls.local[0]).host;await page.goto(url.href);
   await page.waitForFunction(()=>window.__api && window.__animator);await wait(1200);pages.push(page);
  }
  const [a,b]=pages;
  // Instrument transient rendering independently of actual scene data.
  for(const page of pages) await page.evaluate(()=>{
   window.__overrides=[];const original=window.__api.setElementRenderOverrides;
   window.__api.setElementRenderOverrides=(map)=>{window.__overrides.push({time:performance.now(),ids:[...(map?.keys()||[])]});original(map);};
  });
  const elements=Array.from({length:8},(_,i)=>({id:`test-box-${Date.now()}-${i}`,type:'rectangle',x:100+i*140,y:150,width:110,height:70,label:{text:`Box ${i}`}}));
  for(const page of pages) await page.evaluate(id=>{
   window.__arrival=null;
   window.__api.onChange(elements=>{
    if(window.__arrival===null && elements.some(element=>element.id===id)) window.__arrival=Date.now();
   });
  },elements[0].id);
  const start=Date.now();await cli('add',elements);const elapsed=Date.now()-start;
  const arrivals=await Promise.all(pages.map(page=>page.evaluate(()=>window.__arrival)));
  assert.ok(arrivals[1]-arrivals[0]<500,'peer synchronization does not wait for presentation');
  console.log('bulk change reached peer in',arrivals[1]-arrivals[0],'ms');
  for(const page of pages){
   assert.equal(await page.evaluate(ids=>window.__api.getSceneElements().filter(e=>ids.includes(e.id)).length,elements.map(e=>e.id)),8);
   assert.ok(await page.evaluate(()=>window.__overrides.some(o=>o.ids.length>=8)),'batch hidden for staged reveal');
  }
  for(const page of pages) assert.equal(await page.evaluate(()=>window.__overrides.at(-1).ids.length),0,'CLI returns after the drawing finishes');
  console.log('stage1: full scene in both tabs; CLI returned after drawing in',elapsed,'ms');
  const cancelled=cli('add',[{id:'test-cancel-'+Date.now(),type:'rectangle',x:300,y:400,width:400,height:200,label:{text:'Cancelled by a click'}}]);
  await a.waitForFunction(()=>window.__overrides.at(-1)?.ids.length>0);
  await a.mouse.click(1300,850);assert.equal(await a.evaluate(()=>window.__overrides.at(-1).ids.length),0,'interaction cancels presentation');
  // The reply still waits for the save, which is slow in a headless dev build.
  const cancelStart=Date.now();assert.ok((await cancelled).result,'cancelled drawing still applies');assert.ok(Date.now()-cancelStart<10000,'cancelled drawing releases the CLI');
  for(const page of pages)await page.evaluate(()=>window.__overrides=[]);
  await cli('add',[{id:'test-immediate-'+Date.now(),type:'ellipse',x:200,y:400,width:120,height:80}],true);await wait(200);
  for(const page of pages) assert.ok(await page.evaluate(()=>window.__overrides.every(o=>!o.ids.length)),'--immediate never hides');
  console.log('cancellation and --immediate passed');
  const root='animated-'+Date.now();
  const batch=[
   {id:root+'-box',type:'rectangle',x:150,y:570,width:190,height:100,label:{text:'Growing box'}},
   {id:root+'-arrow',type:'arrow',x:390,y:620,points:[[0,0],[100,-40],[230,0]],label:{text:'Extending arrow'}},
   {id:root+'-text',type:'text',x:730,y:595,text:'Streaming text appears character by character.'}
  ];
  // Record each overlay frame's size, to check shapes grow and arrows extend like a drag.
  await a.evaluate(()=>{window.__sizes={};new MutationObserver(()=>{for(const node of document.querySelectorAll('.agent-animation-element')){const svg=node.querySelector('svg');if(svg)(window.__sizes[node.dataset.elementId]??=[]).push([+svg.getAttribute('width'),+svg.getAttribute('height')]);}}).observe(document.body,{childList:true,subtree:true});});
  const writing=cli('add',batch);
  await a.waitForSelector('.agent-animation-element');
  await wait(180);await a.screenshot({path:'/tmp/excalimacs-animation-growing.png'});
  await a.waitForFunction(id=>!!document.querySelector(`[data-element-id="${id}"]`),root+'-arrow');
  await wait(150);await a.screenshot({path:'/tmp/excalimacs-animation-arrow.png'});
  await a.waitForFunction(id=>{const n=document.querySelector(`[data-element-id="${id}"]`);const t=n?.textContent||'';window.__sampleText=t; return t.includes('Streaming') && !t.includes('character by character.');},root+'-text');
  await a.screenshot({path:'/tmp/excalimacs-animation-text.png'});
  await writing;
  const texts=await a.evaluate(()=>window.__sampleText);
  assert.ok(texts.length>0 && texts.length<batch[2].text.length,'text is partially streamed');
  const sizes=await a.evaluate(()=>window.__sizes);
  for(const id of [root+'-box',root+'-arrow']){
   const widths=sizes[id].map(([width])=>width);
   assert.ok(widths.length>3 && widths[0]<widths.at(-1)/2,`${id} starts small and grows`);
   assert.ok(widths.every((width,index)=>!index||width>=widths[index-1]-1),`${id} never shrinks while drawn`);
  }
  await a.mouse.click(1300,850);
  // Human edit changes an already committed shape while another tab still presents it.
  const shape=await a.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id),root+'-box');
  await a.evaluate(({shape})=>window.__api.updateScene({elements:window.__api.getSceneElementsIncludingDeleted().map(e=>e.id===shape.id?{...e,x:e.x+30,version:e.version+1,versionNonce:123456}:e)}),{shape});
  await b.waitForFunction(id=>window.__api.getSceneElements().find(e=>e.id===id)?.x===180,root+'-box',{timeout:1500});
  console.log('growth, arrow reveal, text streaming, and concurrent human edit passed');

  await b.emulateMedia({reducedMotion:'reduce'});
  await b.evaluate(()=>window.__overrides=[]);
  const scene=(await cli('scene')).result;
  const target=scene.find(e=>e.id===root+'-box');
  const updating=cli('update',[{id:target.id,version:target.version,text:'Updated'}]);
  await a.waitForFunction(()=>document.querySelector('.agent-animation-element text')?.textContent.length>0);
  await a.screenshot({path:'/tmp/excalimacs-animation-label.png'});
  await updating;
  await b.waitForFunction(id=>window.__api.getSceneElements().some(e=>e.type==='text'&&e.containerId===id&&e.originalText==='Updated'),target.id);
  assert.ok(await b.evaluate(()=>window.__overrides.every(o=>!o.ids.length)),'reduced motion skips animation');
  console.log('label update and reduced-motion preference passed');
  assert.deepEqual(errors,[]);console.log('no browser errors');
 }finally{await browser.close();await server.close();execFileSync('trash',[scratch]);}
})().catch(e=>{console.error(e);process.exitCode=1;});
