#!/usr/bin/env node
// Tiny CLI over shiki's codeToHtml for the sparkles:syntax foreign benchmark
// panel. Reads a source file + language from argv and prints highlighted HTML
// to stdout — the end-to-end path (process startup + WASM oniguruma load +
// TextMate tokenize + HTML render) the foreign benchmark measures.
//
//   shiki-html <file> <lang> [theme]
//
// Exit codes:
//   0  success (HTML on stdout)
//   2  unsupported language (stderr note) — the D runner skips such pairs
//   1  any other error
import { readFile } from 'node:fs/promises';
import { codeToHtml, bundledLanguages } from 'shiki';

async function main() {
  const [, , file, lang, theme = 'catppuccin-mocha'] = process.argv;
  if (!file || !lang) {
    process.stderr.write('usage: shiki-html <file> <lang> [theme]\n');
    process.exit(1);
  }
  if (!(lang in bundledLanguages)) {
    process.stderr.write(`shiki: unsupported language '${lang}'\n`);
    process.exit(2);
  }
  const code = await readFile(file, 'utf8');
  const html = await codeToHtml(code, { lang, theme });
  process.stdout.write(html);
}

main().catch(err => {
  process.stderr.write(String(err?.stack ?? err) + '\n');
  process.exit(1);
});
