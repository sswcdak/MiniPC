// Regenerate the chat-side route view from the compute-side renderer. Compute UI is unchanged.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'apps/compute-node/entry/src/main/resources/rawfile/peer-chat.html'), 'utf8').replace(/\r\n/g, '\n');
function part(start, end) {
 const a=source.indexOf(start), b=source.indexOf(end,a+start.length);
 if(a<0||b<0)throw new Error('Compute route renderer marker missing: '+start);
 return source.slice(a,b);
}
const target = path.join(root, 'apps/agent-client/entry/src/main/resources/rawfile/task-routing.html');
const previous = fs.existsSync(target) ? fs.readFileSync(target, 'utf8').replace(/\r\n/g, '\n') : '';
// The chat view also handles cloud executors. Keep that adapter when refreshing shared assets.
const hasCloudAdapter = previous.includes('.flow-cloud{');
const cloudCss = hasCloudAdapter ? (previous.match(/^    \.flow-cloud\{.*$/m)?.[0] || '') : '';
const pendingCss=previous.split('\n').filter(line=>/^\.flow-(compute\.is-pending|pending-note)/.test(line)).join('\n');
const routeStateCss=previous.match(/\/\* tablet-route-state-start \*\/[\s\S]*?\/\* tablet-route-state-end \*\//)?.[0] || '';
const css = part('    .flow-view{', '</style>') + '\n' + cloudCss + '\n' + pendingCss;
const symbols = [...source.matchAll(/<symbol id="flow-[\s\S]*?<\/symbol>/g)].map(m=>m[0]).join('\n');
let helpers = part('    function summaryText(', '    function focusWithoutScroll(')+
 part('    function morphNode(', '    function phaseView(')+
 part('    function esc(', source.includes('    function sideClass(') ? '    function sideClass(' : '    function shortModel(')+
 part('    function publicJobName(', '    function updateButton(')+
 part('    function jobKey(', '    // The rail is rebuilt');
let renderer = part('    const flowView=', '    function setTaskView(');
if (hasCloudAdapter) {
 const start=previous.indexOf('    const flowView='), end=previous.indexOf('\nconst viewport=',start);
 if(start<0||end<0)throw new Error('Chat cloud renderer markers missing');
 renderer=previous.slice(start,end);
}
// Give larger labels and memory meters room without changing device artwork dimensions.
renderer=renderer.replace(/height=Math.max\((?:210|224|240|256),88\+Math.max\(1,active.length\)\*96\)/,
 'height=Math.max(device.ready?256:304,96+Math.max(1,active.length)*108)');
renderer=renderer.replace('class="flow-compute" data-row-key="compute:',
 `class="flow-compute'+(row.busy?' is-computing':'')+'" data-row-key="compute:`);
renderer=renderer.replace(/height=Math.max\(device.ready\?(?:256|304|344):(?:304|344|384),96\+Math.max\(1,active.length\)\*108\)/,
 'height=Math.max(device.ready?344:384,96+Math.max(1,active.length)*108)');
renderer=renderer.replace('left=380,rowWidth=', 'left=320,rowWidth=');
if (!renderer.includes('const spread=width/960;')) {
 renderer=renderer.replace('const width=Math.max(960,(flowView.clientWidth||1024)-44),left=320,rowWidth=width-left-18;',
  "const width=Math.max(960,(flowView.clientWidth||1024)-44);\n      const spread=width/960;flowView.style.setProperty('--flow-spread',spread);\n      const left=320*spread,rowWidth=width-left-18;");
 renderer=renderer.replace("const sourcePath=y=>'M120 '+y+'H148Q158 '+y+' 158 '+(y+(y<center?12:-12))+'V'+(center+(y<center?-12:12))+'Q158 '+center+' 168 '+center+'H190';",
  "const sourcePath=y=>'M'+(68*spread+52)+' '+y+'H'+(158*spread-10)+'Q'+(158*spread)+' '+y+' '+(158*spread)+' '+(y+(y<center?12:-12))+'V'+(center+(y<center?-12:12))+'Q'+(158*spread)+' '+center+' '+(158*spread+10)+' '+center+'H'+(232*spread-42);");
 renderer=renderer.replace("const targetPath=y=>'M274 '+center+'H300Q310 '+center+' 310 '+(center+(y<center?-12:12))+'V'+(y+(y<center?12:-12))+'Q310 '+y+' 320 '+y+'H'+left;",
  "const targetPath=y=>'M'+(232*spread+42)+' '+center+'H'+(310*spread-10)+'Q'+(310*spread)+' '+center+' '+(310*spread)+' '+(center+(y<center?-12:12))+'V'+(y+(y<center?12:-12))+'Q'+(310*spread)+' '+y+' '+(310*spread+10)+' '+y+'H'+left;");
 renderer=renderer.replace('style="top:\'+(sourceY.get(source.id)-58)', 'style="left:\'+(68*spread-60)+\'px;top:\'+(sourceY.get(source.id)-58)');
 renderer=renderer.replace('style="top:\'+(center-35)', 'style="left:\'+(232*spread-42)+\'px;top:\'+(center-35)');
 renderer=renderer.replace("sourcePath(y)+'L274 '+center+targetPath(targetY.get(item.executor)).replace(/^M274 [^H]+/,'')",
  "sourcePath(y)+'L'+(232*spread+42)+' '+center+targetPath(targetY.get(item.executor)).replace(/^M[^H]+/,'')");
}
const setup = `let jobs=[],remoteCalls=[],devices=[],groups=[],selfLabel='算力设备1';
function allCalls(){return jobs.concat(remoteCalls);}
`;
const adapter = `
const viewport=document.getElementById('viewport'),stage=document.getElementById('stage'),space=document.getElementById('space');
function fitFlow(){
 const width=viewport.clientWidth,height=viewport.clientHeight;
 if(width<=0||height<=0)return;
 const widthScale=Math.min(1,width/1000);
 // Keep the existing heading size at the normal width, then fit the whole diagram into both axes.
 stage.style.setProperty('--flow-scale',widthScale);
 let scale=Math.min(widthScale,height/Math.max(1,stage.scrollHeight));
 for(let pass=0;pass<3;pass++){
  const layoutWidth=Math.max(1000,width/scale);
  if(Math.abs((parseFloat(stage.style.width)||1000)-layoutWidth)>.5){
   stage.style.width=layoutWidth+'px';flowView.style.width=layoutWidth+'px';renderFlow();
  }
  const nextScale=Math.min(widthScale,height/Math.max(1,stage.scrollHeight));
  if(Math.abs(nextScale-scale)<.000001)break;
  scale=nextScale;
 }
 stage.style.transform='scale('+scale+')';stage.style.left='0px';
 space.style.width=width+'px';space.style.height=height+'px';
}
window.onNativeEvent=function(event){devices=event.devices||[];jobs=event.jobs||[];groups=[];queuedCalls=event.queuedCalls||[];mirroredCalls=event.flowCalls||[];renderFlow();fitFlow();};
window.addEventListener('resize',()=>{flowSignature='';renderFlow();fitFlow();});
if(typeof ResizeObserver!=='undefined')new ResizeObserver(fitFlow).observe(viewport);
flowView.addEventListener('click',event=>{const button=event.target.closest('[data-flow-detail]');if(!button)return;
 const job=jobs.concat(queuedCalls).find(j=>jobKey(j)===button.getAttribute('data-flow-detail'));if(!job)return;
 document.getElementById('detailText').textContent=(job.question||'推理请求')+'\\n执行设备：'+(job.source||'等待分派')+'\\n状态：'+flowState(flowItems.find(item=>item.key===jobKey(job))||{phase:job.phase,executor:job.source,stage:job.stage});
 document.getElementById('detail').hidden=false;
});
document.getElementById('closeDetail').addEventListener('click',()=>document.getElementById('detail').hidden=true);
setInterval(()=>{renderFlow();fitFlow();},500);renderFlow();fitFlow();
`;
const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<title>任务路由</title><style>
:root{--ink:#16332C;--muted:#6B7F79;--ok:#1a9b6a;--busy:#3d5bdb}*{box-sizing:border-box}html,body{width:100%;height:100%;margin:0;overflow:hidden}body{font-family:system-ui,'HarmonyOS Sans SC',sans-serif;color:var(--ink);background:white}
${css}
#viewport{position:relative;width:100%;height:100%;overflow:hidden;overflow:clip;touch-action:manipulation}#stage{position:absolute;left:0;top:0;width:1000px;transform-origin:top left}.flow-view{width:1000px;padding:8px 20px 16px;min-height:0;overflow:visible}.flow-labels{min-width:960px}.flow-empty{left:370px}#detail{position:fixed;inset:12px;padding:16px;background:#f7fbfa;border:1px solid #d8e5df;border-radius:14px;overflow:auto}#detail[hidden]{display:none}#detailText{white-space:pre-wrap;overflow-wrap:anywhere}#closeDetail{float:right;border:0;border-radius:8px;padding:8px;background:#d8f3ea;color:#0f8a74}
.flow-labels{font-size:calc(19px / var(--flow-scale,1));font-weight:600;color:#48665b;line-height:1.35;padding-bottom:24px}
.flow-labels{grid-template-columns:calc(136px * var(--flow-spread,1)) calc(192px * var(--flow-spread,1)) 1fr}
.flow-labels span{text-align:center;white-space:nowrap}
.flow-labels span:last-child{padding:0 20px 0 0;transform:translateX(calc(-4px * var(--flow-spread,1)))}
.flow-compute{grid-template-columns:260px minmax(240px,1fr);gap:18px}
.flow-compute:not(.flow-cloud){border:2px solid #D4DEEA;background:#FFFFFF;box-shadow:0 3px 10px #2449710A,0 1px 2px #24497108}
.flow-phone{font-size:28px}.flow-phone>span{white-space:nowrap}.flow-router>span{font-size:28px}
.flow-computer{font-size:30px;gap:8px}.flow-computer small{font-size:24px}
.flow-computer{min-width:0}.flow-computer>span{width:100%;min-width:0;white-space:normal;overflow-wrap:anywhere;line-height:36px;display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:3;overflow:hidden}
.flow-memory{width:200px}.flow-memory>i{height:18px;border-radius:9px}
.flow-memory>span{font-size:26px;line-height:32px}.flow-memory b{font-weight:700}
.flow-lane h3{font-size:30px;line-height:36px}.flow-idle{font-size:25px}
.flow-task>span{font-size:28px}.flow-task b{font-size:42px}
.flow-compute.is-computing{background:#F8FBFF;border-color:#BDCEE4;box-shadow:0 4px 14px #3B61951A,0 1px 3px #3B61950D;animation:compute-breathe 4s ease-in-out infinite}
.flow-compute.is-computing .flow-computer{color:#244238}
.flow-compute.is-computing .flow-lane h3{color:#5575A6}
.flow-compute.is-computing .flow-memory>i{background:#DCE6F2}
.flow-compute.is-computing .flow-memory>span,.flow-compute.is-computing .flow-idle,.flow-compute.is-computing .flow-computer small{color:#4E6286}
.flow-compute.is-computing .flow-task{background:#FFFFFFD9;border-color:#D4E1F0;color:#3F587A;box-shadow:0 1px 3px #385A8808}
.flow-compute.is-computing .flow-task b{color:#496991}
.flow-compute.is-computing .flow-task.working:before{background:#7C9BD4}
@keyframes compute-breathe{0%,100%{background-color:#F8FBFF;border-color:#BDCEE4;box-shadow:0 4px 14px #3B61951A,0 1px 3px #3B61950D}50%{background-color:#EFF5FF;border-color:#A9C1E1;box-shadow:0 7px 20px #3B619526,0 2px 5px #3B619512}}
@media(max-width:480px){.flow-labels{font-size:calc(13px / var(--flow-scale,1))}}
@media(prefers-reduced-motion:reduce){.flow-compute.is-computing{animation:none}}
${routeStateCss}
</style></head><body><svg style="position:absolute;width:0;height:0" aria-hidden="true"><defs>${symbols}</defs></svg>
<div id="viewport"><div id="space"></div><div id="stage"><section id="collaboration" class="flow-view" aria-label="设备协同运行图"></section></div></div>
<div id="detail" hidden><button id="closeDetail">关闭</button><p id="detailText"></p></div>
<script>${setup}${helpers}${renderer}${adapter}</script></body></html>`;
fs.writeFileSync(path.join(root,'apps/agent-client/entry/src/main/resources/rawfile/task-routing.html'),html);
console.log('Generated task-routing.html from compute route renderer');
