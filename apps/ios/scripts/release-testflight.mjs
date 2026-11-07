#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawn,execFileSync} from 'node:child_process';
import {configuration,request,app} from './app-store-connect.mjs';

const ios=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const repo=path.resolve(ios,'../..');
const developer=process.env.DICETOWER_XCODE_DEVELOPER_DIR||'/Applications/Xcode.app/Contents/Developer';
const c=configuration();
const version=process.env.DICETOWER_MARKETING_VERSION||'0.1.0';
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));

async function command(program,args,log) {
  const fd=fs.openSync(log,'a');
  try {
    await new Promise((resolve,reject)=>{
      const child=spawn(program,args,{cwd:repo,env:{...process.env,DEVELOPER_DIR:developer},stdio:['ignore',fd,fd]});
      child.once('error',reject);
      child.once('exit',code=>code===0?resolve():reject(new Error(`${path.basename(program)} exited ${code}; inspect ${log}`)));
    });
  } finally {fs.closeSync(fd);}
}

async function assignTester(groupID) {
  const encoded=encodeURIComponent(c.tester);
  const users=await request('GET',`/v1/users?filter%5Busername%5D=${encoded}&limit=1`);
  if(!users.data.length)throw new Error('The configured internal tester is not an accepted App Store Connect user.');
  const testers=await request('GET',`/v1/betaTesters?filter%5Bemail%5D=${encoded}&limit=200`);
  const link={data:[{type:'betaGroups',id:groupID}]};
  for(const tester of testers.data) {
    const groups=await request('GET',`/v1/betaTesters/${tester.id}/relationships/betaGroups?limit=200`);
    if(groups.data.some(g=>g.id===groupID))return tester.id;
    try {await request('POST',`/v1/betaTesters/${tester.id}/relationships/betaGroups`,link);return tester.id;}catch {/* Another app-scoped tester identity may be needed. */}
  }
  const user=users.data[0].attributes;
  const result=await request('POST','/v1/betaTesters',{data:{type:'betaTesters',attributes:{email:c.tester,firstName:user.firstName,lastName:user.lastName},relationships:{betaGroups:link}}});
  return result.data.id;
}

