#!/usr/bin/env node
'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),cp=require('node:child_process'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {createOwnedRunner,ownedBytes}=require('../FixEAlignment/owned-command.cjs');
const example=__dirname,repo=path.resolve(example,'../..'),fixture=path.join(example,'fixture');
const sha=b=>crypto.createHash('sha256').update(b).digest('hex');
function files(root){const out=[];function visit(dir){for(const e of fs.readdirSync(dir,{withFileTypes:true})){
 assert(!e.isSymbolicLink(),'symlink is forbidden');const f=path.join(dir,e.name);
 if(e.isDirectory())visit(f);else{assert(e.isFile());out.push(path.relative(root,f));}
}}visit(root);return out.sort();}
function fingerprint(){const m=JSON.parse(fs.readFileSync(path.join(fixture,'generated-files.json')));
 assert.deepEqual(files(fixture),[...Object.keys(m),'generated-files.json','model.xml'].sort());
 for(const[n,h]of Object.entries(m)){assert(!path.isAbsolute(n)&&!n.split('/').includes('..'));assert.equal(sha(fs.readFileSync(path.join(fixture,n))),h,n);}
 return{manifestSha256:sha(fs.readFileSync(path.join(fixture,'generated-files.json'))),modelSha256:sha(fs.readFileSync(path.join(fixture,'model.xml')))};}
function sourceHash(){const h=crypto.createHash('sha256');for(const n of files(path.join(repo,'Sources'))){h.update(n+'\0');h.update(fs.readFileSync(path.join(repo,'Sources',n)));}
 for(const n of ['Package.swift','Package.resolved'])if(fs.existsSync(path.join(repo,n))){h.update(n+'\0');h.update(fs.readFileSync(path.join(repo,n)));}return h.digest('hex');}
