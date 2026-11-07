const $ = s => document.querySelector(s);
const NS = 'http://www.w3.org/2000/svg';
let manifest, current, draft, selected = -1, dirty = false, drawing = false, hidden = false, drag;
const image = new Image();
const svg = (tag, attrs) => { const e = document.createElementNS(NS, tag); for (const [k,v] of Object.entries(attrs)) e.setAttribute(k,v); return e; };
const clone = x => JSON.parse(JSON.stringify(x));
const escapeHTML = s => String(s).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function visible() { return manifest.captures.filter(c => $('#filter').value === 'all' || c.status === $('#filter').value); }
function list() {
  const rows = manifest.captures;
  $('#progress').textContent = `${rows.filter(c=>c.status==='approved').length} approved / ${rows.length} · ${rows.filter(c=>c.status==='flagged').length} flagged`;
  $('.navtitle strong').textContent = `${rows.length} captures`;
  $('#list').innerHTML = visible().map(c => `<button class="capture ${c.id===current?'active':''}" data-id="${c.id}"><img loading="lazy" src="/images/${c.id}/preview.jpg" alt=""><span><span class="num">${String(c.index).padStart(2,'0')}</span><small>${c.dice.length} dice · ${c.dice.reduce((s,d)=>s+(d.value||0),0)} total</small><small class="dot ${c.status}">${c.status}</small></span></button>`).join('');
  document.querySelectorAll('.capture').forEach(b=>b.onclick=()=>load(b.dataset.id));
}
function load(id, force=false) {
  if(dirty && !force && !confirm('Discard unsaved changes to this capture?')) return;
  current=id; draft=clone(manifest.captures.find(c=>c.id===id)); selected=-1; dirty=false; drawing=false;
  location.hash=id;
  $('#add').setAttribute('aria-pressed','false');
  $('#title').textContent=`Capture ${String(draft.index).padStart(2,'0')} / ${manifest.captures.length}`;
  $('#captureid').textContent=draft.id;
  $('#status').textContent=draft.status; $('#status').className=`badge ${draft.status}`;
  $('#notes').value=draft.notes;
  $('.provisional').textContent=draft.status==='approved'?'Approved golden master':draft.status==='flagged'?'Flagged for revision':'Proposed labels · awaiting your review';
  $('#analysis').textContent='Initial analysis: '+(draft.analysis || 'Inspect every upper face and the completeness of the boxes.').split(' Proposed values:')[0];
  $('#feedback').textContent='';
  $('#canvas').setAttribute('viewBox',`0 0 ${draft.width} ${draft.height}`);
  $('#photo').setAttribute('width',draft.width);$('#photo').setAttribute('height',draft.height);
  $('#photo').setAttribute('href',`/images/${id}/preview.jpg`);
  $('#original').href=`/images/${id}/image.jpg`;
  image.src=`/images/${id}/image.jpg`;
  image.onload=()=>{if(current===id)crops();};
  list(); render();
  $('#prev').disabled=visible().findIndex(c=>c.id===id)<=0;
  $('#next').disabled=visible().findIndex(c=>c.id===id)>=visible().length-1;
}
function summary() {
  const complete=draft.dice.every(d=>d.value!==null);
  $('#conclusion').innerHTML=`${draft.dice.length} dice <small>${draft.dice.length?draft.dice.map(d=>d.value??'?').join(' + '):'Empty tray'} = ${complete?draft.dice.reduce((s,d)=>s+d.value,0):'?'}</small>`;
}
function renderBoxes() {
  const group=$('#boxes');group.replaceChildren();group.style.display=hidden?'none':'';
  draft.dice.forEach((d,i)=>{
    const [x,y,w,h]=d.box;const g=svg('g',{'data-die':i,class:i===selected?'selected':''});
    g.append(svg('rect',{x,y,width:w,height:h,class:'face'}));
    const tagY=Math.max(0,y-66);
    g.append(svg('rect',{x,y:tagY,width:190,height:64,rx:10,class:'tag'}));
    const t=svg('text',{x:x+12,y:tagY+48});t.textContent=`${i+1}: ${d.value??'?'}`;g.append(t);
    if(i===selected) [[x,y,'nw'],[x+w,y,'ne'],[x,y+h,'sw'],[x+w,y+h,'se']].forEach(([cx,cy,k])=>g.append(svg('rect',{x:cx-23,y:cy-23,width:46,height:46,class:'handle','data-handle':k})));
    group.append(g);
  });
}
function render() {
  summary();renderBoxes();
  $('#dice').innerHTML=draft.dice.map((d,i)=>`<div class="die ${i===selected?'selected':''}" data-die="${i}"><canvas class="crop" width="200" height="200" aria-label="Enlarged die ${i+1}"></canvas><div><label for="value-${i}">Die ${i+1} · upper face</label><select id="value-${i}" aria-label="Die ${i+1} value">${[null,1,2,3,4,5,6].map(v=>`<option value="${v??''}" ${v===d.value?'selected':''}>${v??'?'}</option>`).join('')}</select><button class="delete" aria-label="Delete die ${i+1}">×</button><div class="coordinates">${d.box.map(Math.round).join(', ')} px</div></div></div>`).join('');
  document.querySelectorAll('.die').forEach(e=>{
    const i=Number(e.dataset.die);
    e.querySelector('select').onchange=event=>{draft.dice[i].value=event.target.value?Number(event.target.value):null;dirty=true;summary();renderBoxes();};
    e.querySelector('.delete').onclick=()=>{draft.dice.splice(i,1);selected=-1;dirty=true;render();};
    e.querySelector('canvas').onclick=()=>{selected=i;render();};
  });
  crops();
}
function crops() {
  if(!image.complete || !image.naturalWidth || !image.src.includes(current))return;
  document.querySelectorAll('.crop').forEach((canvas,i)=>{
    const [x,y,w,h]=draft.dice[i].box;const pad=Math.max(w,h)*.2;
    const side=Math.max(w,h)+2*pad;const ctx=canvas.getContext('2d');
    ctx.fillStyle='#151c18';ctx.fillRect(0,0,200,200);
    ctx.drawImage(image,x+w/2-side/2,y+h/2-side/2,side,side,0,0,200,200);
  });
}
function point(e){const p=$('#canvas').createSVGPoint();p.x=e.clientX;p.y=e.clientY;return p.matrixTransform($('#canvas').getScreenCTM().inverse());}
const bounded = p=>({x:Math.max(0,Math.min(draft.width,p.x)),y:Math.max(0,Math.min(draft.height,p.y))});
$('#canvas').onpointerdown=e=>{
  if(e.button!==0)return;
  const p=bounded(point(e));const target=e.target.closest('[data-die]');
  if(drawing){draft.dice.push({id:String(Date.now()),value:null,box:[p.x,p.y,1,1],provenance:'reviewer drawn'});selected=draft.dice.length-1;drag={kind:'draw',start:p,box:[p.x,p.y,1,1]};dirty=true;}
  else if(target){selected=Number(target.dataset.die);drag={kind:e.target.dataset.handle||'move',start:p,box:[...draft.dice[selected].box]};}
  else {selected=-1;render();return;}
  $('#canvas').setPointerCapture(e.pointerId);renderBoxes();
};
$('#canvas').onpointermove=e=>{
  if(!drag)return;const p=bounded(point(e));let [x,y,w,h]=drag.box;const dx=p.x-drag.start.x,dy=p.y-drag.start.y;
  if(drag.kind==='move'){x=Math.max(0,Math.min(draft.width-w,x+dx));y=Math.max(0,Math.min(draft.height-h,y+dy));}
  else if(drag.kind==='draw'){x=Math.min(p.x,drag.start.x);y=Math.min(p.y,drag.start.y);w=Math.max(1,Math.abs(dx));h=Math.max(1,Math.abs(dy));}
  else {let right=x+w,bottom=y+h;if(drag.kind.includes('w'))x=Math.min(right-1,p.x);if(drag.kind.includes('e'))right=Math.max(x+1,p.x);if(drag.kind.includes('n'))y=Math.min(bottom-1,p.y);if(drag.kind.includes('s'))bottom=Math.max(y+1,p.y);w=right-x;h=bottom-y;}
  draft.dice[selected].box=[x,y,w,h];draft.dice[selected].provenance='reviewer adjusted';dirty=true;renderBoxes();
};
function finishDrag(){if(!drag)return;drag=null;drawing=false;$('#add').setAttribute('aria-pressed','false');render();}
$('#canvas').onpointerup=finishDrag;$('#canvas').onpointercancel=finishDrag;
$('#add').onclick=()=>{drawing=!drawing;$('#add').setAttribute('aria-pressed',String(drawing));$('#feedback').textContent=drawing?'Drag a rectangle around the upper face.':'';};
$('#overlay').onclick=()=>{hidden=!hidden;$('#overlay').textContent=hidden?'Show boxes':'Hide boxes';$('#overlay').setAttribute('aria-pressed',String(!hidden));renderBoxes();};
$('#zoom').onclick=()=>{const zoom=$('#imagewell').classList.toggle('zoomed');$('#zoom').textContent=zoom?'Fit photo':'Zoom in';};
$('#notes').oninput=()=>{draft.notes=$('#notes').value;dirty=true;};
function next(step){const rows=visible();const i=rows.findIndex(c=>c.id===current);if(rows[i+step])load(rows[i+step].id);}
$('#prev').onclick=()=>next(-1);$('#next').onclick=()=>next(1);$('#filter').onchange=()=>{list();};
async function save(status,advance=false){
  if(status==='approved' && draft.dice.some(d=>d.value===null)){ $('#feedback').textContent='Choose a value for every die before approving.';return; }
  const buttons=[...document.querySelectorAll('.actions button')];buttons.forEach(b=>b.disabled=true);
  const oldIndex=manifest.captures.findIndex(c=>c.id===current);
  try{
    const response=await fetch(`/api/captures/${current}`,{method:'POST',headers:{'Content-Type':'application/json','X-DiceTower-Review':'1'},body:JSON.stringify({...draft,status})});
    const result=await response.json();if(!response.ok)throw Error(result.error);
    manifest.captures[oldIndex]=result;dirty=false;
    if(advance){const nextRow=manifest.captures.slice(oldIndex+1).find(c=>$('#filter').value==='all'||c.status===$('#filter').value);if(nextRow){load(nextRow.id,true);}else{load(current,true);$('#feedback').textContent='Approved. You have reached the end of this set.';}}
    else{load(current,true);$('#feedback').textContent=status==='flagged'?'Saved and flagged for revision.':'Edits saved. Awaiting approval.';}
  }catch(error){$('#feedback').textContent=error.message;}
  finally{buttons.forEach(b=>b.disabled=false);}
}
$('#approve').onclick=()=>save('approved',true);$('#save').onclick=()=>save('pending');$('#flag').onclick=()=>save('flagged');
window.onbeforeunload=e=>{if(dirty){e.preventDefault();e.returnValue='';}};
document.onkeydown=e=>{if(['INPUT','TEXTAREA','SELECT'].includes(e.target.tagName))return;if(e.key==='ArrowRight')next(1);if(e.key==='ArrowLeft')next(-1);};
fetch('/api/manifest').then(r=>{if(!r.ok)throw Error('Could not load corpus');return r.json();}).then(data=>{manifest=data;if(data.title){$('h1').textContent=data.title;document.title=`DiceTower · ${data.title}`;}const id=location.hash.slice(1);load(data.captures.some(c=>c.id===id)?id:data.captures[0].id);}).catch(e=>{$('#workspace').textContent=e.message;});