async function main() {
  const a=await app();
  const builds=a?await request('GET',`/v1/builds?filter%5Bapp%5D=${a.id}&limit=200`):{data:[]};
  const number=process.env.DICETOWER_BUILD_NUMBER||String(Math.max(0,...builds.data.map(b=>Number(b.attributes.version)||0))+1);
  if(!/^\d+$/.test(number))throw new Error('Invalid build number');
  const root=path.join(ios,'DerivedData','TestFlight',number);
  const archive=path.join(root,'DiceTower.xcarchive');
  fs.mkdirSync(root,{recursive:true});
  const auth=['-allowProvisioningUpdates','-authenticationKeyPath',c.keyPath,'-authenticationKeyID',c.key,'-authenticationKeyIssuerID',c.issuer];
  if(!fs.existsSync(archive)) {
    console.log(`Archiving DiceTower Capture ${version} (${number})…`);
    await command('/bin/bash',[path.join(ios,'scripts/generate-project.sh')],path.join(root,'generate.log'));
    await command(path.join(developer,'usr/bin/xcodebuild'),['archive','-project',path.join(ios,'DiceTower.xcodeproj'),'-scheme','DiceTower','-configuration','Release','-destination','generic/platform=iOS','-archivePath',archive,'-derivedDataPath',path.join(root,'DerivedData'),...auth,`DEVELOPMENT_TEAM=${c.team}`,`CURRENT_PROJECT_VERSION=${number}`,`MARKETING_VERSION=${version}`],path.join(root,'archive.log'));
  }
  const application=path.join(archive,'Products/Applications/DiceTower.app');
  const plist=path.join(application,'Info.plist');
  const field=name=>execFileSync('/usr/bin/plutil',['-extract',name,'raw',plist],{encoding:'utf8'}).trim();
  if(field('CFBundleIdentifier')!==c.bundle || field('CFBundleVersion')!==number || field('CFBundleShortVersionString')!==version || field('ITSAppUsesNonExemptEncryption')!=='false')throw new Error('Archived app identity/version/encryption declaration mismatch');
  await command('/usr/bin/codesign',['--verify','--deep','--strict',application],path.join(root,'signing-verification.log'));
  if(process.argv.includes('--archive-only')) {console.log(`Signed archive ready: ${archive}`);return;}
  const appRecord=a||await app();
  if(!appRecord)throw new Error('Signed archive is ready. Create the DiceTower Capture app record with bundle org.boardgamescafe.dicetower and SKU dicetower-ios, then rerun with DICETOWER_BUILD_NUMBER='+number);
  console.log(`Uploading ${version} (${number})…`);
  if(!fs.existsSync(path.join(root,'upload-succeeded'))) {
    await command(path.join(developer,'usr/bin/xcodebuild'),['-exportArchive','-archivePath',archive,'-exportPath',path.join(root,'export'),'-exportOptionsPlist',path.join(ios,'Config/TestFlightExportOptions.plist'),...auth],path.join(root,'upload.log'));
    fs.writeFileSync(path.join(root,'upload-succeeded'),new Date().toISOString());
  }
  let build;
  for(let attempt=0;attempt<80;attempt++) {
    const result=await request('GET',`/v1/builds?filter%5Bapp%5D=${appRecord.id}&filter%5Bversion%5D=${number}&limit=1`);
    build=result.data[0];
    if(build?.attributes.processingState==='VALID')break;
    if(['FAILED','INVALID'].includes(build?.attributes.processingState))throw new Error('Apple rejected the build during processing');
    console.log('Waiting for Apple processing…');await delay(15000);
  }
  if(build?.attributes.processingState!=='VALID')throw new Error('Apple processing timed out; rerun with the same build number to check again.');
  if(build.attributes.usesNonExemptEncryption!==false)await request('PATCH',`/v1/builds/${build.id}`,{data:{type:'builds',id:build.id,attributes:{usesNonExemptEncryption:false}}});
  let groups=await request('GET',`/v1/betaGroups?filter%5Bapp%5D=${appRecord.id}&filter%5BisInternalGroup%5D=true&limit=200`);
  let group=groups.data.find(g=>g.attributes.name==='Internal');
  if(!group)group=(await request('POST','/v1/betaGroups',{data:{type:'betaGroups',attributes:{name:'Internal',isInternalGroup:true,feedbackEnabled:true},relationships:{app:{data:{type:'apps',id:appRecord.id}}}}})).data;
  const linked=await request('GET',`/v1/betaGroups/${group.id}/relationships/builds?limit=200`);
  if(!linked.data.some(b=>b.id===build.id))await request('POST',`/v1/betaGroups/${group.id}/relationships/builds`,{data:[{type:'builds',id:build.id}]});
  const testerID=await assignTester(group.id);
  const testers=await request('GET',`/v1/betaGroups/${group.id}/betaTesters?limit=200`);
  if(!testers.data.some(t=>t.id===testerID))throw new Error('Apple did not confirm internal tester membership.');
  const notes='Mount the iPhone above the tray with all edges visible. Adjust the dashed tray area in Capture settings. Start auto capture: the first still scene is saved, including an empty tray. Roll or rearrange the dice and keep hands out until the saved counter increases. No dice count is needed. Pause before adjusting the rig. Use + for a new session with notes about dice, lighting, and mount height. Share exports the original JPEGs and metadata as a ZIP for later labeling. Everything stays on your phone until you export. No dice-recognition model is included in this capture build.';
  const localizations=await request('GET',`/v1/builds/${build.id}/betaBuildLocalizations`);
  if(!localizations.data.length)await request('POST','/v1/betaBuildLocalizations',{data:{type:'betaBuildLocalizations',attributes:{locale:'en-CA',whatsNew:notes},relationships:{build:{data:{type:'builds',id:build.id}}}}});
  const detail=await request('GET',`/v1/builds/${build.id}/buildBetaDetail`);
  const report={appID:appRecord.id,buildID:build.id,version,buildNumber:number,processingState:'VALID',betaDetails:detail.data.attributes,testflightGroup:'Internal',configuredTesterConfirmed:true,completedAt:new Date().toISOString(),commit:execFileSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).trim()};
  fs.writeFileSync(path.join(root,'release.json'),JSON.stringify(report,null,2));
  console.log(JSON.stringify(report,null,2));
}
main().catch(error=>{console.error(error.message);process.exit(1);});
