// Dev-only previewer: renders every committed fixture through
// `hue --twoslash --html` into a git-ignored `html/` directory next to
// `fixtures/`, one standalone page per example plus an `index.html` that links
// them. Handy for eyeballing the overlay after touching the HTML renderer or the
// stylesheet — open `html/index.html` and hover the underlined tokens.
//
// NOT part of the build. Needs node + a built hue:
//   dub build :hue
//   node render-html.mjs          # or: npm run render
// Full fidelity (syntax highlighting + markdown docs) needs the grammar bundle
// on $SPARKLES_TS_GRAMMAR_PATH — the devshell exports it; without it hue still
// renders, just as plain text.

import { execFileSync } from 'node:child_process';
import { readdirSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..', '..');
const hue = join(repoRoot, 'apps', 'hue', 'build', 'hue');
const fixturesDir = join(here, 'fixtures');
const outDir = join(here, 'html'); // git-ignored, sibling of fixtures/

try {
  execFileSync(hue, ['--help'], { stdio: 'ignore' });
} catch {
  console.error(
    `✗ hue binary not found or not runnable at ${hue}\n  build it first: dub build :hue`,
  );
  process.exit(2);
}

if (!process.env.SPARKLES_TS_GRAMMAR_PATH) {
  console.warn(
    '⚠ SPARKLES_TS_GRAMMAR_PATH unset — output will be plain text (no syntax\n' +
      '  highlighting or markdown docs). Enter `nix develop` for full fidelity.',
  );
}

mkdirSync(outDir, { recursive: true });

// The kind tally (hover×2 query …) summarises what an example exercises.
function tally(nodes) {
  const counts = {};
  for (const n of nodes) counts[n.type] = (counts[n.type] ?? 0) + 1;
  return Object.entries(counts)
    .map(([k, n]) => (n > 1 ? `${k}×${n}` : k))
    .join(' ');
}

const esc = s =>
  s.replace(
    /[&<>"]/g,
    c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c],
  );

// Wrap hue's content-only fragment (its own <style> + <pre class="syn-root">) in
// a minimal dark page so each file opens cleanly on its own.
function page(name, kinds, fragment) {
  return (
    `<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n` +
    `<meta name="viewport" content="width=device-width,initial-scale=1">\n` +
    `<title>twoslash · ${esc(name)}</title>\n` +
    `<style>\n` +
    `  body { margin: 0; background: #11111b; color: #cdd6f4;\n` +
    `         font: 14px/1.5 system-ui, sans-serif; }\n` +
    `  header { padding: 0.7em 1em; border-bottom: 1px solid #313244;\n` +
    `           display: flex; gap: 1em; align-items: baseline; flex-wrap: wrap; }\n` +
    `  header b { font-size: 1.1em; } header code { color: #a6adc8; }\n` +
    `  header a { color: #89b4fa; margin-left: auto; }\n` +
    `  main { padding: 1.2em; overflow-x: auto; }\n` +
    `</style></head><body>\n` +
    `<header><b>${esc(name)}</b><code>${esc(kinds)}</code>` +
    `<a href="index.html">← all examples</a></header>\n` +
    `<main>${fragment}</main>\n</body></html>\n`
  );
}

const fixtures = readdirSync(fixturesDir)
  .filter(f => f.endsWith('.twoslash.json'))
  .sort();

const rendered = [];
for (const file of fixtures) {
  const name = file.replace(/\.twoslash\.json$/, '');
  const fixture = join(fixturesDir, file);
  const kinds = tally(JSON.parse(readFileSync(fixture, 'utf8')).nodes);
  const fragment = execFileSync(hue, ['--twoslash', '--html', fixture], {
    encoding: 'utf8',
  });
  writeFileSync(join(outDir, `${name}.html`), page(name, kinds, fragment));
  rendered.push({ name, kinds });
  console.log(`  ✓ ${name.padEnd(20)} [${kinds}]`);
}

// An index linking every rendered example.
const index =
  `<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n` +
  `<meta name="viewport" content="width=device-width,initial-scale=1">\n` +
  `<title>twoslash examples</title>\n` +
  `<style>\n` +
  `  body { margin: 0 auto; max-width: 48em; padding: 2em 1.5em;\n` +
  `         background: #11111b; color: #cdd6f4; font: 15px/1.6 system-ui, sans-serif; }\n` +
  `  h1 { font-size: 1.4em; } p { color: #a6adc8; }\n` +
  `  ul { list-style: none; padding: 0; }\n` +
  `  li { padding: 0.5em 0; border-bottom: 1px solid #1e1e2e; }\n` +
  `  a { color: #89b4fa; text-decoration: none; font-weight: 600; }\n` +
  `  a:hover { text-decoration: underline; }\n` +
  `  code { color: #a6adc8; font-size: 0.9em; margin-left: 0.6em; }\n` +
  `</style></head><body>\n` +
  `<h1>twoslash overlay examples</h1>\n` +
  `<p>Rendered by <code>hue --twoslash --html</code>. Open one and hover the ` +
  `underlined tokens to see the popups.</p>\n<ul>\n` +
  rendered
    .map(
      r =>
        `  <li><a href="${r.name}.html">${esc(r.name)}</a>` +
        `<code>${esc(r.kinds)}</code></li>`,
    )
    .join('\n') +
  `\n</ul>\n</body></html>\n`;
writeFileSync(join(outDir, 'index.html'), index);

console.log(
  `\n${rendered.length} examples rendered → ${outDir}\n` +
    `open ${join(outDir, 'index.html')}`,
);
