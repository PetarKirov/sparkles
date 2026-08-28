// Dev-only VISUAL-regression check for the twoslash HTML overlay. Renders each
// fixture through `hue --twoslash <payload> view --html`, lays it out in
// headless Chrome, and
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
  // A block inside a connected row is a different layout — its previous sibling
  // is a connector, not the code line — so the stacked-layout gap/column
  // invariants below measure the first block that is NOT in one. The connected
  // rows have their own invariants, measured separately below.
  const one = (sel) => { const el = [...document.querySelectorAll(sel)]
    .find(e => !e.closest('.twoslash-crowded-row')); return el && {
    gap: gapAbove(el), col: leftCol(el), arrow: !!el.querySelector(':scope > .twoslash-popup-arrow') }; };
  // A connector stroke, in page pixels, so continuity can be checked ACROSS
  // rows: a guide segment that fills its own row still leaves a visible break
  // if the next row starts below where it ended.
  const seg = (el, kind, row) => {
    const r = el.getBoundingClientRect();
    return { kind, row, col: leftCol(el),
      top: +r.top.toFixed(2), bottom: +r.bottom.toFixed(2) };
  };
  // A crowded line: the connected layout's rows, in document (top-to-bottom)
  // order, each with its label's column, its elbow's column, and the columns
  // and heights of the guides still running through it — plus every stroke as
  // a page-pixel segment, for the continuity check.
  const crowded = [...document.querySelectorAll('.twoslash-crowded')].map(box => {
    const markers = box.querySelector('.twoslash-crowded-markers');
    const segments = [];
    const rows = [...box.querySelectorAll('.twoslash-crowded-row')].map((row, i) => {
      const rh = row.getBoundingClientRect().height;
      const label = row.querySelector('.twoslash-query-line, .twoslash-completion-list, .twoslash-error-line');
      const elbow = row.querySelector('.twoslash-crowded-elbow');
      const arrow = row.querySelector('.twoslash-popup-arrow');
      if (elbow) segments.push(seg(elbow, 'elbow', i));
      // The notch's CENTRE, not its left edge: it is a 6px diamond that has to
      // straddle the 1px rule, so its edge is never the thing to compare.
      const arrowCentre = (el) => {
        const r = el.getBoundingClientRect();
        return +((r.left + r.width / 2 - col0) / charW).toFixed(2);
      };
      return {
        label: label ? leftCol(label) : null,
        elbow: elbow ? leftCol(elbow) : null,
        arrow: arrow ? arrowCentre(arrow) : null,
        guides: [...row.querySelectorAll('.twoslash-crowded-guide')].map(g => {
          segments.push(seg(g, 'guide', i));
          return {
            col: leftCol(g),
            fill: +(g.getBoundingClientRect().height / rh).toFixed(3),
          };
        }),
      };
    });
    // Where the marker row puts its anchors. The row is preformatted text
    // sharing the code's left edge, so the glyph at text index i sits at
    // column i -- the index IS the column. (No backticks in here: this comment
    // lives inside a JS template literal.)
    const anchorCols = [...markers.textContent]
      .map((ch, i) => (ch === '\\u252c' ? i : -1))
      .filter(i => i >= 0);
    return {
      markers: markers.textContent,
      markersBottom: +markers.getBoundingClientRect().bottom.toFixed(2),
      anchorCols,
      rows,
      segments,
    };
  });
  document.getElementById('__vc__').textContent = JSON.stringify({
    charW: +charW.toFixed(2),
    query: one('.twoslash-query-line'),
    completion: one('.twoslash-completion-list'),
    crowded,
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
const CONNECT_TOL = 0.5; // px a connector column may break between two strokes

const fixturesDir = join(here, 'fixtures');
const names = [
  '16-crowded',
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
  // `--twoslash <payload>` is a global overlay option, so it precedes the
  // subcommand; `view --html` is what `--html` alone used to mean.
  const html = execFileSync(hue, ['--twoslash', fixture, 'view', '--html'], {
    encoding: 'utf8',
  });
  const m = measure(html);
  const problems = [];
  const crowdedRows = (m.crowded ?? []).reduce((n, b) => n + b.rows.length, 0);
  let maxBreak = 0;

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

  // Connected layout (CON1-CON3): the labels peel off right to left, each
  // elbow sits on its label's column, every guide is left of the label it is
  // passing, and a guide spans its whole row so a multi-row card never
  // detaches the anchors below it.
  for (const box of m.crowded ?? []) {
    let previous = Infinity;
    for (const [i, row] of box.rows.entries()) {
      if (row.label === null) {
        problems.push(`crowded row ${i} has no label`);
        continue;
      }
      if (row.elbow === null || Math.abs(row.elbow - row.label) > COL_TOL)
        problems.push(
          `crowded row ${i} elbow ${row.elbow} off label ${row.label}`,
        );
      // One column carries the whole chain: the `┬` under the span, the rule
      // down to the label, and the notch the label points back with.
      if (
        row.elbow !== null &&
        !box.anchorCols.some(c => Math.abs(c - row.elbow) <= COL_TOL)
      )
        problems.push(
          `crowded row ${i} elbow ${row.elbow} sits on no marker column (${box.anchorCols.join(',')})`,
        );
      if (
        row.arrow !== null &&
        row.elbow !== null &&
        Math.abs(row.arrow - row.elbow) > COL_TOL
      )
        problems.push(
          `crowded row ${i} arrow ${row.arrow} off the connector column ${row.elbow}`,
        );
      if (row.label >= previous)
        problems.push(
          `crowded row ${i} label at ${row.label} is not left of the row above (${previous})`,
        );
      previous = row.label;
      for (const g of row.guides) {
        if (g.col >= row.label)
          problems.push(
            `crowded row ${i} guide at ${g.col} is not left of its label`,
          );
        if (g.fill < 0.99)
          problems.push(
            `crowded row ${i} guide fills only ${g.fill} of the row`,
          );
      }
    }

    // CON3 continuity. `fill` above only says a segment spans its OWN row; a
    // column still reads as a dashed line if the next row starts below where
    // the last one ended (the card's `margin-top` falling between the rows).
    // Every stroke at one column — guides, then the elbow that ends it — must
    // form one unbroken rule.
    const byCol = new Map();
    for (const s of box.segments) {
      const key = s.col.toFixed(1);
      if (!byCol.has(key)) byCol.set(key, []);
      byCol.get(key).push(s);
    }
    for (const [col, segs] of byCol) {
      segs.sort((a, b) => a.top - b.top);
      for (let i = 1; i < segs.length; i++) {
        const gap = +(segs[i].top - segs[i - 1].bottom).toFixed(2);
        maxBreak = Math.max(maxBreak, gap);
        if (gap > CONNECT_TOL)
          problems.push(
            `crowded column ${col}: ${gap}px break above the ${segs[i].kind} in row ${segs[i].row}`,
          );
      }
    }
  }

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
  if (crowdedRows)
    parts.push(
      `crowded{lines:${m.crowded.length} rows:${crowdedRows} maxBreak:${maxBreak}px}`,
    );
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
