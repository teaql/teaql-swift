#!/usr/bin/env node
'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),cp=require('node:child_process'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {createOwnedRunner,ownedBytes}=require('../FixEAlignment/owned-command.cjs');
const EXAMPLE=__dirname,REPO=path.resolve(EXAMPLE,'../..'),PROFILES=['camelCase','snake_case','PascalCase'],LANGUAGE="swift";
const ORIGIN=path.resolve(process.env.TEAQL_SWIFT_EXAMPLE_SOURCE_ROOT||REPO);
const sha=b=>crypto.createHash('sha256').update(b).digest('hex'),digest=f=>sha(fs.readFileSync(f));
function sourceHash(root=REPO){
 assert.equal(fs.realpathSync(root),root,'runtime source must not traverse symlink aliases');
 const names=[...new Set(cp.execFileSync('git',['-C',ORIGIN,'ls-files','-z','--cached','--others','--exclude-standard']).toString().split('\0').filter(Boolean))].sort(),h=crypto.createHash('sha256');
 for(const n of names){assert(!path.isAbsolute(n)&&!n.split('/').includes('..'));const f=path.join(root,n);assert.equal(fs.realpathSync(f),f);const s=fs.lstatSync(f);assert(s.isFile()&&!s.isSymbolicLink());h.update(n+'\0'+String(s.mode)+'\0');h.update(fs.readFileSync(f));h.update('\0');}return h.digest('hex');
}
function sourceIdentity(){
 const body=sourceHash();assert.equal(body,sourceHash(ORIGIN),'isolated runtime differs from its actual Git source');
 return{commit:cp.execFileSync('git',['-C',ORIGIN,'rev-parse','HEAD'],{encoding:'utf8'}).trim(),sourceContentsSha256:body};
}
function fixture(){
 const root=path.join(EXAMPLE,'generated'),manifest=JSON.parse(fs.readFileSync(path.join(root,'manifest.json'))),provenance=JSON.parse(fs.readFileSync(path.join(EXAMPLE,'provenance.json')));
 assert.equal(manifest.schema,'teaql.generated-expression-model-profiles/v1');assert.equal(manifest.language,"swift");assert.equal(manifest.localSourceOnly,true);
 assert.equal(digest(path.join(root,'manifest.json')),provenance.manifestSha256);assert.deepEqual(Object.keys(manifest.profiles).sort(),[...PROFILES].sort());
 for(const[p,v]of Object.entries(manifest.profiles)){assert.deepEqual(v.evaluation.errors,[]);assert.equal(digest(path.join(root,p,'model.xml')),v.modelSha256);
  for(const[n,h]of Object.entries(v.files)){const f=path.resolve(root,p,n);assert(f.startsWith(path.join(root,p)+path.sep));assert.equal(fs.realpathSync(f),f);assert.equal(digest(f),h);}}
 return{manifest,provenance,provenanceSha256:digest(path.join(EXAMPLE,'provenance.json'))};
}
async function main(){
 const requested=process.env.TEAQL_GENERATED_E_PROFILE_EVIDENCE_DIR,output=requested?path.resolve(requested):fs.mkdtempSync(path.join(os.tmpdir(),'teaql-'+LANGUAGE+'-expression-evidence-'));
 if(requested){assert(path.isAbsolute(requested)&&!fs.existsSync(output));fs.mkdirSync(output,{recursive:true});}
 const report={schema:'teaql.'+LANGUAGE+'-generated-e-model-profiles/v1',passed:false,localSourceOnly:true,publicPublication:false,installedArtifactAccepted:false,completeExampleInventoryAccepted:false,allP0P1Complete:false,commands:[],profiles:{}};
 let scratch,runner;
 try{
  const disk=fs.statfsSync(os.tmpdir());assert(disk.bavail*disk.bsize>8*1024**3);
  report.sourceBefore=sourceIdentity();report.executionSource={path:REPO,origin:ORIGIN,sourceContentsSha256:report.sourceBefore.sourceContentsSha256};report.fixture=fixture();report.controllerSha256=digest(__filename);
  scratch=fs.mkdtempSync(path.join(os.tmpdir(),'teaql-'+LANGUAGE+'-expression-build-'));runner=createOwnedRunner();
  const env={...process.env,TMPDIR:scratch};
  async function run(profile,name,command,cwd,timeout=300000){
   const folder=path.join(output,profile);fs.mkdirSync(folder,{recursive:true});const file=path.join(folder,name+'.log'),fd=fs.openSync(file,'wx');let result;
   try{result=await runner.run(command,{cwd,env,timeout,stdio:['ignore',fd,fd]});}finally{fs.closeSync(fd);}
   const log=fs.readFileSync(file,'utf8');report.commands.push({profile,name,command,exitCode:result.status,signal:result.signal,logSha256:digest(file)});
   assert.equal(result.status,0,log.slice(-6000));assert.equal(result.signal,null);assert(runner.safeToClean);return log;
  }
  for(const profile of PROFILES){
   const work=path.join(scratch,profile);fs.mkdirSync(work);env.TEAQL_EXPRESSION_PROFILE=profile;env.TEAQL_EXPRESSION_DB=path.join(output,profile,'fixture.sqlite');
   fs.mkdirSync(path.join(output,profile));const state={rounds:[],sameDatabase:true};report.profiles[profile]=state;


   const generated=path.join(work,'generated');fs.cpSync(path.join(EXAMPLE,'generated',profile),generated,{recursive:true});
   fs.mkdirSync(path.join(work,'Sources/ExpressionProfiles'),{recursive:true});fs.copyFileSync(path.join(EXAMPLE,'main.swift'),path.join(work,'Sources/ExpressionProfiles/main.swift'));report.applicationSha256=digest(path.join(EXAMPLE,'main.swift'));
   const manifest='// swift-tools-version: 6.0\nimport PackageDescription\nlet package=Package(name:"ExpressionProfiles",dependencies:[.package(name:"teaql-swift",path:'+JSON.stringify(REPO)+')],targets:[.target(name:"GeneratedTeaQL",dependencies:[.product(name:"TeaQLCore",package:"teaql-swift")],path:"generated/Sources/GeneratedTeaQL"),.executableTarget(name:"ExpressionProfiles",dependencies:["GeneratedTeaQL",.product(name:"TeaQLCore",package:"teaql-swift"),.product(name:"TeaQLSQLite",package:"teaql-swift")],path:"Sources/ExpressionProfiles")],swiftLanguageModes:[.v6])\n';
   fs.writeFileSync(path.join(work,'Package.swift'),manifest);fs.writeFileSync(path.join(output,profile,'consumer-Package.swift'),manifest);
   const build=path.join(scratch,'build'),flags=['--package-path',work,'--scratch-path',build,'--jobs','2'];
   await run(profile,'build',['swift','build',...flags,'--product','ExpressionProfiles','--skip-update'],work,540000);
   const description=JSON.parse(await run(profile,'runtime-origin',['swift','package',...flags,'describe','--type','json'],work));
   assert(description.dependencies.some(d=>d.path===REPO));state.runtimeOrigin=description.dependencies;
   const bin=(await run(profile,'bin-path',['swift','build',...flags,'--show-bin-path'],work)).trim();assert(bin.startsWith(build+path.sep));const executable=path.join(bin,'ExpressionProfiles');assert(fs.existsSync(executable));
   if(fs.existsSync(path.join(work,'Package.resolved')))fs.copyFileSync(path.join(work,'Package.resolved'),path.join(output,profile,'Package.resolved'));
   for(const round of[1,2]){env.TEAQL_EXPRESSION_ROUND=String(round);const log=await run(profile,'round-'+round,[executable],work,90000);
    const rows=[...log.matchAll(/^GENERATED_E_MODEL_PROFILE=(.+)$/gm)].map(m=>JSON.parse(m[1]));assert.equal(rows.length,1);const v=rows[0];
    assert.equal(v.passed,true);assert.equal(v.profile,profile);assert.equal(v.round,round);assert.equal(v.providerEntries,0);assert(v.queryCalibration>0);state.rounds.push(v);
   }

   state.databaseSha256=digest(env.TEAQL_EXPRESSION_DB);assert.deepEqual(fixture(),report.fixture);assert.equal(sourceHash(),report.sourceBefore.sourceContentsSha256);
  }
  assert.deepEqual(sourceIdentity(),report.sourceBefore);report.passed=true;
 }catch(error){report.error=error.stack;console.error(error.stack);process.exitCode=1;}
 finally{
  const safe=!runner||runner.safeToClean;report.cleanup={scratchRemoved:false,disposedOwnedBytes:safe&&scratch?ownedBytes(scratch):0,sharedCachesDeleted:false,databasesDeleted:false};
  if(safe&&scratch){fs.rmSync(scratch,{recursive:true});report.cleanup.scratchRemoved=true;}else if(scratch)report.unsafeRetention=scratch;
  runner?.dispose();report.sourceAfter=sourceHash();fs.writeFileSync(path.join(output,'report.json'),JSON.stringify(report,null,2)+'\n',{flag:'wx'});console.log(JSON.stringify({output,passed:report.passed,cleanup:report.cleanup}));
 }
}
module.exports={sourceHash,sourceIdentity};
if(require.main===module)main().catch(e=>{console.error(e.stack);process.exitCode=1;});
