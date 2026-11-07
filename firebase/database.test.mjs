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
