#!/usr/bin/env node
import assert from 'node:assert/strict';
import { setTimeout as sleep } from 'node:timers/promises';

const controller = new AbortController();
let cleaned = false;
let interrupted = false;
// Calling the async function reaches sleep before returning its promise.
const work = (async () => {
  try {
    await sleep(10_000, undefined, { signal: controller.signal });
    assert.fail('the timer should have been interrupted');
  } catch (error) {
    assert.equal(error.name, 'AbortError');
    interrupted = true;
    console.log('sleep returned: AbortError');
  } finally {
    await sleep(5); // deliberately omit the aborted signal for cleanup
    cleaned = true;
  }
})();
const timeout = setTimeout(() => controller.abort(), 50);
try {
  await work;
} finally {
  clearTimeout(timeout);
}
assert(interrupted && cleaned && controller.signal.aborted);
console.log('timed out:', interrupted);
console.log('cleaned up:', cleaned);
