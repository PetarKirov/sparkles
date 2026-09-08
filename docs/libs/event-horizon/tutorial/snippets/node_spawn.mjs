#!/usr/bin/env node
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';

// No descendants: readiness precedes TERM, and close waits for pipe EOF.
const child = spawn(
  process.execPath,
  ['-e', "console.log('one'); console.log('two'); setInterval(() => {}, 1000)"],
  { stdio: ['ignore', 'pipe', 'pipe'] },
);
const closed = new Promise((resolve, reject) => {
  child.once('error', reject);
  child.once('close', (code, signal) => resolve({ code, signal }));
});
const watchdog = setTimeout(() => child.kill('SIGKILL'), 5000);
const lines = [];
const reader = createInterface({ input: child.stdout });
let timeout;
try {
  for await (const line of reader) {
    lines.push(line);
    console.log('line:', line);
    if (lines.length === 2)
      timeout = setTimeout(() => child.kill('SIGTERM'), 50);
  }
  const status = await closed;
  assert.deepEqual(lines, ['one', 'two']);
  assert.equal(status.code, null);
  assert.equal(status.signal, 'SIGTERM');
  console.log('exited: SIGTERM');
  console.log('end: closed');
} finally {
  clearTimeout(timeout);
  clearTimeout(watchdog);
  reader.close();
  child.kill('SIGKILL');
  await closed;
}
