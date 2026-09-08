#!/usr/bin/env node
import { setTimeout as sleep } from 'node:timers/promises';

const controller = new AbortController();
const timeout = setTimeout(() => controller.abort(), 50);
let cleaned = false;
try {
  await sleep(10_000, undefined, { signal: controller.signal });
} catch (error) {
  if (error.name !== 'AbortError') throw error;
  console.log('sleep returned:', error.name);
} finally {
  clearTimeout(timeout);
  await sleep(5); // Cleanup deliberately does not receive the aborted signal.
  cleaned = true;
}
console.log('timed out:', controller.signal.aborted);
console.log('cleaned up:', cleaned);
