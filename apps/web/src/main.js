import {initializeApp} from 'firebase/app';
import {getAuth, signInAnonymously, onAuthStateChanged} from 'firebase/auth';
import {getDatabase, ref, onValue, query, orderByChild, limitToLast, endBefore, get} from 'firebase/database';
import config from '../../../firebase/client-config.json';
import {normalizeEvent, mergeEvents, towerLink} from './events.js';
import './style.css';
import {sortedMetrics,displayMs} from './metrics.js';

const $ = id => document.getElementById(id);
const app = initializeApp(config), auth = getAuth(app), db = getDatabase(app);
let metricSamples = [], unsubscribeMetrics;
let towers = {}, selected = new URL(location.href).searchParams.get('tower'), events = [], unsubscribe, selection = 0, canLoadOlder = false;
const clock = new Intl.DateTimeFormat(undefined,{hour:'numeric',minute:'2-digit',second:'2-digit'});
const date = new Intl.DateTimeFormat(undefined,{month:'short',day:'numeric',year:'numeric'});
function text(tag, value, className) { const node = document.createElement(tag); node.textContent = value; if(className) node.className = className; return node; }
function showError(message) { $('error').textContent = message; $('error').hidden = !message; }
function active(tower) { return tower.sharing && Date.now() - tower.updatedAt < 120000; }
function renderTowers() {
  const search = $('tower-search').value.toLocaleLowerCase();
  const entries = Object.entries(towers).sort((a,b)=>b[1].updatedAt-a[1].updatedAt).filter(([,t])=>t.name.toLocaleLowerCase().includes(search));
  $('tower-count').textContent = Object.keys(towers).length;
  $('tower-list').replaceChildren();
  for (const [id, tower] of entries) {
    const link = document.createElement('a'); link.href = towerLink(id); link.className = 'tower' + (selected===id ? ' selected':'');
    if (selected===id) link.setAttribute('aria-current','page');
    const body = document.createElement('div'); body.append(text('strong',tower.name),text('small',`${active(tower) ? 'Live now' : tower.sharing ? 'Away' : 'Sharing paused'} · ${id.slice(-6)}`));
    link.append(text('span','',`tower-light ${active(tower)?'active':''}`),body,text('span','↗','tower-arrow'));
    link.addEventListener('click',event=>{if(event.metaKey||event.ctrlKey||event.shiftKey||event.button!==0)return;event.preventDefault();history.pushState({},'',link.href);selectTower(id);});
    $('tower-list').append(link);
  }
  if (!entries.length) $('tower-list').append(text('p',search?'No matching towers.':'No towers yet. Name yours in the iPhone app.','muted'));
  renderHeading();
}
function renderHeading() {
  const tower = towers[selected];
  $('tower-title').textContent = tower?.name || (selected?'Looking for your tower…':'A seat at every table.');
  $('tower-description').textContent = tower ? `${active(tower)?'Live from the tray':tower.sharing?'Waiting for the tower to reconnect':'Sharing is paused'} · Tower ${selected.slice(-6)}` : selected?'This tower may be new, offline, or no longer listed.':'Your physical dice, one roll at a time.';
  document.title = tower ? `${tower.name} · DiceTower` : 'DiceTower · Live rolls';
  $('open-tab').hidden = !selected; if(selected) $('open-tab').href = towerLink(selected);
}
function snapshot(event, loading='lazy') {
  const container = document.createElement('div'); container.className = 'snapshot';
  const image = document.createElement('img'); image.src = event.thumbnail; image.loading=loading; image.alt=`Tray snapshot: ${event.dice.map(d=>d.value).join(', ') || 'no dice detected'}`;
  container.append(image);
  for(const die of event.dice) {
    const box = document.createElement('span'); box.className='detection'; box.style.left=`${die.box.x*100}%`;box.style.top=`${die.box.y*100}%`;box.style.width=`${die.box.width*100}%`;box.style.height=`${die.box.height*100}%`;
    box.setAttribute('aria-hidden','true'); const value=text('b',die.value);value.title=`Confidence ${(die.confidence*100).toFixed(0)}%`;box.append(value);container.append(box);
  }
  return container;
}
function renderFeed() {
  $('roll-feed').replaceChildren();
  $('empty').hidden=events.length>0;
  $('empty-title').textContent = selected?'Waiting for the next roll':'Find your DiceTower';
  $('empty-description').textContent=selected?'Keep sharing enabled in the iPhone app, then roll the dice and let them settle. The first snapshot will appear here.':'Pick a named tower on the left. Its snapshots and dice results will appear here as they arrive.';
  $('feed-count').textContent = selected ? `${events.length} event${events.length===1?'':'s'} loaded` : 'Select a tower';
  const latest=events[0];
  $('latest-dice').textContent=latest?.count ?? '—';$('latest-total').textContent=latest?.total ?? '—';$('latest-time').textContent=latest?clock.format(latest.capturedAt):'—';
  for(const [index,event] of events.entries()) {
    const card = document.createElement('article');card.className='roll-card';card.dataset.eventId=event.eventId;
    const heading=document.createElement('div');heading.className='card-heading';
    const timestamp=text('time',clock.format(event.capturedAt));timestamp.dateTime=new Date(event.capturedAt).toISOString();timestamp.title=new Date(event.capturedAt).toLocaleString();
    heading.append(timestamp,text('span',event.kind==='recognitionChanged'?'Recognition update':index===0?'Latest roll':'Roll',`badge ${event.kind==='recognitionChanged'?'revision':''}`));
    const preview=document.createElement('button');preview.className='snapshot-button';preview.setAttribute('aria-label',`Enlarge snapshot at ${clock.format(event.capturedAt)}`);preview.append(snapshot(event,index<3?'eager':'lazy'));
    preview.onclick=()=>{$('snapshot-content').replaceChildren(snapshot(event,'eager'),text('p',`${date.format(event.capturedAt)} · ${clock.format(event.capturedAt)} · ${event.count} dice · Total ${event.total}`));$('snapshot-dialog').showModal();};
    const result=document.createElement('div');result.className='result';const faces=document.createElement('div');faces.className='faces';
    for (const die of event.dice) faces.append(text('span',die.value,'face'));if(!event.dice.length)faces.append(text('span','No dice detected','muted'));
    result.append(faces,text('strong',`Σ ${event.total}`,'total'));
    const detail=document.createElement('div');detail.className='card-detail';detail.append(text('span',`${event.count} dice · ${date.format(event.capturedAt)}`),text('span',`Roll ${event.rollId.slice(-6)}`));
    const timing=metricSamples.find(m=>m.eventId===event.eventId);
    if(timing)detail.append(text('span',`Inference ${displayMs(timing.inferenceMs)} · EMA ${displayMs(timing.emaInferenceMs)}`));
    card.append(heading,preview,result,detail);$('roll-feed').append(card);
  }
  $('load-older').hidden=!selected||!canLoadOlder;
}
function selectTower(id) {
  selected=id;events=[];metricSamples=[];selection++;unsubscribe?.();unsubscribeMetrics?.();renderMetrics();canLoadOlder=false;renderTowers();renderFeed();showError('');
  if(!id)return;
  const epoch=selection;
  unsubscribeMetrics=onValue(query(ref(db,`metrics/${id}`),orderByChild('recordedAt'),limitToLast(100)),snapshot=>{
    if(epoch!==selection)return;
    metricSamples=sortedMetrics(snapshot.val());renderMetrics();renderFeed();
  },error=>showError(`Could not load timing metrics: ${error.message}`));
  unsubscribe=onValue(query(ref(db,`rolls/${id}`),orderByChild('capturedAt'),limitToLast(50)),snapshot=>{
    if(epoch!==selection)return;
    const rows=Object.entries(snapshot.val()||{}).map(([key,event])=>normalizeEvent(key,event));
    events=mergeEvents(events,rows);canLoadOlder=rows.length===50;renderFeed();
  },error=>showError(`Could not load this stream: ${error.message}`));
}
function renderMetrics() {
  const latest=metricSamples[0];
  $('metrics-state').textContent=latest ? (latest.phase==='quiescent'?'Watching for motion · ML idle':latest.phase) : 'Waiting for metrics';
  $('metrics-state').classList.toggle('idle',latest?.phase==='quiescent');
  for(const [key,id] of [['inferenceMs','metric-inference'],['emaInferenceMs','metric-ema'],['processingMs','metric-processing'],['intervalMs','metric-interval']]) $(''+id).textContent=latest && (latest.inferenceCount>0 || key==='intervalMs') ? displayMs(latest[key]) : '—';
  $('metrics-summary').textContent=latest ? `${latest.inferenceCount} inferences · ${latest.agreementCount}/2 agree · ${latest.settleMs} ms settlement · Sample ${clock.format(latest.recordedAt)} · Session ${latest.sessionId.slice(-6)}` : 'New app builds publish timings separately from roll images.';
  $('metrics-samples').replaceChildren();
  for(const sample of metricSamples.slice(0,30)) {
    const row=document.createElement('tr');
    for(const value of [clock.format(sample.recordedAt),sample.phase,displayMs(sample.inferenceMs),displayMs(sample.emaInferenceMs),displayMs(sample.processingMs),`${sample.intervalMs} ms`,sample.inferenceCount,`${sample.agreementCount}/2`,`${sample.settleMs} ms`,sample.eventId?sample.eventId.slice(-6):'—'])row.append(text('td',value));
    $('metrics-samples').append(row);
  }
}
$('tower-search').addEventListener('input',renderTowers);
$('close-snapshot').onclick=()=>$('snapshot-dialog').close();
$('snapshot-dialog').onclick=event=>{if(event.target===$('snapshot-dialog'))$('snapshot-dialog').close();};
window.addEventListener('popstate',()=>selectTower(new URL(location.href).searchParams.get('tower')));
$('load-older').onclick=async()=>{
  const oldest=events.at(-1),epoch=selection;if(!oldest)return;
  $('load-older').disabled=true;
  try {
    const page=await get(query(ref(db,`rolls/${selected}`),orderByChild('capturedAt'),endBefore(oldest.capturedAt,oldest.eventId),limitToLast(50)));
    if(epoch!==selection)return;
    const rows=Object.entries(page.val()||{}).map(([id,event])=>normalizeEvent(id,event));events=mergeEvents(events,rows);canLoadOlder=rows.length===50;renderFeed();
  }catch(error){showError(`Could not load older rolls: ${error.message}`);}finally{$('load-older').disabled=false;}
};
try {
  await new Promise((resolve,reject)=>{const stop=onAuthStateChanged(auth,async user=>{stop();if(user)resolve();else signInAnonymously(auth).then(resolve,reject);},reject);});
  onValue(ref(db,'.info/connected'),snapshot=>{$('connection').textContent=snapshot.val()?'Connected · live updates':'Reconnecting…';$('connection').classList.toggle('online',Boolean(snapshot.val()));});
  onValue(query(ref(db,'towers'),orderByChild('updatedAt'),limitToLast(200)),snapshot=>{
    towers=Object.fromEntries(Object.entries(snapshot.val()||{}).filter(([,t])=>typeof t.name==='string'&&Number.isFinite(t.updatedAt)));renderTowers();
  },error=>showError(`Could not list towers: ${error.message}`));
  selectTower(selected);setInterval(renderTowers,30000);
}catch(error){$('connection').textContent='Connection unavailable';showError(`Anonymous sign-in failed: ${error.message}. Reload to try again.`);}
