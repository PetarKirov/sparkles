// Dev-only previewer: renders every committed fixture through
// `hue --twoslash --html` into a git-ignored `html/` directory next to
// `fixtures/`, one standalone page per example plus an `index.html` that links
// them. Handy for eyeballing the overlay after touching the HTML renderer or the
// stylesheet — open `html/index.html` and hover the underlined tokens.
//
// Each page adds a preview shell around hue's content-only fragment: a header
// (name · node-kind tally · prev/next/index nav), a full-height code pane, and a
// physical-line-numbered gutter (numbers are CSS `::before`, so they never enter
// a text selection; below-line twoslash annotations and any soft wrapping do not
// advance the count).
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

const VOID = new Set([
  'br',
  'hr',
  'img',
  'input',
  'wbr',
  'col',
  'area',
  'base',
  'link',
  'meta',
  'source',
  'track',
]);

// Split the outer `<code>` HTML into PHYSICAL lines and below-line annotations,
// wrapping each physical line's content in an inline `<span class="ln">` (which
// carries the line counter) and passing annotations through untouched (no
// number). Physical-line boundaries are the `'\n'`s at tag-depth 0 — hue balances
// every tag at each line seam, and popup markup (with its own newlines) stays
// nested at depth > 0, so those newlines never split a line. The `'\n'` is KEPT
// (a literal text node after the span), so `white-space: pre` draws the line
// breaks and a copied selection preserves every line — including blank ones,
// which would vanish if each line were a self-collapsing block. Returns
// `{ html, lines }`.
function relayout(code) {
  let depth = 0;
  let line = '';
  let anno = '';
  let inAnno = false;
  const out = [];
  let lines = 0;
  // `nl` appends the physical newline after the line span (omitted only for a
  // final line the source didn't newline-terminate, or a defensive mid-line flush).
  const emitLine = nl => {
    out.push(`<span class="ln">${line}</span>` + (nl ? '\n' : ''));
    line = '';
    lines++;
  };

  let i = 0;
  while (i < code.length) {
    const ch = code[i];
    if (ch === '<') {
      const gt = code.indexOf('>', i);
      const raw = code.slice(i, gt + 1);
      const m = /^<(\/?)([a-zA-Z0-9]+)/.exec(raw);
      const closing = !!(m && m[1]);
      const name = m ? m[2].toLowerCase() : '';
      const isVoid = VOID.has(name) || raw.endsWith('/>');

      // A below-line block opens at depth 0 (query/error/tag `<div>` or the
      // completion `<ul>`). Everything until it balances back to depth 0 is one
      // annotation, emitted verbatim with no line number.
      if (
        !inAnno &&
        depth === 0 &&
        !closing &&
        /class="[^"]*\b(?:twoslash-meta-line|twoslash-completion-list|twoslash-tag-line)\b/.test(
          raw,
        )
      ) {
        if (line.length) emitLine(false); // defensive; a '\n' already flushed it
        inAnno = true;
        anno = '';
      }

      inAnno ? (anno += raw) : (line += raw);
      if (!isVoid) depth += closing ? -1 : 1;
      if (inAnno && depth === 0) {
        out.push(anno);
        inAnno = false;
      }
      i = gt + 1;
    } else if (ch === '\n') {
      if (inAnno) anno += ch;
      else if (depth === 0)
        emitLine(true); // physical line boundary — keep the newline
      else line += ch; // newline nested in popup markup — keep verbatim
      i++;
    } else {
      let j = i;
      while (j < code.length && code[j] !== '<' && code[j] !== '\n') j++;
      const text = code.slice(i, j);
      inAnno ? (anno += text) : (line += text);
      i = j;
    }
  }
  if (line.length) emitLine(false);
  return { html: out.join(''), lines };
}

