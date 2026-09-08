#!/usr/bin/env node
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';

let attempts = 0;
let result;
for (let retry = 0; retry <= 4; ++retry) {
  try {
    ++attempts;
    if (attempts < 3)
      throw Object.assign(new Error('try again'), { code: 'EAGAIN' });
    result = attempts;
    break;
  } catch (error) {
    assert.equal(error.code, 'EAGAIN');
    if (retry === 4) throw error;
    await sleep(5 * 2 ** retry);
  }
}
assert.equal(attempts, 3);
assert.equal(result, 3);
console.log('attempts:', result);
