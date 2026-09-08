#!/usr/bin/env node
import assert from 'node:assert/strict';

const received = new Promise(resolve => process.once('SIGUSR1', resolve));
// A watchdog keeps the process alive and makes failure finite.
const watchdog = setTimeout(() => {
  throw new Error('SIGUSR1 was not delivered');
}, 5000);
try {
  assert.equal(process.listenerCount('SIGUSR1'), 1);
  process.kill(process.pid, 'SIGUSR1');
  await received;
  assert.equal(process.listenerCount('SIGUSR1'), 0);
  console.log('got signal SIGUSR1');
} finally {
  clearTimeout(watchdog);
}
