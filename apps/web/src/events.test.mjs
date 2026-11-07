import {test} from 'node:test';
import assert from 'node:assert/strict';
import {normalizeEvent,mergeEvents,towerLink} from './events.js';
const face = {value:4,confidence:0.9,box:{x:0.2,y:0.2,width:0.1,height:0.1}};
const event = {schemaVersion:1,eventId:'a',rollId:'r',kind:'roll',capturedAt:100,count:1,total:4,dice:[face],thumbnail:'data:image/jpeg;base64,AA=='};
test('accepts an event and an empty tray, rejects mismatched conclusions or unsafe images',()=>{
 assert.equal(normalizeEvent('a',event).total,4);
 assert.equal(normalizeEvent('b',{...event,count:0,total:0,dice:undefined}).count,0);
 assert.equal(normalizeEvent('b',{...event,total:6}),null);
 assert.equal(normalizeEvent('b',{...event,count:2}),null);
 assert.equal(normalizeEvent('b',{...event,thumbnail:'javascript:alert(1)'}),null);
 assert.equal(normalizeEvent('b',{...event,dice:[{...face,box:{...face.box,x:0.95}}]}),null);
});
test('live updates and pagination merge idempotently in capture order',()=>{
 const e=normalizeEvent('a',event),newer={...e,eventId:'b',capturedAt:200};
 assert.deepEqual(mergeEvents([e],[newer,e,null]).map(x=>x.eventId),['b','a']);
});
test('tower URLs isolate selection and preserve the GitHub Pages base path',()=>{
 assert.equal(towerLink('tower-two','https://anicolao.github.io/dicetower/?tower=tower-one#old'),'https://anicolao.github.io/dicetower/?tower=tower-two');
});