// Wrap hue's content-only fragment (its own <style> + <pre class="syn-root">) in
// a full-height preview shell with a numbered gutter and prev/next nav.
function page(name, kinds, fragment, prev, next) {
  // Match <main>'s background to the code block's, extracted from the theme.
  const bg =
    (fragment.match(/\.syn-root\s*{[^}]*background-color:\s*(#[0-9a-fA-F]+)/) ||
      [])[1] || '#1e1e2e';

  // Number the physical lines inside the outer <pre><code>.
  let gutter = 3;
  const withLines = fragment.replace(
    /(<pre class="syn-root twoslash"><code>)([\s\S]*)(<\/code><\/pre>)/,
    (_, open, inner, close) => {
      const r = relayout(inner);
      gutter = String(r.lines).length + 2; // digits + 1ch number-gap + 1ch pad
      return open + r.html + close;
    },
  );

  const navLink = (target, label, cls) =>
    target
      ? `<a class="${cls}" href="${target}.html">${label}</a>`
      : `<span class="${cls} disabled">${label}</span>`;

  return (
    `<!doctype html>\n<html lang="en"><head><meta charset="utf-8">\n` +
    `<meta name="viewport" content="width=device-width,initial-scale=1">\n` +
    `<title>twoslash · ${esc(name)}</title>\n` +
    `<style>\n` +
    `  html, body { height: 100%; }\n` +
    `  body { margin: 0; background: ${bg}; color: #cdd6f4;\n` +
    `         font: 14px/1.5 system-ui, sans-serif;\n` +
    `         display: flex; flex-direction: column; }\n` +
    `  header { flex: none; display: flex; gap: 0.9em; align-items: baseline;\n` +
    `           flex-wrap: wrap; padding: 0.7em 1em;\n` +
    `           background: #181825; border-bottom: 1px solid #313244; }\n` +
    `  header b { font-size: 1.05em; } header .kinds { color: #a6adc8; }\n` +
    `  header .spacer { flex: 1; } header a { color: #89b4fa; text-decoration: none; }\n` +
    `  header a:hover { text-decoration: underline; }\n` +
    `  header .disabled { color: #45475a; }\n` +
    // The single scroll container: the code pane fills the remaining height, so
    // only ONE scrollbar ever appears (no nested body + pre scrollbars).
    `  main { flex: 1; min-height: 0; overflow: auto; background: ${bg}; }\n` +
    `  main pre.syn-root { margin: 0; padding: 0.6em 1ch; min-height: 100%;\n` +
    `                      box-sizing: border-box; }\n` +
    // Line-number gutter: a left pad on <code> holds the numbers; each physical
    // line's number is generated content (never selected/copied). Below-line
    // annotations aren't `.ln`, so they carry no number and don't advance it.
    `  main pre.syn-root > code { display: block; counter-reset: lineno;\n` +
    `                             padding-left: ${gutter}ch; }\n` +
    // `.ln` is INLINE — the physical `\n` after each span (kept by relayout)
    // draws the line breaks under `white-space: pre` and gives blank lines their
    // height, and a copied selection keeps every line. `position: relative` +
    // `counter-increment` anchor the gutter number to each line's start.
    `  .ln { position: relative; counter-increment: lineno; }\n` +
    `  .ln::before { content: counter(lineno); position: absolute;\n` +
    `                left: -${gutter}ch; width: ${gutter - 1}ch; text-align: right;\n` +
    `                color: #6c7086; -webkit-user-select: none; user-select: none; }\n` +
    // (Hidden hover popups take no layout — the shipped twoslash.css now hides
    // them with `display:none`, so no preview override is needed for the
    // scroll-width / newline artifacts they used to cause.)
    // Selection domains (VSCode-like). The shipped twoslash.css sets the
    // below-line annotations `user-select: none` (code copies cleanly for every
    // consumer). The preview goes further: a drag is confined to whichever
    // domain it STARTS in — the code, or one annotation. Override the shipped
    // `none` back to selectable so a drag can begin inside an annotation…
    `  main .twoslash :is(.twoslash-meta-line, .twoslash-completion-list, .twoslash-tag-line) {\n` +
    `    -webkit-user-select: text; user-select: text; }\n` +
    // …started in code → annotations drop out of the selection;
    `  body.sel-code :is(.twoslash-meta-line, .twoslash-completion-list, .twoslash-tag-line) {\n` +
    `    -webkit-user-select: none; user-select: none; }\n` +
    // …started in an annotation → only that one stays selectable (contained).
    `  body.sel-anno main pre.syn-root > code { -webkit-user-select: none; user-select: none; }\n` +
    `  body.sel-anno :is(.twoslash-meta-line, .twoslash-completion-list, .twoslash-tag-line) {\n` +
    `    -webkit-user-select: none; user-select: none; }\n` +
    `  body.sel-anno .sel-active, body.sel-anno .sel-active * {\n` +
    `    -webkit-user-select: text; user-select: text; }\n` +
    `</style></head><body>\n` +
    `<header>${navLink(prev, '← prev', 'prev')}` +
    `<b>${esc(name)}</b><span class="kinds">${esc(kinds)}</span>` +
    `<span class="spacer"></span><a href="index.html">all</a>` +
    `${navLink(next, 'next →', 'next')}</header>\n` +
    `<main>${withLines}</main>\n` +
    // Confine each drag to the domain it started in: mark the annotation the
    // mousedown landed in (if any) and flag the body so the CSS above restricts
    // the other domain. Runs before the drag extends, so the restriction applies
    // to the selection this mousedown begins.
    `<script>\n` +
    `const A = '.twoslash-meta-line,.twoslash-completion-list,.twoslash-tag-line';\n` +
    `addEventListener('mousedown', e => {\n` +
    `  document.querySelectorAll('.sel-active').forEach(el => el.classList.remove('sel-active'));\n` +
    `  const a = e.target.closest(A);\n` +
    `  if (a) a.classList.add('sel-active');\n` +
    `  document.body.classList.toggle('sel-anno', !!a);\n` +
    `  document.body.classList.toggle('sel-code', !a);\n` +
    `});\n` +
    `</script>\n</body></html>\n`
  );
}

const fixtures = readdirSync(fixturesDir)
  .filter(f => f.endsWith('.twoslash.json'))
  .sort();

const names = fixtures.map(f => f.replace(/\.twoslash\.json$/, ''));
const rendered = [];
for (let k = 0; k < fixtures.length; k++) {
  const name = names[k];
  const fixture = join(fixturesDir, fixtures[k]);
  const kinds = tally(JSON.parse(readFileSync(fixture, 'utf8')).nodes);
  const fragment = execFileSync(hue, ['--twoslash', '--html', fixture], {
    encoding: 'utf8',
  });
  writeFileSync(
    join(outDir, `${name}.html`),
    page(name, kinds, fragment, names[k - 1], names[k + 1]),
  );
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
