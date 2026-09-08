#!/usr/bin/env node
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';

const ticks = [];
for (let i = 1; i <= 3; ++i) {
  await sleep(10); // relative delay, not an absolute-deadline ticker
  ticks.push(i);
  console.log('tick', i);
}
assert.deepEqual(ticks, [1, 2, 3]);
