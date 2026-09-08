#!/usr/bin/env node
import { execFile } from 'node:child_process';

// A nonzero child exit is part of this demonstration, not a launch failure.
const { error, stdout, stderr } = await new Promise(resolve => {
  execFile(
    'sh',
    ['-c', 'echo out; echo err >&2; exit 3'],
    { timeout: 5000 },
    (error, stdout, stderr) => resolve({ error, stdout, stderr }),
  );
});
if (error && (typeof error.code !== 'number' || error.killed)) throw error;
console.log('stdout:', stdout);
console.log('stderr:', stderr);
console.log('exit code:', error?.code ?? 0);
