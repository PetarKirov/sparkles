#!/usr/bin/env node
import { setTimeout as sleep } from 'node:timers/promises';

let attempts = 0;
function request() {
  if (++attempts < 3)
    throw Object.assign(new Error('try again'), { code: 'EAGAIN' });
  return attempts;
}
for (let retry = 0; ; ++retry) {
  try {
    console.log('attempts:', request());
    break;
  } catch (error) {
    if (error.code !== 'EAGAIN' || retry === 4) throw error;
    await sleep(5 * 2 ** retry);
  }
}