const requested=process.env.TEAQL_CONTEXT_FIX_EVIDENCE_DIR;
const evidence=requested?path.resolve(requested):fs.mkdtempSync(path.join(os.tmpdir(),'teaql-swift-context-evidence-'));
if(requested){assert(path.isAbsolute(requested)&&!fs.existsSync(evidence));fs.mkdirSync(evidence,{recursive:true});}
const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'teaql-swift-context-build-')),runner=createOwnedRunner();
const report={schema:'teaql.swift-context-derived-mutation/v1',passed:false,commands:[],rounds:[],publicPublication:false,databaseRetained:true};
async function main(){try{
 const disk=fs.statfsSync(scratch);assert(disk.bavail*disk.bsize>8*1024**3);
 report.fixture=fingerprint();report.sourceSha256=sourceHash();report.sourceCommit=cp.execFileSync('git',['-C',repo,'rev-parse','HEAD'],{encoding:'utf8'}).trim();
 report.applicationSha256=sha(fs.readFileSync(path.join(example,'ContextDerived.swift')));
 const work=path.join(scratch,'consumer'),build=path.join(scratch,'build');fs.mkdirSync(work);
 fs.cpSync(fixture,path.join(work,'generated'),{recursive:true});fs.mkdirSync(path.join(work,'Sources/ContextDerivedExample'),{recursive:true});
 fs.copyFileSync(path.join(example,'ContextDerived.swift'),path.join(work,'Sources/ContextDerivedExample/ContextDerived.swift'));
 const manifest='// swift-tools-version: 6.0\nimport PackageDescription\nlet package=Package(name:"ContextDerivedExample",dependencies:[.package(name:"teaql-swift",path:'+JSON.stringify(repo)+')],targets:[.target(name:"GeneratedTeaQL",dependencies:[.product(name:"TeaQLCore",package:"teaql-swift")],path:"generated/Sources/GeneratedTeaQL"),.executableTarget(name:"ContextDerivedExample",dependencies:["GeneratedTeaQL",.product(name:"TeaQLCore",package:"teaql-swift"),.product(name:"TeaQLSQLite",package:"teaql-swift")],path:"Sources/ContextDerivedExample")],swiftLanguageModes:[.v6])\n';
 fs.writeFileSync(path.join(work,'Package.swift'),manifest);fs.writeFileSync(path.join(evidence,'consumer-Package.swift'),manifest);
 const lockfile=path.join(repo,'Package.resolved');assert(fs.existsSync(lockfile),'runtime resolution must be pinned');
 fs.copyFileSync(lockfile,path.join(work,'Package.resolved'));report.runtimeResolutionSha256=sha(fs.readFileSync(lockfile));
 const flags=['--package-path',work,'--scratch-path',build,'--jobs','2'];
 const env={...process.env,TEAQL_CONTEXT_FIX_DB:path.join(evidence,'fixture.sqlite')};
 async function run(command,log,timeout=120000){const f=path.join(evidence,log),fd=fs.openSync(f,'wx');let result;
  try{result=await runner.run(command,{cwd:work,env,timeout,stdio:['ignore',fd,fd]});}finally{fs.closeSync(fd);}
  const bytes=fs.readFileSync(f);report.commands.push({command,exitCode:result.status,signal:result.signal,logSha256:sha(bytes)});
  assert.equal(result.status,0,bytes.toString().slice(-9000));return bytes.toString();}
 if(process.env.TEAQL_CONTEXT_FIX_UNIT_TESTS==='1'){
  await run(['swift','test','--package-path',repo,'--scratch-path',path.join(scratch,'unit-build'),'--jobs','2','--skip-update'], 'unit-tests.log',600000);
  report.completeRuntimeTests=true;
 }
 await run(['swift','build',...flags,'--product','ContextDerivedExample','--skip-update'],'build.log',540000);
 const resolved=JSON.parse(fs.readFileSync(path.join(work,'Package.resolved'))),originalPins=JSON.parse(fs.readFileSync(lockfile));
 for(const pin of resolved.pins){const expected=originalPins.pins.find(p=>p.identity===pin.identity);assert(expected,'unexpected dependency '+pin.identity);assert.deepEqual(pin.state,expected.state,pin.identity);}
 fs.copyFileSync(path.join(work,'Package.resolved'),path.join(evidence,'Package.resolved'));report.dependenciesMatchRuntimePins=true;
 const description=JSON.parse(await run(['swift','package',...flags,'describe','--type','json'],'runtime-origin.log'));
 assert(description.dependencies.some(d=>d.path===repo));report.localSourceDependency=true;
 const bin=(await run(['swift','build',...flags,'--show-bin-path'],'binary-path.log')).trim();assert(bin.startsWith(build+path.sep));
 const binary=path.join(bin,'ContextDerivedExample');assert(fs.existsSync(binary));report.binarySha256=sha(fs.readFileSync(binary));
 for(const round of [1,2]){
  const log=await run([binary],`round-${round}.log`),rows=log.split(/\r?\n/).filter(s=>s.startsWith('SWIFT_CONTEXT_FIX_SQLITE=')).map(s=>JSON.parse(s.slice('SWIFT_CONTEXT_FIX_SQLITE='.length)));
  assert.equal(rows.length,1);const row=rows[0];for(const n of ['passed','typedQ','typedE','objectLocation','graphRollback','fixOnce'])assert.equal(row[n],true,n);
  assert.equal(row.noOpProviderCalls,0);assert.equal(row.failedCheckProviderCalls,0);assert.equal(row.updateAudits,1);
  // Read-only independent oracle; no hand-written mutation alternative.
  const oracle='import sqlite3,json,sys\nc=sqlite3.connect("file:"+sys.argv[1]+"?mode=ro",uri=True)\nr=json.loads(sys.argv[2])\nv=c.execute("SELECT name,last_ip,version FROM entry_data WHERE id=?",(r["physicalId"],)).fetchone()\nassert v==(r["physicalName"],"ip-D",r["physicalVersion"]),v\nc.close()\nprint("SQLITE_ORACLE=passed")\n';
  const observed=await run(['python3','-c',oracle,env.TEAQL_CONTEXT_FIX_DB,JSON.stringify(row)],`oracle-${round}.log`);assert(observed.includes('SQLITE_ORACLE=passed'));
  report.rounds.push({round,observations:row,physicalOracle:true});assert.deepEqual(fingerprint(),report.fixture);assert.equal(sourceHash(),report.sourceSha256);
 }
 report.passed=true;report.sameDatabase=true;report.databaseSha256=sha(fs.readFileSync(env.TEAQL_CONTEXT_FIX_DB));
}catch(error){report.error=String(error);process.exitCode=1;console.error(error);}
finally{report.disposableBytesRemoved=runner.safeToClean?ownedBytes(scratch):0;if(runner.safeToClean)fs.rmSync(scratch,{recursive:true});else report.unsafeBuildRetention={path:scratch,processGroup:runner.unsafeGroup};
 runner.dispose();fs.writeFileSync(path.join(evidence,'receipt.json'),JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify({passed:report.passed,evidence,rounds:report.rounds.length}));}}
main().catch(error=>{console.error(error);process.exitCode=1;});
