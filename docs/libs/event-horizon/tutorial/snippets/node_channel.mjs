#!/usr/bin/env node
import assert from 'node:assert/strict';
import { Writable } from 'node:stream';

// A Writable's highWaterMark counts buffered objects, including in-flight work.
// The caller must obey write(false); this is not a blocking queue put.
const values = [];
let releaseFirst;
const sink = new Writable({
  objectMode: true,
  highWaterMark: 2,
  write(value, encoding, done) {
    values.push(value);
    if (value === 1) releaseFirst = done;
    else done();
  },
});
let drained = false;
const drain = new Promise(resolve =>
  sink.once('drain', () => {
    drained = true;
    resolve();
  }),
);
assert.equal(sink.write(1), true);
assert.equal(sink.write(2), false);
assert.equal(sink.writableLength, 2);
assert.deepEqual(values, [1]);
assert.equal(drained, false);
releaseFirst();
await drain;
assert.deepEqual(values, [1, 2]);
for (let i = 3; i <= 5; ++i) assert.equal(sink.write(i), true);
const finished = new Promise((resolve, reject) => {
  sink.once('finish', resolve);
  sink.once('error', reject);
});
sink.end();
await finished;
assert.deepEqual(values, [1, 2, 3, 4, 5]);
const sum = values.reduce((a, b) => a + b, 0);
assert.equal(sum, 15);
console.log('consumed:', sum);
