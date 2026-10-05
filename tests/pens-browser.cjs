// Requires running Emacs and Playwright; supports PLAYWRIGHT_MODULE and CHROMIUM_PATH.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const {execFileSync}=require('node:child_process');
const assert=require('node:assert/strict');
const root=require('node:path').resolve(__dirname, '..');
const emacs=code=>execFileSync('emacsclient',['-e',code],{encoding:'utf8'}).trim();
(async()=>{
// A fixed-pressure taper should converge linearly to a needle-like tip.
const {strokeOutline,outlineElement,resizePen}=await import(root+'/plugins/pens/strokes.js');
const outline=strokeOutline(Array.from({length:41},(_,i)=>[i*10,0]),'tapered',
 {width:2,thinning:1,smoothing:0.5,streamline:0.5});
const spanAt=x=>{
 const crossings=[];
 for(let i=0;i<outline.length;i++){
  const a=outline[i],b=outline[(i+1)%outline.length];
  if((a[0]<x&&b[0]>=x)||(b[0]<x&&a[0]>=x))
   crossings.push(a[1]+(x-a[0])/(b[0]-a[0])*(b[1]-a[1]));
 }
 return Math.max(...crossings)-Math.min(...crossings);
};
assert.ok(spanAt(390)<0.6,'taper narrows linearly near the end');
assert.ok(spanAt(399)<0.1,'tip is needle-like rather than rounded');
// A threefold resize preserves marker thickness while lengthening its path.
const marker={preset:'highlighter',settings:{width:2,thinning:1,smoothing:0.5,streamline:0.5},
 points:Array.from({length:41},(_,i)=>[i*10,0]),pressures:Array(41).fill(1),
 simulatePressure:false,color:'#ffaa00',opacity:30};
const original=outlineElement(strokeOutline(marker.points,marker.preset,marker.settings),marker);
const scaled={...original,width:original.width*3,height:original.height*3,
 points:original.points.map(p=>p.map(v=>v*3))};
const rebuilt=resizePen(scaled,original);
assert.ok(Math.abs(rebuilt.height-original.height)<0.01,'resizing preserves marker thickness');
assert.ok(rebuilt.width>original.width*2.9,'resizing lengthens the stroke');
const drawing='/tmp/excalimacs-pens-'+Date.now()+'.excalidraw.png';
const previous=emacs('(progn (setq excalimacs-test-previous-plugins excalimacs-plugins) (setq excalimacs-plugins (quote (pens))))');
const source=JSON.parse(emacs(`(let ((browse-url-browser-function (lambda (url &rest _) url))) (excalimacs-open "${drawing}"))`));
const target=new URL(source).origin;
const prefsPath=JSON.parse(emacs('(expand-file-name "plugin-settings.json" excalimacs-library-directory)'));
const fs=require('node:fs');
const previousPrefs=fs.existsSync(prefsPath)?fs.readFileSync(prefsPath):null;
// Isolate settings so defaults and persistence can be checked without changing user presets.
emacs('(when (file-exists-p (expand-file-name "plugin-settings.json" excalimacs-library-directory)) (rename-file (expand-file-name "plugin-settings.json" excalimacs-library-directory) (expand-file-name "plugin-settings.pens-test-backup" excalimacs-library-directory) t))');
const {createServer}=await import(root+'/node_modules/vite/dist/node/index.js');
const server=await createServer({root,server:{port:5198,host:'127.0.0.1',proxy:{'/api':{target,changeOrigin:true,configure(p){p.on('proxyReq',r=>r.setHeader('Origin',target));}}}}});await server.listen();
const browser=await chromium.launch(process.env.CHROMIUM_PATH ? {executablePath:process.env.CHROMIUM_PATH} : {});
try {
const page=await browser.newPage({viewport:{width:1400,height:900}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
await page.route('**/src/main.jsx',async route=>{const r=await route.fetch();let body=await r.text();body=body.replace('onExcalidrawAPI: setExcalidrawAPI','onExcalidrawAPI: (api) => { window.__api = api; window.__waitForPenSettings = () => pluginSaveRef.current; setExcalidrawAPI(api); }');await route.fulfill({response:r,body});});
const url=new URL(source);url.host=new URL(server.resolvedUrls.local[0]).host;await page.goto(url.href);await page.waitForFunction(()=>window.__api);await page.getByRole('toolbar',{name:'Pens'}).waitFor();
assert.equal(await page.locator('.excalidraw-ui-top-right .pens-plugin').count(),0);
const draw=async(label,y,custom=false)=>{
  await page.getByRole('button',{name:label,exact:true}).click();
  const before=await page.evaluate(()=>window.__api.getSceneElements().length);
  await page.mouse.move(400,y);await page.mouse.down();
  await page.mouse.move(500,y,{steps:8});
  await page.mouse.move(600,y-45,{steps:8});
  if(custom){
    assert.ok(await page.locator('.pen-preview path').getAttribute('d'),'visible ink before release');
    assert.equal(await page.evaluate(()=>window.__api.getSceneElements().length),before,'preview is transient');
  }
  await page.mouse.move(700,y-140,{steps:8});
  await page.mouse.move(800,y-190,{steps:8});
  if(custom) await page.screenshot({path:'/tmp/excalimacs-pens-live-'+label.replaceAll(' ','-')+'.png'});
  await page.mouse.up();await page.waitForTimeout(150);
  if(custom) assert.equal(await page.locator('.pen-preview path').getAttribute('d'),null);
  return page.evaluate(()=>window.__api.getSceneElements()[0]);
};
const normal=await draw('Normal',300);assert.equal(normal.type,'freedraw');assert.equal(normal.opacity,100);
await draw('Highlighter',400,true);
let scene=await page.evaluate(()=>window.__api.getSceneElements());const highlight=scene[0];
assert.equal(highlight.opacity,30);assert.equal(highlight.type,'line');assert.equal(highlight.customData.excalimacsPen.preset,'highlighter');
const tapered=await draw('Thick → thin',500,true);
assert.equal(tapered.type,'line');assert.equal(tapered.customData.excalimacsPen.preset,'tapered');
assert.deepEqual(tapered.points[0],tapered.points.at(-1));
assert.equal(tapered.strokeWidth,0);assert.equal(tapered.fillStyle,'solid');
assert.equal(tapered.backgroundColor,'#CECDCC');assert.equal(tapered.opacity,100);
assert.ok(tapered.height < 210,'default tapered stroke stays narrow');
assert.equal(await page.evaluate(()=>window.__api.getSceneElements()[0].id),tapered.id,'tapered stroke goes behind existing elements');
await page.screenshot({path:'/tmp/excalimacs-pens-completed.png'});
await page.keyboard.press('Meta+z');await page.waitForTimeout(200);
assert.equal(await page.evaluate(()=>window.__api.getSceneElements().length),2);
await page.keyboard.press('Meta+Shift+z');await page.waitForTimeout(200);
assert.equal(await page.evaluate(()=>window.__api.getSceneElements()[0].customData.excalimacsPen.preset),'tapered');
// A cancelled gesture must not leave an element or preview behind.
await page.mouse.move(400,600);await page.mouse.down();await page.mouse.move(600,620,{steps:10});
await page.keyboard.press('Escape');await page.mouse.up();await page.waitForTimeout(150);
assert.equal(await page.evaluate(()=>window.__api.getSceneElements().length),3);
assert.equal(await page.locator('.pen-preview path').getAttribute('d'),null);
await page.keyboard.press('p');
await page.getByRole('toolbar',{name:'Pens'}).waitFor();
// Native stroke controls update custom pens, without a duplicate settings UI.
assert.equal(await page.locator('.selected-shape-actions-container .pens-plugin').count(),1);
await page.getByTestId('strokeWidth-thin').locator('..').click();
await page.getByTestId('opacity').fill('60');
await page.locator('input[name="strokeOptions.variability"]').nth(1).locator('..').click();
await page.evaluate(()=>window.__api.updateScene({appState:{currentItemStrokeColor:'#6688aa'}}));
await page.waitForFunction(()=>window.__api.getAppState().currentItemOpacity===60);
await page.getByRole('button',{name:'Highlighter',exact:true}).click();
await page.getByRole('button',{name:'Thick → thin',exact:true}).click();
const penStyle=()=>page.evaluate(()=>{
 const state=window.__api.getAppState();
 return [state.currentItemStrokeColor,state.currentItemStrokeWidthKey,state.currentItemOpacity,state.currentItemStrokeVariability];
});
assert.deepEqual(await penStyle(),['#6688aa','thin',60,'variable']);
for(const preset of ['Highlighter','Thick → thin']){
 await page.getByRole('button',{name:preset,exact:true}).click();
 await page.keyboard.press('r');
 await page.waitForFunction(()=>window.__api.getAppState().activeTool.type==='rectangle');
 await page.waitForFunction(color=>window.__api.getAppState().currentItemStrokeColor===color,normal.strokeColor);
 assert.equal(await page.evaluate(()=>window.__api.getAppState().currentItemOpacity),normal.opacity);
 await page.keyboard.press('p');await page.getByRole('toolbar',{name:'Pens'}).waitFor();
 assert.equal(await page.getByRole('button',{name:preset,exact:true}).getAttribute('aria-pressed'),'true');
}
assert.deepEqual(await penStyle(),['#6688aa','thin',60,'variable'],'custom pen style restored on return');
await page.getByRole('button',{name:'Normal',exact:true}).click();
await page.waitForFunction(color=>window.__api.getAppState().currentItemStrokeColor===color,normal.strokeColor);
await page.getByRole('button',{name:'Thick → thin',exact:true}).click();
await page.waitForFunction(async()=>{
 const p=new URL(location.href);const r=await fetch('/api/plugins',{headers:{'X-Editor-Token':p.searchParams.get('token')}});
 const data=await r.json();return data.settings.pens?.pens?.tapered?.opacity===60;
});
await page.evaluate(()=>window.__waitForPenSettings());await page.keyboard.press('Meta+s');await page.waitForFunction(()=>!document.title.startsWith('●'));
await page.reload();await page.waitForFunction(()=>window.__api?.getSceneElements().length===3);
assert.equal(await page.evaluate(()=>window.__api.getAppState().activeTool.type),'freedraw');
assert.equal(await page.getByRole('button',{name:'Thick → thin',exact:true}).getAttribute('aria-pressed'),'true');
assert.deepEqual(await penStyle(),['#6688aa','thin',60,'variable']);
const customized=await draw('Thick → thin',650,true);
assert.equal(customized.backgroundColor,'#6688aa');assert.equal(customized.opacity,60);
await page.keyboard.press('Meta+z');await page.waitForTimeout(150);
assert.equal(await page.evaluate(()=>window.__api.getSceneElements().length),3);
const scrollBefore=await page.evaluate(()=>window.__api.getAppState().scrollX);
await page.keyboard.down('Space');await page.mouse.move(900,700);await page.mouse.down();
await page.mouse.move(950,700,{steps:5});await page.mouse.up();await page.keyboard.up('Space');
assert.equal(await page.evaluate(()=>window.__api.getSceneElements().length),3,'space-drag pans without ink');
assert.notEqual(await page.evaluate(()=>window.__api.getAppState().scrollX),scrollBefore);
await page.getByRole('button',{name:'Normal',exact:true}).click();
assert.equal(await page.evaluate(()=>window.__api.getAppState().currentItemOpacity),100);
await page.evaluate(()=>window.__waitForPenSettings());await page.keyboard.press('Meta+s');await page.waitForFunction(()=>!document.title.startsWith('●'));
await page.reload();await page.waitForFunction(()=>window.__api?.getSceneElements().length===3);
const restored=await page.evaluate(()=>window.__api.getSceneElements()[0]);
const absolute=e=>e.points.map(([x,y])=>[+(x+e.x).toFixed(5),+(y+e.y).toFixed(5)]);
assert.deepEqual(absolute(restored),absolute(tapered));
await page.keyboard.press('v');
await page.waitForFunction(()=>window.__api.getAppState().activeTool.type==='selection');
assert.equal(await page.getByRole('toolbar',{name:'Pens'}).count(),0);
await page.evaluate(()=>window.__api.updateScene({appState:{currentItemStrokeColor:'#ff0000'}}));
await page.keyboard.press('p');
await page.getByRole('toolbar',{name:'Pens'}).waitFor();
assert.equal(await page.evaluate(()=>window.__api.getAppState().currentItemStrokeColor),normal.strokeColor);
// Reproduce the reference: a tapered branch must sit behind the box border.
await page.evaluate(normal=>window.__api.updateScene({elements:[{
 ...normal,id:'pen-box',type:'rectangle',x:390,y:440,width:150,height:120,
 strokeWidth:2,backgroundColor:'#ffffff',fillStyle:'solid',roundness:null,
}]}),normal);
await page.getByRole('button',{name:'Thick → thin',exact:true}).click();
await page.getByTestId('strokeWidth-bold').locator('..').click();
await page.locator('input[name="strokeOptions.variability"]').nth(0).locator('..').click();
await page.getByTestId('opacity').fill('100');
const branch=await draw('Thick → thin',500,true);
assert.deepEqual(await page.evaluate(()=>window.__api.getSceneElements().map(e=>e.id)),[branch.id,'pen-box']);
await page.screenshot({path:'/tmp/excalimacs-pens-box-layering.png'});
await page.keyboard.press('v');
// Click an actual outline point so native selection would expose line handles.
const branchPoint=await page.evaluate(id=>{
 const element=window.__api.getSceneElements().find(e=>e.id===id);
 const [x,y]=element.points[Math.floor(element.points.length/4)];
 const state=window.__api.getAppState();
 return [(x+element.x+state.scrollX)*state.zoom.value+state.offsetLeft,
   (y+element.y+state.scrollY)*state.zoom.value+state.offsetTop];
},branch.id);
await page.mouse.click(...branchPoint);
await page.waitForFunction(id=>window.__api.getAppState().selectedElementIds[id],branch.id);
await page.waitForFunction(()=>window.__api.getAppState().selectedLinearElement===null);
assert.deepEqual(await page.evaluate(()=>Object.keys(window.__api.getAppState().selectedElementIds)),[branch.id]);
await page.waitForFunction(()=>document.querySelector('.excalidraw').classList.contains('pen-selection'));
assert.equal(await page.locator('[data-openpopup="elementBackground"]').isVisible(),false);
assert.equal(await page.getByTestId('fill-solid').isVisible(),false);
assert.equal(await page.getByTestId('strokeWidth-thin').isVisible(),false);
await page.keyboard.press('Enter');
assert.equal(await page.getByRole('button',{name:'Edit points',exact:true}).isVisible(),false);
await page.getByTestId('color-top-pick-#e03131').click();
await page.waitForFunction(id=>{
 const e=window.__api.getSceneElements().find(e=>e.id===id);
 return e.strokeColor==='#e03131'&&e.backgroundColor==='#e03131'&&e.strokeWidth===0;
},branch.id);
// Check an interior pixel of the displayed canvas, not merely scene metadata.
const {getStrokePoints}=await import('perfect-freehand');
const centerline=getStrokePoints(branch.customData.excalimacsPen.points,
 {size:branch.customData.excalimacsPen.settings.width*4.25,streamline:0.5,last:true});
const center=centerline[Math.floor(centerline.length*0.6)].point;
await page.waitForFunction(({id,center})=>{
 const e=window.__api.getSceneElements().find(e=>e.id===id),s=window.__api.getAppState();
 const canvas=document.querySelector('canvas.excalidraw__canvas.static'),rect=canvas.getBoundingClientRect();
 const x=((e.x+center[0]+s.scrollX)*s.zoom.value+s.offsetLeft-rect.left)*canvas.width/rect.width;
 const y=((e.y+center[1]+s.scrollY)*s.zoom.value+s.offsetTop-rect.top)*canvas.height/rect.height;
 const [r,g,b]=canvas.getContext('2d').getImageData(Math.round(x),Math.round(y),1,1).data;
 return r>g+80&&r>b+80;
},{id:branch.id,center});
await page.keyboard.press('Meta+z');await page.waitForTimeout(200);
assert.equal(await page.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id).backgroundColor,branch.id),branch.backgroundColor,'color undo restores whole mark');
await page.keyboard.press('Meta+Shift+z');await page.waitForTimeout(200);
await page.getByRole('radiogroup',{name:'Pen stroke width'}).getByRole('radio',{name:'Medium',exact:true}).locator('..').click();
await page.waitForFunction(id=>window.__api.getSceneElements().find(e=>e.id===id).customData.excalimacsPen.settings.width===1,branch.id);
assert.equal(await page.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id).strokeWidth,branch.id),0,'pen width changes without adding a border');
assert.equal(await page.getByRole('radiogroup',{name:'Pen stroke width'}).getByRole('radio',{name:'Medium',exact:true}).isChecked(),true);
await page.keyboard.press('Meta+z');await page.waitForTimeout(200);
assert.equal(await page.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id).customData.excalimacsPen.settings.width,branch.id),branch.customData.excalimacsPen.settings.width);
await page.keyboard.press('Meta+Shift+z');await page.waitForTimeout(200);
await page.screenshot({path:'/tmp/excalimacs-pens-single-selection.png'});
// Whole-stroke dragging still works after the point editor is suppressed.
const beforeDrag=await page.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id).x,branch.id);
await page.mouse.move(...branchPoint);await page.mouse.down();
await page.mouse.move(branchPoint[0]+30,branchPoint[1]+20,{steps:5});await page.mouse.up();
assert.ok(await page.evaluate(({id,before})=>window.__api.getSceneElements().find(e=>e.id===id).x>before+20,{id:branch.id,before:beforeDrag}));
const beforeResize=await page.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id),branch.id);
const resizeHandle=await page.evaluate(id=>{
 const e=window.__api.getSceneElements().find(e=>e.id===id),s=window.__api.getAppState();
 return [(e.x+Math.max(...e.points.map(p=>p[0]))+s.scrollX)*s.zoom.value+s.offsetLeft+8,
  (e.y+Math.max(...e.points.map(p=>p[1]))+s.scrollY)*s.zoom.value+s.offsetTop+8];
},branch.id);
await page.mouse.move(...resizeHandle);await page.mouse.down();
await page.mouse.move(resizeHandle[0]+100,resizeHandle[1]+70,{steps:8});
const resized=await page.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id),branch.id);
assert.ok(resized.width>beforeResize.width+60,'native resize changes the stroke path');
assert.equal(resized.customData.excalimacsPen.settings.width,beforeResize.customData.excalimacsPen.settings.width);
const pen=resized.customData.excalimacsPen;
const resizedOutline=strokeOutline(pen.points,pen.preset,pen.settings,pen.pressures,pen.simulatePressure);
const height=Math.max(...resizedOutline.map(p=>p[1]))-Math.min(...resizedOutline.map(p=>p[1]));
assert.ok(Math.abs(resized.height-height)<0.001,'live outline regenerated at fixed pen width');
await page.mouse.up();
await page.keyboard.press('Meta+z');await page.waitForTimeout(200);
const undone=await page.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id),branch.id);
assert.deepEqual(absolute(undone),absolute(beforeResize),'resize undo restores original outline');
await page.keyboard.press('Meta+Shift+z');await page.waitForTimeout(200);
const redone=await page.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id),branch.id);
assert.deepEqual(absolute(redone),absolute(resized),'resize redo restores fixed-width outline');
await page.evaluate(()=>window.__waitForPenSettings());
await page.keyboard.press('Meta+s');await page.waitForFunction(()=>!document.title.startsWith('●'));
await page.reload();await page.waitForFunction(id=>window.__api?.getSceneElements().some(e=>e.id===id),branch.id);
assert.deepEqual(await page.evaluate(id=>window.__api.getSceneElements().find(e=>e.id===id).customData.excalimacsPen,branch.id),redone.customData.excalimacsPen,'resize path data survives save/reload');
// Background and fill controls remain available for ordinary shapes.
await page.evaluate(()=>window.__api.updateScene({appState:{selectedElementIds:{'pen-box':true}}}));
await page.waitForFunction(()=>!document.querySelector('.excalidraw').classList.contains('pen-selection'));
assert.equal(await page.locator('[data-openpopup="elementBackground"]').isVisible(),true);
assert.equal(await page.getByRole('radiogroup',{name:'Pen stroke width'}).count(),0);
await page.keyboard.press('p');
await page.getByRole('toolbar',{name:'Pens'}).waitFor();
await page.setViewportSize({width:390,height:844});await page.getByRole('toolbar',{name:'Pens'}).waitFor({state:'visible'});assert.equal(await page.getByRole('toolbar',{name:'Pens'}).isVisible(),true);
await page.evaluate(()=>window.__waitForPenSettings());
emacs('(setq excalimacs-plugins nil)');await page.reload();await page.waitForFunction(()=>window.__api);await page.waitForTimeout(500);assert.equal(await page.getByRole('toolbar',{name:'Pens'}).count(),0);
assert.deepEqual(errors,[]);console.log('Pens browser checks passed');
}finally{await browser.close();await server.close();emacs('(setq excalimacs-plugins excalimacs-test-previous-plugins)');execFileSync('trash',[drawing]);if(previousPrefs){fs.writeFileSync(prefsPath,previousPrefs);execFileSync('trash',[prefsPath.replace('plugin-settings.json','plugin-settings.pens-test-backup')]);}else if(fs.existsSync(prefsPath))execFileSync('trash',[prefsPath]);}
})().catch(e=>{console.error(e);process.exitCode=1;});
