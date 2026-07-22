// Dev-only fixture generator. Runs the reference TypeScript `twoslash` over every
// source in `src/` and writes the trimmed `{ code, nodes }` slice the renderer
// consumes to `fixtures/<name>.twoslash.json`.
//
// This is the ONE place node is allowed: the sparkles build and `dub test` are
// hermetic and never invoke it. The outputs are committed so consumers
// (`dub test :twoslash`, `hue --twoslash`) need no node dependency. Run it via
// `./regen.sh` (which installs deps first) or `npm run regen`.
//
// The overlay treats `nodes` as opaque input, so any twoslash-compatible source
// (twoslash today, the future sparkles:dmd-lsp backend) produces the same shape.

import { createTwoslasher } from 'twoslash'
import { readdirSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, extname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const srcDir = join(here, 'src')
const outDir = join(here, 'fixtures')
mkdirSync(outDir, { recursive: true })

// Match the upstream fixture harness: one shared twoslasher, language from the
// file extension, and `annotate` registered as a custom tag.
const twoslasher = createTwoslasher()
const customTags = ['annotate', 'log', 'warn', 'error']

const sources = readdirSync(srcDir)
  .filter(f => /\.(ts|tsx|mts|cts)$/.test(f))
  .sort()

let ok = 0
const failures = []

for (const file of sources) {
  const name = file.replace(/\.[^.]+$/, '')
  const lang = extname(file).slice(1)
  const code = readFileSync(join(srcDir, file), 'utf8')
  try {
    const result = twoslasher(code, lang, { customTags })
    // Keep only the slice the D renderer reads; drop the heavy TS metadata.
    const slim = { code: result.code, nodes: result.nodes }
    const json = JSON.stringify(slim, null, 1) + '\n'
    writeFileSync(join(outDir, `${name}.twoslash.json`), json)
    const kinds = tally(result.nodes.map(n => n.type))
    console.log(`  ✓ ${file.padEnd(20)} → ${name}.twoslash.json  [${kinds}]`)
    ok++
  }
  catch (err) {
    failures.push({ file, message: err?.message ?? String(err) })
    console.error(`  ✗ ${file.padEnd(20)} ${firstLine(err?.message ?? String(err))}`)
  }
}

console.log(`\n${ok}/${sources.length} fixtures regenerated into fixtures/`)
if (failures.length) {
  console.error(`${failures.length} source(s) failed — fix the markup (e.g. the ` +
    `@errors code list) and rerun.`)
  process.exit(1)
}

function tally(kinds) {
  const counts = {}
  for (const k of kinds) counts[k] = (counts[k] ?? 0) + 1
  return Object.entries(counts).map(([k, n]) => (n > 1 ? `${k}×${n}` : k)).join(' ')
}

function firstLine(s) {
  return String(s).split('\n')[0]
}
