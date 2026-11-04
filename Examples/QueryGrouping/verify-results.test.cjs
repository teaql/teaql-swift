'use strict';
const test = require('node:test'), assert = require('node:assert/strict');
const {expectedCases, validate} = require('./verify-results.cjs');
function rounds() {
  return [1, 2].map(round => ({profile: 'nonhuman', round, seeded: round === 1 ? 6 : 0,
    parentIds: [1, 2], recordIds: [1, 2, 3, 4], cases: expectedCases()}));
}
test('accept exact two-round named grouping contract', () => assert.equal(validate(rounds()).passed, true));
for (const [name, change] of [
  ['missing case', q => q[0].cases.pop()],
  ['second-round reseeding', q => q[1].seeded = 6],
  ['Boolean domain replaced by integer', q => q[0].cases[0].value[0].bucket = 0],
  ['Decimal precision lost', q => q[1].cases[3].value[0].amount = '12345678901234567890'],
  ['entity versions not inspected', q => q[1].cases[9].value = 0],
  ['duplicate alias accepted', q => q[0].cases[8].value = false],
]) test('reject ' + name, () => {const q = rounds(); change(q); assert.throws(() => validate(q));});
