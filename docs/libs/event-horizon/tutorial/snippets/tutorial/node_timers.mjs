#!/usr/bin/env node
import { setTimeout as sleep } from 'node:timers/promises';

for (let tick = 1; tick <= 3; ++tick) {
  await sleep(10);
  console.log('tick', tick);
}
