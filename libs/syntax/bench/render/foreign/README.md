# `syntax-foreign-bench` — foreign highlighter panel

Runs four **other** syntax highlighters over the same corpus as the in-process
[`syntax-render-bench`](../README.md) and reports **MB/s of source highlighted**,
so `sparkles:syntax`'s ANSI/HTML renderers can be placed against the field on
identical input.

| Tool         | Engine / grammars           | ANSI | HTML | Source            |
| ------------ | --------------------------- | :--: | :--: | ----------------- |
| `bat`        | syntect / Sublime-syntax    |  ✓   |      | `pkgs.bat`        |
| `chroma`     | Go, Pygments-derived        |  ✓   |  ✓   | `pkgs.chroma`     |
| `pygmentize` | Pygments                    |  ✓   |  ✓   | `pygments`        |
| `shiki-html` | TextMate / VS Code grammars |      |  ✓   | `buildNpmPackage` |

The tools are Nix-pinned in
[`nix/packages/syntax-foreign.nix`](../../../../../nix/packages/syntax-foreign.nix)
as the `syntax-foreign` linkFarm (`result/bin/{bat,chroma,pygmentize,shiki-html}`).

## What it measures — and what it does NOT

> [!IMPORTANT]
> These are **end-to-end wall-clock** numbers. Each timed run **spawns the tool**,
> which pays process startup + grammar/theme load + a full parse + render, every
> time. That is deliberately **not** comparable to the in-process `ansi`/`html`
> rows in the parent bench (those parse once and re-render a cached event stream —
> pure render cost). It **is** comparable:
>
> - among the foreign tools (same methodology), and
> - to our own **end-to-end** path (read file → tree-sitter parse → render),
>   which is the honest apples-to-apples comparison.

To keep spawn cost from dominating, each corpus file is **concatenated ×N to
~1.5 MB** before highlighting, so the wall time is mostly the highlighter's
throughput, not `fork`/`exec`. The reported rate is `input_bytes ÷ median_wall_time`.

## Languages

The runner is **language-aware**: it only runs a `(tool, language)` cell when the
tool advertises a grammar for it, and it treats a non-zero exit or empty output
during the warmup run as "unsupported" and skips the cell rather than failing.

Corpus (under [`../corpus/`](../corpus/)): `sample.d` (the shared D corpus),
plus `sample.py` and `sample.ts` — **original BSL-1.0 code (ours)**, authored to
mirror the D corpus's token texture so every tool (and shiki in particular, whose
D grammar we also exercise) has representative work. No third-party source is
vendored.

## Running

```sh
# 1. Build the pinned tool panel.
nix build .#syntax-foreign          # -> ./result/bin/{bat,chroma,pygmentize,shiki-html}

# 2. Run the panel (bin dir via $SYNTAX_FOREIGN or as argv[1]).
SYNTAX_FOREIGN="$PWD/result/bin" \
    dub run --root=libs/syntax/bench/render/foreign

# or point it explicitly:
dub run --root=libs/syntax/bench/render/foreign -- "$PWD/result/bin"
```

Environment knobs:

| Variable                | Default                              | Meaning                               |
| ----------------------- | ------------------------------------ | ------------------------------------- |
| `SYNTAX_FOREIGN`        | (argv[1], then `$PATH`)              | bin dir with the four wrappers        |
| `SYNTAX_FOREIGN_REPS`   | `5`                                  | timed runs per cell (median reported) |
| `SYNTAX_FOREIGN_TARGET` | `1500000`                            | concatenated input size, bytes        |
| `SYNTAX_FOREIGN_LANGS`  | (all present)                        | comma list to restrict languages      |
| `SYNTAX_FOREIGN_JSON`   | `results/<date>-<host>-foreign.json` | JSON snapshot path                    |

The run prints a comparison table and writes a JSON snapshot under
[`results/`](./results/) for the record.
