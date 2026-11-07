import {test,before,after,beforeEach} from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {initializeTestEnvironment,assertSucceeds,assertFails} from '@firebase/rules-unit-testing';
import {ref,set,get,query,orderByChild,limitToLast,serverTimestamp,update,remove} from 'firebase/database';
const enabled=Boolean(process.env.FIREBASE_DATABASE_EMULATOR_HOST);
let env;
before(async()=>{if(enabled)env=await initializeTestEnvironment({projectId:'demo-dicetower',database:{rules:fs.readFileSync('firebase/database.rules.json','utf8')}});});
after(async()=>{await env?.cleanup();});
beforeEach(async()=>{await env?.clearDatabase();});
function db(uid){return uid ? env.authenticatedContext(uid,{firebase:{sign_in_provider:'anonymous'}}).database():env.unauthenticatedContext().database();}
const profile={schemaVersion:1,name:'Table A',createdAt:serverTimestamp(),updatedAt:serverTimestamp(),sharing:true};
function event(){return {schemaVersion:1,eventId:'e1',rollId:'r1',kind:'roll',capturedAt:Date.now(),receivedAt:serverTimestamp(),modelSHA256:'a'.repeat(64),count:1,total:4,dice:[{value:4,confidence:.95,box:{x:.2,y:.2,width:.1,height:.1}}],thumbnail:'data:image/jpeg;base64,AA==',experimental:true};}
const check=(name,run)=>test(name,{skip:!enabled},run);
check('anonymous owners create towers; observers can list and read, but cannot overwrite',async()=>{
 await assertSucceeds(set(ref(db('owner'),'towers/owner'),profile));
 await assertSucceeds(get(query(ref(db('observer'),'towers'),orderByChild('updatedAt'),limitToLast(200))));
 await assertFails(get(ref(db(),'towers/owner')));
 await assertFails(set(ref(db('observer'),'towers/owner'),profile));
 await assertFails(get(ref(db('observer'),'towers')));
 await assertFails(set(ref(db('owner'),'towers/owner'),{...profile,name:'x'.repeat(61)}));
});
check('each tower writes only its own append-only stream; observers read bounded history',async()=>{
 await set(ref(db('owner'),'towers/owner'),profile);
 await assertSucceeds(set(ref(db('owner'),'rolls/owner/e1'),event()));
 const page=await assertSucceeds(get(query(ref(db('observer'),'rolls/owner'),orderByChild('capturedAt'),limitToLast(50))));
 assert.equal(page.child('e1/total').val(),4);
 await assertFails(set(ref(db('observer'),'rolls/owner/e2'),{...event(),eventId:'e2'}));
 await assertFails(update(ref(db('owner'),'rolls/owner/e1'),{total:5}));
 await assertFails(remove(ref(db('owner'),'rolls/owner/e1')));
 await assertFails(get(ref(db('observer'),'rolls/owner')));
 await assertFails(get(query(ref(db('observer'),'rolls/owner'),orderByChild('capturedAt'),limitToLast(101))));
});
check('invalid predictions, oversized snapshots and unknown fields are rejected; empty tray is valid',async()=>{
 await set(ref(db('owner'),'towers/owner'),profile);
 await assertFails(set(ref(db('owner'),'rolls/owner/e1'),{...event(),secret:'extra'}));
 await assertFails(set(ref(db('owner'),'rolls/owner/e1'),{...event(),thumbnail:'data:image/jpeg;base64,'+'A'.repeat(100001)}));
 const invalid=event();invalid.dice[0].value=7;
 await assertFails(set(ref(db('owner'),'rolls/owner/e1'),invalid));
 const empty={...event(),dice:[],count:0,total:0};
 await assertSucceeds(set(ref(db('owner'),'rolls/owner/e1'),empty));
});
function metric(id='m1') { return {schemaVersion:1,metricId:id,sessionId:'session',recordedAt:Date.now(),phase:'quiescent',inferenceMs:19.5,emaInferenceMs:21.2,processingMs:25.1,intervalMs:50,inferenceCount:2,agreementCount:2,settleMs:200,eventId:'e1'}; }
check('metrics have an independent owner-only stream with bounded observer reads and safe batch retries',async()=>{
 await set(ref(db('owner'),'towers/owner'),profile);
 const batch={m1:metric(),m2:metric('m2')};
 await assertSucceeds(update(ref(db('owner'),'metrics/owner'),batch));
 await assertSucceeds(update(ref(db('owner'),'metrics/owner'),batch));
 const page=await assertSucceeds(get(query(ref(db('observer'),'metrics/owner'),orderByChild('recordedAt'),limitToLast(100))));
 assert.equal(page.child('m1/emaInferenceMs').val(),21.2);
 await assertFails(update(ref(db('observer'),'metrics/owner'),{m3:metric('m3')}));
 await assertFails(update(ref(db('owner'),'metrics/owner/m1'),{inferenceMs:99}));
 await assertFails(remove(ref(db('owner'),'metrics/owner/m1')));
 await assertFails(get(ref(db('observer'),'metrics/owner')));
 await assertFails(get(ref(db(),'metrics/owner/m1')));
 await assertFails(get(query(ref(db('observer'),'metrics/owner'),orderByChild('recordedAt'),limitToLast(201))));
});
check('metrics reject unsupported cadence, extra fields and wrong metric IDs',async()=>{
 await set(ref(db('owner'),'towers/owner'),profile);
 await assertFails(set(ref(db('owner'),'metrics/owner/m1'),{...metric(),intervalMs:75}));
 await assertFails(set(ref(db('owner'),'metrics/owner/m1'),{...metric(),eventId:'x'.repeat(65)}));
 await assertFails(set(ref(db('owner'),'metrics/owner/m1'),{...metric(),secret:'extra'}));
 await assertFails(set(ref(db('owner'),'metrics/owner/m1'),{...metric(),metricId:'different'}));
});
check('duplicate discards are owner-only immutable metrics, with legacy retries preserved',async()=>{
 await set(ref(db('owner'),'towers/owner'),profile);
 const legacy=metric();await assertSucceeds(set(ref(db('owner'),'metrics/owner/m1'),legacy));
 await assertSucceeds(set(ref(db('owner'),'metrics/owner/m1'),legacy));
 const duplicate={...metric('m2'),eventId:'',duplicateDiscarded:true,duplicateCount:1,duplicateOfEventId:'e1'};
 await assertSucceeds(set(ref(db('owner'),'metrics/owner/m2'),duplicate));
 await assertSucceeds(set(ref(db('owner'),'metrics/owner/m2'),duplicate));
 assert.equal((await get(ref(db('observer'),'metrics/owner/m2'))).val().duplicateOfEventId,'e1');
 await assertFails(update(ref(db('owner'),'metrics/owner/m2'),{duplicateCount:2}));
 await assertFails(update(ref(db('owner'),'metrics/owner/m1'),{duplicateCount:0,duplicateDiscarded:false,duplicateOfEventId:''}));
 await assertFails(set(ref(db('observer'),'metrics/owner/m3'),{...duplicate,metricId:'m3'}));
});
check('malformed duplicate counts, links and states cannot pollute the stream',async()=>{
 await set(ref(db('owner'),'towers/owner'),profile);
 const duplicate={...metric(),eventId:'',duplicateDiscarded:true,duplicateCount:1,duplicateOfEventId:'e1'};
 for(const extra of [{duplicateCount:-1},{duplicateCount:.5},{duplicateCount:0},{duplicateOfEventId:''},{duplicateOfEventId:'x'.repeat(65)},{duplicateDiscarded:'yes'},{eventId:'e2'},{phase:'active'},{agreementCount:1}])await assertFails(set(ref(db('owner'),'metrics/owner/m1'),{...duplicate,...extra}));
 await assertFails(set(ref(db('owner'),'metrics/owner/m1'),{...metric(),duplicateCount:1}));
});
check('upload health is bounded, owner-only and immutable, while legacy metrics still work',async()=>{
 await set(ref(db('owner'),'towers/owner'),profile);
 const warning={...metric(),uploadHeldCount:2,uploadIssue:'Roll ABC: Firebase request failed (403).'};
 await assertSucceeds(set(ref(db('owner'),'metrics/owner/m1'),warning));
 await assertSucceeds(set(ref(db('owner'),'metrics/owner/m1'),warning));
 await assertFails(update(ref(db('owner'),'metrics/owner/m1'),{uploadHeldCount:3}));
 for(const extra of [{uploadHeldCount:-1},{uploadHeldCount:.5},{uploadIssue:'x'.repeat(201)},{uploadIssue:3}])await assertFails(set(ref(db('owner'),'metrics/owner/m2'),{...warning,metricId:'m2',...extra}));
 await assertFails(set(ref(db('observer'),'metrics/owner/m2'),{...warning,metricId:'m2'}));
 await assertFails(set(ref(db('owner'),'metrics/owner/m2'),{...metric('m2'),uploadHeldCount:1}));
});

