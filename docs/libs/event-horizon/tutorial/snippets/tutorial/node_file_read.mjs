#!/usr/bin/env node
import { mkdtemp, writeFile, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

const directory = await mkdtemp(join(tmpdir(), 'node-file-'));
try {
  const path = join(directory, 'input');
  await writeFile(path, 'hello from a file\n');
  const data = await readFile(path);
  console.log(`read ${data.length} bytes: ${data}`);
} finally {
  await rm(directory, { recursive: true });
}
