#!/usr/bin/env node
// Imports the sibling workspace `@acme/greeter`, resolved locally through
// the `workspace:^` protocol (PnP links it to ../greeter, never the registry).
import { greet } from '@acme/greeter';

const name = process.argv[2] ?? 'world';
console.log(greet(name));
