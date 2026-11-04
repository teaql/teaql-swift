#!/usr/bin/env node
'use strict';
const fs = require('node:fs'), path = require('node:path'), assert = require('node:assert/strict');

function expectedCases() {
  return [
    {id: 'boolean-and-sum', value: [{bucket: false, hits: 1, total: 1}, {bucket: true, hits: 3, total: 9}]},
    {id: 'aliases-shadow-model-fields', value: [{required_long: false, active: 1}, {required_long: true, active: 3}]},
    {id: 'timestamp-decoding', value: [{occurred: '2026-08-29T09:30:00Z', hits: 4}]},
    {id: 'exact-decimal', value: [{amount: '12345678901234567890.123456789', hits: 4}]},
    {id: 'exact-long', value: [{key: '9007199254740993', hits: 4}]},
    {id: 'groups-without-aggregate', value: [{bucket: false}, {bucket: true}]},
    {id: 'nullable-fk-group', value: [{owner: null, hits: 1}, {owner: 1, hits: 2}, {owner: 2, hits: 1}]},
    {id: 'multiple-group-aliases', value: [{owner: null, bucket: true, hits: 1}, {owner: 1, bucket: false, hits: 1}, {owner: 1, bucket: true, hits: 1}, {owner: 2, bucket: true, hits: 1}]},
    {id: 'duplicate-alias-rejected', value: true},
    {id: 'entity-E-and-version', value: 4},
  ];
}
function validate(rounds) {
  assert.equal(rounds.length, 2);
  for (const [i, r] of rounds.entries()) {
    assert.equal(r.profile, 'nonhuman'); assert.equal(r.round, i + 1);
    assert.equal(r.seeded, i === 0 ? 6 : 0);
    assert.deepEqual(r.parentIds, [1, 2]); assert.deepEqual(r.recordIds, [1, 2, 3, 4]);
    assert.deepEqual(r.cases, expectedCases());
  }
  return {passed: true, rounds: 2, casesPerRound: 10, generatedMutations: 6, reseededInSecondRound: 0};
}
function read(directory) {
  return validate([1, 2].map(round => {
    const log = fs.readFileSync(path.join(directory, `round-${round}.log`), 'utf8');
    const frames = [...log.matchAll(/^SWIFT_GROUP_ALIAS_GENERATED=(.+)$/gm)];
    assert.equal(frames.length, 1, 'exactly one actual execution frame per round');
    return JSON.parse(frames[0][1]);
  }));
}
module.exports = {expectedCases, validate, read};
if (require.main === module) console.log(JSON.stringify(read(process.argv[2])));
