import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import {execFileSync} from 'node:child_process';
const root=process.cwd(), dist=path.join(root,'apps/web/dist');
if(!fs.existsSync(path.join(dist,'index.html')))throw new Error('Run npm run build first.');
const source=execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim();
const remote=execFileSync('git',['remote','get-url','origin'],{encoding:'utf8'}).trim();
if(remote!=='https://github.com/anicolao/dicetower.git')throw new Error('Unexpected deploy repository');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'dicetower-pages-'));
try {
 execFileSync('git',['init','-b','gh-pages',temp]);
 execFileSync('git',['remote','add','origin',remote],{cwd:temp});
 let exists=false;
 try {execFileSync('git',['fetch','--depth=1','origin','gh-pages'],{cwd:temp,stdio:'pipe'});exists=true;}catch(error){if(!String(error.stderr).includes("couldn't find remote ref"))throw error;}
 if(exists)execFileSync('git',['reset','--hard','FETCH_HEAD'],{cwd:temp});
 for(const name of fs.readdirSync(temp))if(name!=='.git')fs.rmSync(path.join(temp,name),{recursive:true,force:true});
 fs.cpSync(dist,temp,{recursive:true});fs.writeFileSync(path.join(temp,'.nojekyll'),'');
 fs.writeFileSync(path.join(temp,'version.json'),JSON.stringify({sourceCommit:source,builtAt:new Date().toISOString()})+'\n');
 execFileSync('git',['add','.'],{cwd:temp});
 execFileSync('git',['commit','--allow-empty','-m',`Deploy DiceTower observer from ${source.slice(0,7)}`],{cwd:temp});
 execFileSync('git',['push','origin','HEAD:gh-pages'],{cwd:temp,stdio:'inherit'});
 console.log('Published observer source to gh-pages. GitHub Pages performs the final deployment.');
} finally {fs.rmSync(temp,{recursive:true,force:true});}
