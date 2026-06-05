#!/usr/bin/env node
// @acme/cli — imports the sibling workspace member by its package name.
// npm's Arborist links @acme/greeter into node_modules because the local
// version satisfies the "^1.0.0" range, so this import resolves locally.
import { greet } from '@acme/greeter';

const name = process.argv[2] ?? 'world';
console.log(greet(name));
