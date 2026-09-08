#!/usr/bin/env node
import { setTimeout as sleep } from 'node:timers/promises';

async function work(value, delay) {
  await sleep(delay);
  return value;
}
const [a, b] = await Promise.all([work(1, 20), work(2, 5)]);
console.log('joined:', a * 10 + b);
