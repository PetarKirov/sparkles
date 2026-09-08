#!/usr/bin/env node
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';

const result = await new Promise(resolve => {
  execFile(
    'sh',
    ['-c', 'echo out; echo err >&2; exit 3'],
    { timeout: 5000 },
    (error, stdout, stderr) => resolve({ error, stdout, stderr }),
  );
});
assert.equal(result.error?.code, 3);
assert.equal(result.stdout, 'out\n');
assert.equal(result.stderr, 'err\n');
console.log('stdout:', result.stdout);
console.log('stderr:', result.stderr);
console.log('exit code:', result.error.code);
