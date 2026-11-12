#!/usr/bin/env node
'use strict';
const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),cp=require('node:child_process'),crypto=require('node:crypto'),assert=require('node:assert/strict');
const {createOwnedRunner,ownedBytes}=require('../Examples/FixEAlignment/owned-command.cjs');
const repo=path.resolve(__dirname,'..'),sha=bytes=>crypto.createHash('sha256').update(bytes).digest('hex');
function sourceFiles(){
  const names=cp.execFileSync('git',['ls-files','-z','--cached','--others','--exclude-standard'],{cwd:repo,encoding:'utf8'}).split('\0').filter(Boolean);
  const result={};for(const name of [...new Set(names)].sort()){
    assert(!path.isAbsolute(name)&&!name.split('/').includes('..'));const file=path.join(repo,name);
    assert(fs.lstatSync(file).isFile()&&!fs.lstatSync(file).isSymbolicLink(),name);result[name]=sha(fs.readFileSync(file));
  }return result;
}
function automaticFixture(root){
  const names=[];function visit(dir,prefix=''){for(const entry of fs.readdirSync(dir,{withFileTypes:true})){
    assert(!entry.isSymbolicLink());const name=path.join(prefix,entry.name);assert(!['.build','bin','obj'].includes(entry.name));
    if(entry.isDirectory())visit(path.join(dir,entry.name),name);else{assert(entry.isFile());names.push(name);}}}visit(root);
  const json=name=>JSON.parse(fs.readFileSync(path.join(root,name)));
  const files=json('generated-files.json'),assists=json('assist-files.json'),origin=json('generation.json');
  assert.equal(Object.keys(files).length,14);assert.equal(Object.keys(assists).length,7);
  assert.deepEqual(names.sort(),[...Object.keys(files),...Object.keys(assists),'generated-files.json','assist-files.json','model.xml','evaluation.json','generation.json'].sort());
  for(const[name,hash]of Object.entries({...files,...assists})){
    assert(!path.isAbsolute(name)&&!name.split('/').includes('..'));assert.equal(sha(fs.readFileSync(path.join(root,name))),hash,name);
  }
  assert.equal(json('evaluation.json').errors.length,0);assert.equal(origin.modelSha256,sha(fs.readFileSync(path.join(root,'model.xml'))));
  assert(!origin.implementationHandEdited&&!origin.publicPublication);
  const app=fs.readFileSync(path.join(repo,'Examples/NaturalMessages/AutomaticNaturalMessages.swift'),'utf8');
  for(const forbidden of ['CheckerPresentationModel(', 'installCheckerPresentation(', 'struct AppChecker', 'AppChecker(', 'checkers:', 'RuntimeModule(name:'])
    assert(!app.includes(forbidden),'automatic composition replaced: '+forbidden);
  return {files,assists,origin,inputHashes:Object.fromEntries(names.map(name=>[name,sha(fs.readFileSync(path.join(root,name)))]))};
}
async function main(){
  const args=process.argv.slice(2);let focused=false,example=false,exampleOnly=false,output;
  for(let i=0;i<args.length;i++)if(args[i]==='--focused')focused=true;else if(args[i]==='--example')example=true;else if(args[i]==='--example-only'){example=true;exampleOnly=true;}
  else if(args[i]==='--output'&&args[i+1])output=args[++i];else throw new Error('Usage: node scripts/verify-natural-messages.cjs [--focused | --example-only | --example] [--output /new/evidence]');
  assert(!(focused&&example),'focused native and generated consumer are separate gates');
  if(output){assert(path.isAbsolute(output)&&!fs.existsSync(output));fs.mkdirSync(output,{recursive:true});}else output=fs.mkdtempSync(path.join(os.tmpdir(),'teaql-swift-natural-evidence-'));
  const scratch=fs.mkdtempSync(path.join(os.tmpdir(),'teaql-swift-natural-build-')),runner=createOwnedRunner();
  const receipt={schema:'teaql.swift-natural-tests/v1',passed:false,focused,completeRuntimeTests:!focused&&!exampleOnly,scratch,commands:[],rounds:[],publicPublication:false};
  try{
    assert(fs.statfsSync(scratch).bavail*fs.statfsSync(scratch).bsize>8*1024**3);
    receipt.sourceCommit=cp.execFileSync('git',['rev-parse','HEAD'],{cwd:repo,encoding:'utf8'}).trim();receipt.sourceHashes=sourceFiles();
    const work=path.join(scratch,'source');fs.mkdirSync(work);
    for(const name of Object.keys(receipt.sourceHashes)){const target=path.join(work,name);fs.mkdirSync(path.dirname(target),{recursive:true});fs.copyFileSync(path.join(repo,name),target);}
    if(focused){
      // Explicit lightweight gate, never reported as the complete package suite.
      // The production sources/resources are byte-exact; the build manifest only
      // selects Core and the natural-message/legacy-i18n tests without SDK fetches.
      const manifest='// swift-tools-version: 6.0\nimport PackageDescription\nlet package=Package(name:"NaturalMessageFocused",targets:[.target(name:"TeaQLCore",resources:[.process("Resources")]),.testTarget(name:"TeaQLCoreTests",dependencies:["TeaQLCore"],exclude:[],sources:["CheckerNaturalMessagesTests.swift","I18nTests.swift"],resources:[.process("fixtures")])],swiftLanguageModes:[.v6])\n';
      fs.writeFileSync(path.join(work,'Package.swift'),manifest);fs.writeFileSync(path.join(output,'focused-Package.swift'),manifest);
    }
    const swift=process.env.SWIFT_EXE||'swift',env={...process.env,TEAQL_NATURAL_MESSAGES_DB:path.join(output,'fixture.sqlite'),TEAQL_TELEMETRY_ENABLED:'false'};
    async function run(command,log,timeout=300000,cwd=work){
      const file=path.join(output,log),fd=fs.openSync(file,'wx');let result;
      try{result=await runner.run(command,{cwd,env,timeout,stdio:['ignore',fd,fd]});}finally{fs.closeSync(fd);}
      const bytes=fs.readFileSync(file);receipt.commands.push({command,log,exitCode:result.status,signal:result.signal,logSha256:sha(bytes)});
      assert.equal(result.status,0,bytes.toString().slice(-14000));return bytes.toString();
    }
    if(!exampleOnly)await run([swift,'test','--package-path',work,'--scratch-path',path.join(scratch,'build'),'--jobs','2',...(focused?[]:['--skip-update','--force-resolved-versions'])], 'native-tests.log',focused?240000:900000);
    if(example){
      const fixture=path.join(work,'Examples/NaturalMessages/automatic-fixture');
      const automatic=automaticFixture(fixture),generated=automatic.files;
      for(const[name,hash]of Object.entries(generated)){
        assert(!path.isAbsolute(name)&&!name.split('/').includes('..'));assert.equal(sha(fs.readFileSync(path.join(fixture,name))),hash,name);
      }
      receipt.fixtureFiles=generated;receipt.fixtureSha256=sha(fs.readFileSync(path.join(fixture,'generated-files.json')));
      receipt.fixtureInputHashes=automatic.inputHashes;receipt.generation=automatic.origin;receipt.automaticComposition=true;
      const consumer=path.join(scratch,'consumer'),build=path.join(scratch,'consumer-build');fs.mkdirSync(path.join(consumer,'Sources/NaturalMessagesExample'),{recursive:true});
      fs.cpSync(fixture,path.join(consumer,'generated'),{recursive:true});fs.copyFileSync(path.join(work,'Examples/NaturalMessages/AutomaticNaturalMessages.swift'),path.join(consumer,'Sources/NaturalMessagesExample/NaturalMessages.swift'));
      const manifest='// swift-tools-version: 6.0\nimport PackageDescription\nlet package=Package(name:"NaturalMessagesExample",dependencies:[.package(name:"teaql-swift",path:'+JSON.stringify(work)+')],targets:[.target(name:"GeneratedTeaQL",dependencies:[.product(name:"TeaQLCore",package:"teaql-swift")],path:"generated/Sources/GeneratedTeaQL"),.executableTarget(name:"NaturalMessagesExample",dependencies:["GeneratedTeaQL",.product(name:"TeaQLCore",package:"teaql-swift"),.product(name:"TeaQLSQLite",package:"teaql-swift")],path:"Sources/NaturalMessagesExample")],swiftLanguageModes:[.v6])\n';
      fs.writeFileSync(path.join(consumer,'Package.swift'),manifest);fs.writeFileSync(path.join(output,'consumer-Package.swift'),manifest);fs.copyFileSync(path.join(work,'Package.resolved'),path.join(consumer,'Package.resolved'));
      const flags=['--package-path',consumer,'--scratch-path',build,'--jobs','2'];
      await run([swift,'build',...flags,'--product','NaturalMessagesExample','--skip-update','--force-resolved-versions'],'example-build.log',600000,consumer);
      const pins=JSON.parse(fs.readFileSync(path.join(consumer,'Package.resolved'))),original=JSON.parse(fs.readFileSync(path.join(work,'Package.resolved')));
      for(const pin of pins.pins){const source=original.pins.find(p=>p.identity===pin.identity);assert(source,pin.identity);assert.deepEqual(pin.state,source.state);}
      receipt.dependenciesMatchRuntimePins=true;
      const description=JSON.parse(await run([swift,'package',...flags,'describe','--type','json'],'runtime-origin.log',120000,consumer));
      assert(description.dependencies.some(d=>d.path===work));receipt.localSourceDependency=true;
      const bin=(await run([swift,'build',...flags,'--show-bin-path'],'binary-path.log',120000,consumer)).trim();assert(bin.startsWith(build+path.sep));
      const binary=path.join(bin,'NaturalMessagesExample');receipt.binarySha256=sha(fs.readFileSync(binary));
      for(const round of[1,2]){
        const log=await run([binary],`round-${round}.log`,120000,consumer),marker='SWIFT_NATURAL_SQLITE=';
        const rows=log.split(/\r?\n/).filter(line=>line.startsWith(marker)).map(line=>JSON.parse(line.slice(marker.length)));assert.equal(rows.length,1);const row=rows[0];
        for(const field of['passed','typedQ','typedE','unchangedParent','automaticMetadata','originalGeneratedChecker','missingAuditRejected'])assert.equal(row[field],true,field);
        assert.equal(row.failedCheckProviderCalls,0);assert.equal(row.correctedWrites,1);assert.equal(row.correctedAudits,1);assert.equal(row.originalLength,101);assert.equal(row.unicodeScalars,202);
        assert.equal(row.responses,4);assert.equal(row.customerRendererCalls,1);
        const responses=log.split(/\r?\n/).filter(line=>line.startsWith('SWIFT_NATURAL_CHECKER_RESPONSE='))
          .map(line=>JSON.parse(line.slice('SWIFT_NATURAL_CHECKER_RESPONSE='.length)));
        assert.equal(responses.length,4);
        assert.deepEqual(responses.map(v=>v.message),['The name of the 2nd entry is required.','请填写第2项明细的名称。',
          'The name of the 2nd entry must not exceed 100 grapheme clusters; its current length is 101.','Private [REDACTED]']);
        assert(responses.every(v=>v.entityType==='Entry'&&v.instancePath==='/entryList/1/name'));
        assert(!JSON.stringify(responses).includes('e\u0301'.repeat(101)));
        const oracle='import sqlite3,json,sys,pathlib\nc=sqlite3.connect(pathlib.Path(sys.argv[1]).resolve().as_uri()+"?mode=ro&immutable=1",uri=True)\nr=json.loads(sys.argv[2])\nassert c.execute("SELECT name,version FROM entry_data WHERE id=?",(r["secondId"],)).fetchone()==("accepted",r["secondVersion"])\nassert c.execute("SELECT name,version FROM entry_data WHERE id=?",(r["firstId"],)).fetchone()==("second",r["firstVersion"])\nassert c.execute("SELECT version FROM catalog_data WHERE id=?",(r["parentId"],)).fetchone()==(r["parentVersion"],)\nassert c.execute("pragma quick_check").fetchone()==("ok",)\nc.close()\nprint("SQLITE_ORACLE=passed")\n';
        await run(['python3','-B','-c',oracle,env.TEAQL_NATURAL_MESSAGES_DB,JSON.stringify(row)],`oracle-${round}.log`,120000,consumer);
        receipt.rounds.push({round,observations:row,responses,physicalOracle:true});
      }
      receipt.sameDatabase=true;receipt.databaseSha256=sha(fs.readFileSync(env.TEAQL_NATURAL_MESSAGES_DB));
    }
    assert.deepEqual(sourceFiles(),receipt.sourceHashes);
    if(!focused)assert.equal(sha(fs.readFileSync(path.join(work,'Package.resolved'))),receipt.sourceHashes['Package.resolved']);
    receipt.sourceUnchanged=true;receipt.passed=true;
  }catch(error){receipt.error=String(error);process.exitCode=1;console.error(error);}
  finally{
    receipt.disposableBytesRemoved=runner.safeToClean?ownedBytes(scratch):0;
    if(runner.safeToClean)fs.rmSync(scratch,{recursive:true});else receipt.unsafeBuildRetention={path:scratch,processGroup:runner.unsafeGroup};
    receipt.scratchRemoved=!fs.existsSync(scratch);runner.dispose();fs.writeFileSync(path.join(output,'receipt.json'),JSON.stringify(receipt,null,2)+'\n');console.log(JSON.stringify({passed:receipt.passed,evidence:output,focused}));
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
