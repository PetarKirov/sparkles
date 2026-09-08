#!/usr/bin/env node
import assert from 'node:assert/strict';

const release = Promise.withResolvers();
let started = 0;
let finished = 0;
async function work(value) {
  ++started;
  await release.promise;
  ++finished;
  return value;
}
const children = [work(1), work(2)];
assert.equal(started, 2);
assert.equal(finished, 0);
release.resolve();
const [a, b] = await Promise.all(children);
assert.equal(finished, 2);
assert.equal(a * 10 + b, 12);
console.log('joined:', a * 10 + b);
