'use strict';
const fs=require('node:fs'),assert=require('node:assert/strict');
function validate(rows){
 assert.equal(rows.length,4);const seen=new Set();
 for(const r of rows){assert.equal(r.formatVersion,2);assert.equal(typeof r.logging,'boolean');assert.equal(typeof r.rejectedFirst,'boolean');
  const key=r.logging+'/'+r.rejectedFirst;assert(!seen.has(key));seen.add(key);
  assert.equal(r.rejectedBeforeAnyBegin,r.rejectedFirst);assert.equal(r.publicOverlap,r.rejectedFirst?1:2);
  assert.equal(r.serializedTransactions,1);assert.equal(r.begins,1);assert.equal(r.commits,1);assert.equal(r.rollbacks,0);
  assert(r.violations.some(v=>v.rule.toLowerCase()==='required'&&v.path==='orderItemList[1].name'));
  assert.equal(r.commands.length,2);assert.deepEqual(r.commands.map(c=>c.entity).sort(),['CustomerOrder','OrderItem']);
  for(const c of r.commands){assert.equal(c.comment,'accept checked graph');assert(Number.isSafeInteger(c.id)&&c.id>0);assert.equal(c.version,1);}
  assert.equal(r.rawSQL.length,4);assert.equal(r.safeSQL.length,4);assert.equal(r.audit.length,2);
  for(const event of r.audit)assert.equal(event.reason,'accept checked graph');
 }
 for(const logging of [false,true])for(const first of [false,true])assert(seen.has(logging+'/'+first));
 return {cases:4,forcedOverlaps:2,earlyRejectionsBeforeBegin:2,rejectedTransactions:0};
}
if(require.main===module){const log=fs.readFileSync(process.argv[2],'utf8');const rows=log.split(/\r?\n/).filter(l=>l.startsWith('CHECKER_OVERLAP_OBSERVED ')).map(l=>JSON.parse(l.slice(25)));console.log('PASS Checker isolation v2 oracle '+JSON.stringify(validate(rows)));}
module.exports={validate};
