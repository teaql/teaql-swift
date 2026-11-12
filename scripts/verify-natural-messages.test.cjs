'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),path=require('node:path'),os=require('node:os'),cp=require('node:child_process');
const script=path.join(__dirname,'verify-natural-messages.cjs');
for(const mode of['failure','missing-executable'])test('Swift owned gate cleans after '+mode,()=>{
  const owned=fs.mkdtempSync(path.join(os.tmpdir(),'teaql-swift-natural-runner-test-'));
  try{
    const evidence=path.join(owned,'evidence');
    const result=cp.spawnSync(process.execPath,[script,'--focused','--output',evidence],{encoding:'utf8',timeout:20000,
      env:{...process.env,SWIFT_EXE:mode==='failure'?'/usr/bin/false':path.join(owned,'absent-swift')}});
    assert.equal(result.status,1,result.stderr);
    const receipt=JSON.parse(fs.readFileSync(path.join(evidence,'receipt.json')));
    assert.equal(receipt.passed,false);assert.equal(receipt.rounds.length,0);assert.equal(receipt.completeRuntimeTests,false);
    assert.equal(receipt.unsafeBuildRetention,undefined);assert(receipt.disposableBytesRemoved>0);
    assert(receipt.scratch.startsWith(os.tmpdir()+path.sep+'teaql-swift-natural-build-'));assert.equal(fs.existsSync(receipt.scratch),false);
    assert.equal(receipt.commands.length,1);assert.notEqual(receipt.commands[0].exitCode,0);
  }finally{fs.rmSync(owned,{recursive:true});}
});
test('Swift evidence cannot be overwritten',()=>{
  const owned=fs.mkdtempSync(path.join(os.tmpdir(),'teaql-swift-natural-existing-test-'));
  try{
    fs.writeFileSync(path.join(owned,'keep.txt'),'retained evidence');
    const result=cp.spawnSync(process.execPath,[script,'--focused','--output',owned],{encoding:'utf8',timeout:20000});
    assert.equal(result.status,1);assert.deepEqual(fs.readdirSync(owned),['keep.txt']);assert.equal(fs.readFileSync(path.join(owned,'keep.txt'),'utf8'),'retained evidence');
  }finally{fs.rmSync(owned,{recursive:true});}
});
