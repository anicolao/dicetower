const $=s=>document.querySelector(s),NS='http://www.w3.org/2000/svg';
let data,model,current,selected=-1,full=false,noteDirty=false,lastFilter='fail';
const image=new Image();
const svg=(tag,attrs)=>{const e=document.createElementNS(NS,tag);Object.entries(attrs).forEach(([k,v])=>e.setAttribute(k,v));return e;};
const percent=v=>`${(v*100).toFixed(1)}%`;
function visible(){return model.captures.filter(c=>$('#filter').value==='all'||(c.metrics.exactLocalized? 'pass':'fail')===$('#filter').value);}
function renderList(){
 const s=model.summary;$('#summary').innerHTML=`<strong>${s.exactLocalizedScenes}/${s.scenes} photos fully correct</strong> · ${s.scenes-s.exactLocalizedScenes} failures<br>${s.truePositiveFaces50}/50 correct face values · ${s.exactCounts}/${s.scenes} correct counts`;
 $('#list').innerHTML=visible().map(c=>`<button class="capture ${current?.id===c.id?'active':''}" data-id="${c.id}"><img loading="lazy" src="/images/${c.id}/preview.jpg" alt=""><span><strong>Capture ${c.index}</strong><small class="${c.metrics.exactLocalized?'pass':'fail'}">${c.metrics.exactLocalized?'Pass':'Fail'}</small><small>${c.predictions.length} predicted / ${c.dice.length} actual</small></span></button>`).join('')||'<p class="help">No photos in this filter.</p>';
 document.querySelectorAll('.capture').forEach(e=>e.onclick=()=>load(e.dataset.id));
}
function frame(){
 const t=current.transform;$('#canvas').setAttribute('viewBox',full?`0 0 ${current.width} ${current.height}`:`${t.cropX} ${t.cropY} ${t.cropWidth} ${t.cropHeight}`);
 $('#frame').textContent=full?'Tray view':'Full photo';
}
function canLeave(){if(!noteDirty)return true;if(confirm('Discard unsaved review notes?')){noteDirty=false;return true;}return false;}
function load(id){
 if(!canLeave())return;
 current=model.captures.find(c=>c.id===id);selected=-1;location.hash=id;
 $('#title').textContent=`Capture ${String(current.index).padStart(2,'0')}`;
 $('#identity').textContent=current.id;
 $('#status').textContent=current.metrics.exactLocalized?'Pass · all faces correct':'Fail · inspect highlighted rows';$('#status').className=`badge ${current.metrics.exactLocalized?'pass':'fail'}`;
 $('#photo').setAttribute('width',current.width);$('#photo').setAttribute('height',current.height);$('#photo').setAttribute('href',`/images/${id}/image.jpg`);
 $('#original').href=`/images/${id}/image.jpg`;image.onload=()=>crops();image.src=`/images/${id}/image.jpg`;
 $('#conclusion').innerHTML=`${current.metrics.exactLocalized?'All faces correct':'Frozen-label mismatch'}<small><span class="green">Truth: ${current.dice.map(d=>d.value).join(', ')} · ${current.dice.length} dice</span><br><span class="red">Model: ${current.predictions.map(p=>p.label).join(', ')} · ${current.predictions.length} dice</span></small>`;
 const wrong=current.matches.filter(m=>!m.correctValue).length;
 const parts=[];if(wrong)parts.push(`${wrong} face-value mismatch${wrong===1?'':'es'}`);if(current.extraPredictions.length)parts.push(`${current.extraPredictions.length} extra detection${current.extraPredictions.length===1?'':'s'}`);if(current.missedTruth.length)parts.push(`${current.missedTruth.length} missed face${current.missedTruth.length===1?'':'s'}`);
 $('#explanation').textContent=parts.length?parts.join(' · ')+'. Matches use box overlap (IoU ≥ 0.5), independent of face value.':'Every face has a correctly valued prediction overlapping its approved box. No extra detections.';
 $('#settings').textContent=`Truth version ${data.truthVersion||1} · Frozen cutoff ${model.cutoff.toFixed(2)} · NMS IoU ${data.nmsIoU.toFixed(2)}. Confidence = object confidence × class confidence. Saved model predictions and thresholds are unchanged.`;
 $('#findings').textContent=data.labelFindings[id]?.note||'';$('#findings').className=data.labelFindings[id]?'finding':'';
 $('#note').value=data.reviewNotes[id]?.note||'';$('#saved').textContent='';noteDirty=false;lastFilter=$('#filter').value;$('aside').scrollTop=0;
 frame();renderList();renderBoxes();renderFaces();
 const rows=visible(),i=rows.findIndex(c=>c.id===id);$('#prev').disabled=i<=0;$('#next').disabled=i<0||i>=rows.length-1;
}
function renderBoxes(){
 const group=$('#boxes');group.replaceChildren();
 if($('#truth').checked)current.dice.forEach((die,i)=>{const[x,y,w,h]=die.box;const rect=svg('rect',{x,y,width:w,height:h,class:`truthbox ${selected===i?'selected':''}`});rect.onclick=()=>select(i);group.append(rect);const text=svg('text',{x,y:Math.max(55,y-22),class:'truthlabel'});text.textContent=`T${i+1}: ${die.value}`;group.append(text);});
 if($('#predicted').checked)current.predictions.forEach((pred,i)=>{const[x,y,w,h]=pred.box;group.append(svg('rect',{x,y,width:w,height:h,class:'predictionbox'}));const text=svg('text',{x,y:Math.min(current.height-10,y+h+52),class:'predictionlabel'});text.textContent=`P${i+1}: ${pred.label} · ${pred.score.toFixed(2)}`;group.append(text);});
}
function renderFaces(){
 $('#faces').innerHTML=current.dice.map((die,i)=>{const match=current.matches.find(m=>m.truthIndex===i),pred=match?current.predictions[match.predictionIndex]:null;const error=!match||!match.correctValue;return `<div class="face ${error?'error':''} ${selected===i?'active':''}" data-truth="${i}" tabindex="0" role="button" aria-label="Inspect face ${i+1}"><canvas class="crop" width="240" height="240" data-box="truth" data-index="${i}" aria-label="Enlarged approved face ${i+1}"></canvas><div><small>Face T${i+1}${match?` ↔ P${match.predictionIndex+1}`:''}</small><strong>${die.value} → ${pred?pred.label:'missed'}</strong><small class="result ${error?'fail':'pass'}">${!match?'No matching box':match.correctValue?'Correct':'Wrong value'}</small>${pred?`<small>Confidence ${percent(pred.score)}</small><small>Box IoU ${match.iou.toFixed(2)}</small>`:''}</div></div>`;}).join('');
 document.querySelectorAll('[data-truth]').forEach(e=>{e.onclick=()=>select(Number(e.dataset.truth));e.onkeydown=event=>{if(event.key==='Enter')select(Number(e.dataset.truth));};});
 $('#extras').innerHTML=current.extraPredictions.length?`<h3 class="extraheading">Extra detections</h3>`+current.extraPredictions.map(i=>{const p=current.predictions[i];return `<div class="face error"><canvas class="crop" width="240" height="240" data-box="prediction" data-index="${i}" aria-label="Enlarged extra detection"></canvas><div><small>Prediction P${i+1}</small><strong>Extra ${p.label}</strong><small>Confidence ${percent(p.score)}</small><small>No unclaimed face with IoU ≥ 0.5</small></div></div>`;}).join(''):'';
 $('#suppressedTitle').textContent=`${current.suppressed.length} below-cutoff detections`;
 $('#suppressed').innerHTML=current.suppressed.map(p=>`<div class="suppressedrow">Value ${p.label} · ${percent(p.score)} confidence</div>`).join('')||'<p class="help">None.</p>';
 crops();
}
function crops(){if(!image.complete||!image.naturalWidth||!image.src.includes(current.id))return;document.querySelectorAll('canvas.crop').forEach(canvas=>{const i=Number(canvas.dataset.index),box=canvas.dataset.box==='truth'?current.dice[i].box:current.predictions[i].box;const[x,y,w,h]=box,side=Math.max(w,h)*1.4,ctx=canvas.getContext('2d');ctx.fillStyle='#152018';ctx.fillRect(0,0,240,240);ctx.drawImage(image,x+w/2-side/2,y+h/2-side/2,side,side,0,0,240,240);});}
function select(i){selected=i;renderBoxes();renderFaces();}
function choose(){if(!canLeave()){$('#model').value=model.id;$('#filter').value=lastFilter;return;}model=data.models.find(m=>m.id===$('#model').value);const rows=visible();const id=rows.some(c=>c.id===current?.id)?current.id:rows[0]?.id;if(id)load(id);else renderList();}
function next(step){const rows=visible(),i=rows.findIndex(c=>c.id===current.id);if(rows[i+step])load(rows[i+step].id);}
$('#model').onchange=choose;$('#filter').onchange=choose;$('#prev').onclick=()=>next(-1);$('#next').onclick=()=>next(1);
$('#note').oninput=()=>{noteDirty=true;$('#saved').textContent='Unsaved';};
$('#saveNote').onclick=async()=>{const id=current.id;$('#saveNote').disabled=true;try{const response=await fetch(`/api/review-notes/${id}`,{method:'POST',headers:{'Content-Type':'application/json','X-DiceTower-Review':'1'},body:JSON.stringify({note:$('#note').value})});const saved=await response.json();if(!response.ok)throw Error(saved.error);data.reviewNotes[id]=saved;if(current.id===id){$('#saved').textContent='Saved locally';noteDirty=$('#note').value!==saved.note;}}catch(e){$('#saved').textContent=e.message;}finally{$('#saveNote').disabled=false;}};
$('#truth').onchange=renderBoxes;$('#predicted').onchange=renderBoxes;$('#frame').onclick=()=>{full=!full;frame();};$('#zoom').onclick=()=>{$('#well').classList.toggle('large');$('#zoom').textContent=$('#well').classList.contains('large')?'Fit view':'Enlarge';};
window.onbeforeunload=e=>{if(noteDirty){e.preventDefault();e.returnValue='';}};
document.onkeydown=e=>{if(['SELECT','INPUT','TEXTAREA'].includes(e.target.tagName))return;if(e.key==='ArrowRight')next(1);if(e.key==='ArrowLeft')next(-1);};
fetch('/api/results').then(r=>{if(!r.ok)throw Error('Could not load frozen test results');return r.json();}).then(d=>{data=d;$('.locked').textContent=data.truthVersion>1?`Audited labels v${data.truthVersion} · saved predictions`:'Frozen test · read only';model=d.models[0];const id=location.hash.slice(1);const wanted=model.captures.find(c=>c.id===id);if(wanted&&wanted.metrics.exactLocalized)$('#filter').value='all';load(wanted?.id||visible()[0].id);}).catch(e=>{$('section').textContent=e.message;});