check('delivery diagnostics are bounded owner-only immutable metrics; confidence overflow stays rejected',async()=>{
 await set(ref(db('owner'),'towers/owner'),profile);
 const status={...metric(),eventId:'',deliveryEventId:'e1',deliveryState:'rejected',deliveryValues:'1,3,4,3',deliveryDetail:'Invalid dice[2].confidence',deliveryAt:Date.now()};
 await assertSucceeds(set(ref(db('owner'),'metrics/owner/m1'),status));
 await assertSucceeds(set(ref(db('owner'),'metrics/owner/m1'),status));
 await assertFails(update(ref(db('owner'),'metrics/owner/m1'),{deliveryState:'delivered'}));
 for(const extra of [{deliveryState:'unknown'},{deliveryValues:'7'},{deliveryEventId:''},{deliveryDetail:'x'.repeat(201)}])await assertFails(set(ref(db('owner'),'metrics/owner/m2'),{...status,metricId:'m2',...extra}));
 await assertFails(set(ref(db('observer'),'metrics/owner/m2'),{...status,metricId:'m2'}));
 const overflow=event();overflow.dice[0].confidence=1.0000001192092896;
 await assertFails(set(ref(db('owner'),'rolls/owner/e1'),overflow));
 overflow.dice[0].confidence=1;await assertSucceeds(set(ref(db('owner'),'rolls/owner/e1'),overflow));
});
