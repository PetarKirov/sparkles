#!/usr/bin/env node
import { once } from 'node:events';

const received = once(process, 'SIGUSR1'); // Install before sending.
const watchdog = setTimeout(() => {
  throw new Error('SIGUSR1 was not delivered');
}, 5000);
try {
  process.kill(process.pid, 'SIGUSR1');
  await received;
  console.log('got signal SIGUSR1');
} finally {
  clearTimeout(watchdog);
}
