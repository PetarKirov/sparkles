// Dev-only fidelity check: compares the `.twoslash-*` HTML chrome and the CSS
// contract our renderer produces against the reference `@shikijs/twoslash`
// `rendererRich`. NOT part of the build — run it after changing the twoslash
// HTML renderer or the ported stylesheet:
//
//   ./regen.sh                 # (once) install deps
//   node compare-shiki.mjs     # or: npm run compare
//
// Two comparisons (see cryptic-weaving-pizza.md):
//   (a) HTML class-vocabulary coverage — every `.twoslash-*` class shiki emits
//       over the src corpus must also appear in our `hue --twoslash --html`
//       output (and we report any extra classes we emit), modulo an allowlist of
//       intentional model differences.
//   (b) CSS selector coverage — our views/twoslash.css must define every
//       `.twoslash-*` selector shiki's style-rich.css does, modulo the allowlist.
//
// Scope limits (why this is coverage, not a byte diff): the inner *syntax token*
// markup differs (shiki = TextMate + inline styles, us = tree-sitter + `.syn-*`)
// and is out of scope. Both sides now render docs/tags as markdown, but through
// different engines (shiki = markdown-it, us = tree-sitter `MdDoc`), so the docs
// *content* structure can still diverge — the skeleton collapses it, comparing
// the `.twoslash-popup-docs` container and chrome, not the rendered prose.

import { codeToHtml } from 'shiki';
import { transformerTwoslash, rendererRich } from '@shikijs/twoslash';
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { dirname, join, extname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..', '..');
const hue = join(repoRoot, 'apps', 'hue', 'build', 'hue');
const ourCss = join(
  here,
  '..',
  'src',
  'sparkles',
  'twoslash',
  'views',
  'twoslash.css',
);
const shikiCss =
  '/home/petar/code/repos/typescript/shiki/packages/twoslash/style-rich.css';

// Classes that legitimately differ between the two renderers — not gaps.
const ALLOW_SHIKI_ONLY = new Set([
  'twoslash-query-persisted', // shiki renders `^?` as an inline persisted hover…
  'twoslash-query-presisted', // …(+ this upstream typo); we use a below-line block
  'twoslash-completion-cursor', // shiki draws a caret in the completion popup; we don't
  'twoslash-popup-error', // shiki's inline-error popup variant; we use error-line only
  'twoslash-error-hover', // shiki's inline error-hover popup; we render errors below-line only
]);
const ALLOW_OURS_ONLY = new Set([
  'twoslash-query-line',
  'twoslash-meta-line', // our below-line query model
]);

// Extract twoslash-* classes from `class="…"` attributes only, so inlined
// `<style>` blocks (with their `--twoslash-*` custom properties) are ignored.
const classSet = html => {
  const s = new Set();
  for (const m of html.matchAll(/class="([^"]*)"/g))
    for (const c of m[1].split(/\s+/)) if (c.startsWith('twoslash-')) s.add(c);
  return s;
};
const selectorSet = css =>
  new Set([...css.matchAll(/\.(twoslash-[a-z0-9-]+)/g)].map(m => m[1]));

const customTags = ['annotate', 'log', 'warn', 'error'];
const langOf = f => extname(f).slice(1) || 'ts';

function shikiHtml(source, lang) {
  return codeToHtml(source, {
    lang,
    theme: 'github-dark',
    transformers: [
      transformerTwoslash({
        renderer: rendererRich(),
        twoslashOptions: { customTags },
      }),
    ],
  });
}

function ourHtml(fixture) {
  return execFileSync(hue, ['--twoslash', '--html', fixture], {
    encoding: 'utf8',
  });
}

if (!existsSync(hue)) {
  console.error(
    `✗ hue binary not found at ${hue}\n  build it first: dub build :hue`,
  );
  process.exit(2);
}

const sources = readdirSync(join(here, 'src'))
  .filter(f => /\.(ts|tsx)$/.test(f))
  .sort();
const shikiAll = new Set(),
  oursAll = new Set();
let checked = 0;

console.log('Per-fixture twoslash-class coverage (shiki → ours):\n');
for (const file of sources) {
  const name = file.replace(/\.[^.]+$/, '');
  const fixture = join(here, 'fixtures', `${name}.twoslash.json`);
  if (!existsSync(fixture)) continue;
  const shiki = classSet(
    await shikiHtml(
      readFileSync(join(here, 'src', file), 'utf8'),
      langOf(file),
    ),
  );
  const ours = classSet(ourHtml(fixture));
  shiki.forEach(c => shikiAll.add(c));
  ours.forEach(c => oursAll.add(c));
  const missing = [...shiki]
    .filter(c => !ours.has(c) && !ALLOW_SHIKI_ONLY.has(c))
    .sort();
  const mark = missing.length ? '✗' : '✓';
  console.log(
    `  ${mark} ${name.padEnd(16)} shiki:${shiki.size} ours:${ours.size}` +
      (missing.length ? `  MISSING: ${missing.join(', ')}` : ''),
  );
  checked++;
}

// (a) union vocabulary
const missingClasses = [...shikiAll]
  .filter(c => !oursAll.has(c) && !ALLOW_SHIKI_ONLY.has(c))
  .sort();
const extraClasses = [...oursAll]
  .filter(c => !shikiAll.has(c) && !ALLOW_OURS_ONLY.has(c))
  .sort();

// (b) CSS selector coverage
const shikiSel = selectorSet(readFileSync(shikiCss, 'utf8'));
const ourSel = selectorSet(readFileSync(ourCss, 'utf8'));
const missingCss = [...shikiSel]
  .filter(s => !ourSel.has(s) && !ALLOW_SHIKI_ONLY.has(s))
  .sort();

console.log(`\n(a) HTML class vocabulary over ${checked} fixtures`);
console.log(`    shiki classes: ${shikiAll.size}, ours: ${oursAll.size}`);
console.log(
  `    missing (shiki has, we don't): ${missingClasses.length ? missingClasses.join(', ') : '— none'}`,
);
console.log(
  `    extra   (we have, shiki doesn't): ${extraClasses.length ? extraClasses.join(', ') : '— none'}`,
);
console.log(
  `    allowlisted shiki-only: ${[...ALLOW_SHIKI_ONLY].filter(c => shikiAll.has(c)).join(', ') || '—'}`,
);

console.log(`\n(b) CSS .twoslash-* selector coverage`);
console.log(`    shiki selectors: ${shikiSel.size}, ours: ${ourSel.size}`);
console.log(
  `    missing rules (shiki styles, we don't): ${missingCss.length ? missingCss.join(', ') : '— none'}`,
);

console.log(
  `\nScope: inner syntax tokens excluded (different highlighters); docs prose` +
    ` collapsed (both render markdown, via different engines).`,
);

const fail = missingClasses.length || missingCss.length;
console.log(
  fail
    ? '\n✗ coverage gaps found'
    : '\n✓ full chrome + CSS coverage (modulo allowlist)',
);
process.exit(fail ? 1 : 0);
