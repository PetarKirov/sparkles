#!/usr/bin/env node
import { Writable } from 'node:stream';
import { once } from 'node:events';
import { finished } from 'node:stream/promises';

let sum = 0;
const sink = new Writable({
  objectMode: true,
  highWaterMark: 2,
  write(value, encoding, done) {
    sum += value;
    setTimeout(done, 2); // A slow consumer.
  },
});
const completion = finished(sink);
try {
  for (let value = 1; value <= 5; ++value) {
    if (!sink.write(value)) await once(sink, 'drain');
  }
  sink.end();
  await completion;
  console.log('consumed:', sum);
} finally {
  sink.destroy();
}
