// Dev-only VISUAL-regression check for the twoslash HTML overlay. Renders each
// fixture through `hue --twoslash --html`, lays it out in headless Chrome, and
// asserts geometry invariants that plain markup/CSS diffs (compare-shiki.mjs)
// cannot see — the popup positioning bugs that were only visible once rendered:
//
//   1. below-line popups (query, completion) detach from their code line by a
//      small, uniform gap (~1ch) — catches the inline-flex-in-a-wrapper line-box
//      inflation that pushed the query popup ~3x too far down;
//   2. the completion list anchors under the START of the typed prefix
//      (caret column − prefix length) — catches horizontal-offset regressions.
//
// NOT part of the build. Needs node + a Chromium/Chrome and a built hue:
//   dub build :hue
//   node visual-check.mjs        # or: npm run visual
// The devshell provides Chromium and exports CHROME_BIN; otherwise the script
// searches PATH and skips cleanly (exit 0) if no browser is found.

import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, existsSync, mkdtempSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { tmpdir } from 'node:os';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(here, '..', '..', '..');
const hue = join(repoRoot, 'apps', 'hue', 'build', 'hue');

function findBrowser() {
  if (process.env.CHROME_BIN && existsSync(process.env.CHROME_BIN))
    return process.env.CHROME_BIN;
  for (const name of [
    'chromium',
    'chromium-browser',
    'google-chrome-stable',
    'google-chrome',
    'chrome',
  ]) {
    try {
      return execFileSync('sh', ['-c', `command -v ${name}`], {
        encoding: 'utf8',
      }).trim();
    } catch {
      /* keep looking */
    }
  }
  return null;
}

const browser = findBrowser();
if (!browser) {
  console.log(
    '⊘ visual-check skipped: no Chromium/Chrome found (set CHROME_BIN or run in the devshell)',
  );
  process.exit(0);
}
if (!existsSync(hue)) {
  console.error(
    `✗ hue binary not found at ${hue}\n  build it first: dub build :hue`,
  );
  process.exit(2);
}

// The measurement runs in-page and writes JSON into a hidden node we grep back
// out of `--dump-dom` (no puppeteer dependency).
const PROBE = `
<div id="__vc__" style="display:none"></div>
<script>
addEventListener('load', () => setTimeout(() => {
  const code = document.querySelector('pre.syn-root code') || document.querySelector('pre.syn-root');
  const col0 = code.getBoundingClientRect().left;
  const probe = document.createElement('span'); probe.textContent = '0123456789';
  code.appendChild(probe); const charW = probe.getBoundingClientRect().width / 10; code.removeChild(probe);
  // Gap between a below-line block and the code line immediately above it.
  const gapAbove = (el) => {
    let prev = el.previousSibling, rects = [];
    while (prev && !rects.length) {
      const r = document.createRange();
      prev.nodeType === 3 ? r.selectNodeContents(prev) : r.selectNode(prev);
      rects = [...r.getClientRects()];
      prev = prev.previousSibling;
    }
    if (!rects.length) return null;
    return +(el.getBoundingClientRect().top - rects[rects.length - 1].bottom).toFixed(2);
  };
  const leftCol = (el) => +((el.getBoundingClientRect().left - col0) / charW).toFixed(2);
  const one = (sel) => { const el = document.querySelector(sel); return el && {
    gap: gapAbove(el), col: leftCol(el), arrow: !!el.querySelector(':scope > .twoslash-popup-arrow') }; };
  document.getElementById('__vc__').textContent = JSON.stringify({
    charW: +charW.toFixed(2),
    query: one('.twoslash-query-line'),
    completion: one('.twoslash-completion-list'),
  });
}, 60));
</script>`;

function measure(html) {
  const dir = mkdtempSync(join(tmpdir(), 'tw-vc-'));
  const page = join(dir, 'page.html');
  writeFileSync(page, html + PROBE);
  const dom = execFileSync(
    browser,
    [
      '--headless',
      '--disable-gpu',
      '--no-sandbox',
      '--hide-scrollbars',
      '--virtual-time-budget=3000',
      '--dump-dom',
      `file://${page}`,
    ],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] },
  );
  const m = dom.match(/<div id="__vc__"[^>]*>(.*?)<\/div>/s);
  if (!m) throw new Error('measurement probe produced no output');
  return JSON.parse(m[1]);
}

// Fixture data → expected completion column (caret column − typed prefix).
function completionExpectation(fixture) {
  const doc = JSON.parse(readFileSync(fixture, 'utf8'));
  const n = doc.nodes.find(x => x.type === 'completion');
  if (!n) return null;
  return n.character - (n.completionsPrefix ? n.completionsPrefix.length : 0);
}

const GAP_MIN = 2,
  GAP_MAX = 14; // ~1ch (≈7.8px); the old line-box bug was ~22px
const GAP_SKEW = 5; // query vs completion may differ by at most this
const COL_TOL = 0.6; // completion column tolerance (fraction of a column)

const fixturesDir = join(here, 'fixtures');
const names = [
  '02-query',
  '07-generics',
  '08-jsdoc',
  '10-cut',
  '12-async',
  '13-shiki-rich',
  '03-completions',
];
let failures = 0,
  checked = 0;

console.log('Visual-regression geometry (headless Chrome):\n');
for (const name of names) {
  const fixture = join(fixturesDir, `${name}.twoslash.json`);
  if (!existsSync(fixture)) continue;
  const html = execFileSync(hue, ['--twoslash', '--html', fixture], {
    encoding: 'utf8',
  });
  const m = measure(html);
  const problems = [];

  for (const kind of ['query', 'completion']) {
    const p = m[kind];
    if (!p) continue;
    if (p.gap === null || p.gap < GAP_MIN || p.gap > GAP_MAX)
      problems.push(`${kind} gap ${p.gap}px out of [${GAP_MIN},${GAP_MAX}]`);
    if (!p.arrow) problems.push(`${kind} missing arrow`);
  }
  if (
    m.query &&
    m.completion &&
    m.query.gap != null &&
    m.completion.gap != null &&
    Math.abs(m.query.gap - m.completion.gap) > GAP_SKEW
  )
    problems.push(
      `query/completion gap skew ${Math.abs(m.query.gap - m.completion.gap).toFixed(1)}px > ${GAP_SKEW}`,
    );

  const expectCol = completionExpectation(fixture);
  if (
    m.completion &&
    expectCol != null &&
    Math.abs(m.completion.col - expectCol) > COL_TOL
  )
    problems.push(
      `completion col ${m.completion.col} ≠ expected ${expectCol} (caret−prefix)`,
    );

  const parts = [];
  if (m.query) parts.push(`query{gap:${m.query.gap} arrow:${m.query.arrow}}`);
  if (m.completion)
    parts.push(
      `completion{gap:${m.completion.gap} col:${m.completion.col} arrow:${m.completion.arrow}}`,
    );
  console.log(
    `  ${problems.length ? '✗' : '✓'} ${name.padEnd(14)} ${parts.join(' ')}` +
      (problems.length ? `\n      ${problems.join('\n      ')}` : ''),
  );
  failures += problems.length ? 1 : 0;
  checked++;
}

console.log(`\n${checked} fixtures measured, ${failures} with problems.`);
console.log(
  failures
    ? '\n✗ visual-regression check FAILED'
    : '\n✓ popup geometry within tolerances',
);
process.exit(failures ? 1 : 0);
