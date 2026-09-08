#!/usr/bin/env node
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { once } from 'node:events';

const child = spawn(
  process.execPath,
  ['-e', "console.log('one'); console.log('two'); setInterval(() => {}, 1000)"],
  { stdio: ['ignore', 'pipe', 'inherit'] },
);
const reader = createInterface({ input: child.stdout });
const watchdog = setTimeout(() => child.kill('SIGKILL'), 5000);
try {
  const [, [, signal]] = await Promise.all([
    (async () => {
      for await (const line of reader) {
        console.log('line:', line);
        if (line === 'two') child.kill('SIGTERM'); // Readiness, not a guessed delay.
      }
    })(),
    once(child, 'close'), // Includes output drainage as well as root exit.
  ]);
  console.log('exited:', signal);
  console.log('end: closed');
} finally {
  clearTimeout(watchdog);
  reader.close();
  if (child.exitCode === null && child.signalCode === null) {
    const closed = once(child, 'close');
    child.kill('SIGKILL');
    await closed;
  }
}
