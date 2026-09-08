#!/usr/bin/env node
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const directory = await mkdtemp(join(tmpdir(), 'node-file-'));
try {
  const path = join(directory, 'input');
  const expected = 'hello from a file\n';
  await writeFile(path, expected);
  const data = await readFile(path);
  assert.equal(data.toString(), expected);
  assert.equal(data.length, 18);
  await assert.rejects(readFile(join(directory, 'missing')), {
    code: 'ENOENT',
  });
  console.log(`read ${data.length} bytes: ${data}`);
} finally {
  await rm(directory, { recursive: true });
}
