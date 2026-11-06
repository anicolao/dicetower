#!/usr/bin/env node
// Credentials stay in the owner's existing external handoff; never print JWTs.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';

export function configuration() {
  const file = process.env.DICETOWER_APPLE_CONFIG || path.join(os.homedir(), '.config/hunger/testflight.env');
  const bytes = execFileSync('/bin/bash', ['-c', 'set +x; set -a; source "$1"; env -0', 'handoff', file]);
  const values = Object.fromEntries(bytes.toString().split('\0').filter(Boolean).map(line => {
    const i = line.indexOf('='); return [line.slice(0, i), line.slice(i + 1)];
  }));
  const pick = name => process.env[`DICETOWER_${name}`] || values[`HUNGER_${name}`];
  return {team:pick('APPLE_TEAM_ID'), key:pick('ASC_KEY_ID'), issuer:pick('ASC_ISSUER_ID'),
    keyPath:pick('ASC_KEY_PATH'), tester:pick('TESTFLIGHT_TESTER_EMAIL'), bundle:'org.boardgamescafe.dicetower'};
}

export async function request(method, endpoint, body) {
  const c = configuration();
  const now = Math.floor(Date.now()/1000);
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const unsigned = encode({alg:'ES256', kid:c.key, typ:'JWT'})+'.'+encode({iss:c.issuer,iat:now-5,exp:now+600,aud:'appstoreconnect-v1'});
  const signature = crypto.sign('sha256',Buffer.from(unsigned),{key:crypto.createPrivateKey(fs.readFileSync(c.keyPath)),dsaEncoding:'ieee-p1363'}).toString('base64url');
  const response = await fetch('https://api.appstoreconnect.apple.com'+endpoint,{
    method, headers:{Authorization:'Bearer '+unsigned+'.'+signature,'Content-Type':'application/json'},
    body:body?JSON.stringify(body):undefined
  });
  const text = await response.text();
  if(!response.ok) throw new Error(`App Store Connect ${response.status}: ${text}`);
  return text?JSON.parse(text):{};
}

export async function app() {
  const c=configuration();
  const response=await request('GET',`/v1/apps?filter%5BbundleId%5D=${encodeURIComponent(c.bundle)}&limit=1`);
  return response.data[0];
}

async function main() {
  const action=process.argv[2];const c=configuration();
  if(action==='register') {
    let response=await request('GET',`/v1/bundleIds?filter%5Bidentifier%5D=${c.bundle}&limit=1`);
    if(!response.data.length) response=await request('POST','/v1/bundleIds',{data:{type:'bundleIds',attributes:{identifier:c.bundle,name:'DiceTower Capture',platform:'IOS'}}});
    console.log('Bundle registered:',c.bundle);
    console.log('App record:',(await app())?.id || 'not created yet');
  } else if(action==='status') {
    const a=await app();
    if(!a){console.log('App record not created yet');return;}
    const builds=await request('GET',`/v1/builds?filter%5Bapp%5D=${a.id}&limit=10&sort=-uploadedDate`);
    console.log(JSON.stringify({appId:a.id,name:a.attributes.name,builds:builds.data.map(b=>({id:b.id,...b.attributes}))},null,2));
  } else {throw new Error('Use register or status');}
}
if(process.argv[1]===fileURLToPath(import.meta.url)) main().catch(error=>{console.error(error.message);process.exit(1);});
