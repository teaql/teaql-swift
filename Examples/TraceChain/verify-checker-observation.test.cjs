'use strict';
const test=require('node:test'),assert=require('node:assert/strict');const {validate}=require('./verify-checker-observation.cjs');
function rows(){return [false,true].flatMap(logging=>[false,true].map(rejectedFirst=>({formatVersion:2,logging,rejectedFirst,rejectedBeforeAnyBegin:rejectedFirst,publicOverlap:rejectedFirst?1:2,
 serializedTransactions:1,begins:1,commits:1,rollbacks:0,violations:[{rule:'required',path:'orderItemList[1].name'}],commands:[{entity:'CustomerOrder',id:1,version:1,comment:'accept checked graph'},{entity:'OrderItem',id:2,version:1,comment:'accept checked graph'}],rawSQL:Array(4).fill({}),safeSQL:Array(4).fill({}),audit:Array(2).fill({reason:'accept checked graph'})})));}
test('both real overlap and zero-I/O early rejection have explicit different expectations',()=>{assert.equal(validate(rows()).cases,4);});
for(const [name,change]of Object.entries({
 rejectedBEGIN:r=>r[1].begins=2,
 rejectedRollback:r=>r[1].rollbacks=1,
 fakeOverlap:r=>r[1].publicOverlap=2,
 missingOverlap:r=>r[0].publicOverlap=1,
 rejectedCommand:r=>r[0].commands[0].comment='reject incomplete graph',
 missingRequiredViolation:r=>r[0].violations=[],
}))test('reject '+name,()=>{const r=rows();change(r);assert.throws(()=>validate(r));});
