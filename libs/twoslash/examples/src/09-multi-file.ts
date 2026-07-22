// `@filename` splits a snippet into a virtual multi-file project.
// @filename: math.ts
export function sum(a: number, b: number): number {
  return a + b
}

// @filename: index.ts
import { sum } from "./math"
const result = sum(1, 2)
//    ^?
