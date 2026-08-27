# Editor project search — Zed and VS Code

Two editors with the same problem hue has, and the same answer: **neither wrote a
search engine.** That makes hue's decision to write one a deliberate divergence,
and this page is where the reasons are recorded.

> **Last reviewed:** August 28, 2026.

---

## VS Code — marshalling ripgrep

VS Code's search is a **ripgrep subprocess** behind a service boundary
(`ripgrepTextSearchEngine`, `ripgrepSearchProvider`, `textSearchManager` in
`src/vs/workbench/services/search/node/`). It consumes `--json` output, applies
result caps, and cancels by killing the process.

It is the [live-grep host][hosts] pattern with more engineering: a stable
provider API, structured output instead of `path:line:col:text`, and result caps
enforced by the consumer. The costs are the same ones — process per query, no
resume, no partial-ranking contract.

## Zed — a Rust searcher in-process

Zed's `crates/search/` plus its project layer take a different route: a
`SearchQuery` value (regex / whole-word / case / include-ignored) evaluated
**in-process** over Rust's `regex` crate, with the walk and the matching inside
the editor.

The design detail worth taking is that Zed **searches open buffers separately from
disk**. An unsaved edit is not on disk, so a filesystem search cannot see it, and
an editor that reports stale results for the file you are looking at is
immediately and obviously wrong.

hue has the same problem the moment its grep source ships: the open document may
differ from the file on disk, and the format-preview and DSV paths already hold
transformed in-memory content. **The corpus is not simply the filesystem**, which
is a requirement `PKS2` does not currently state.

## What the two together establish

**Neither editor wrote an engine.** VS Code marshals someone else's; Zed uses a
library. The industry answer to "how does an editor do project search" is
_acquire, do not build_.

So hue's position needs a reason, and it has one — the same one
[`picker.md`][picker] gives for writing `sparkles:fuzzy` rather than binding fff:

- **A `@safe pure nothrow @nogc` engine with caller-owned fixed capacity** is not
  something available to acquire in D.
- **The Android target** rules out a subprocess outright.
- **The interactive contract** — budget, generation cancellation, globally-ranked
  partial results — is absent from every acquirable scanner, per
  [interactive-contracts](./interactive-contracts.md).
- **One engine must serve two consumers**, the picker's grep source and the
  in-document search, which a subprocess cannot do for the open buffer.

The last point is the one Zed makes concrete, and it is the strongest of the four:
an in-process engine can search a buffer, and a subprocess fundamentally cannot.

## What this catalog concluded

1. **The divergence is justified**, and the justification should be written into
   the spec rather than assumed — the same way `picker.md` justifies `PKM`.
2. **Take Zed's buffer/disk split as a requirement.** The grep source's corpus is
   the working tree _plus_ modified open documents, and the in-document search is
   the degenerate case of that with one file.
3. **Take VS Code's caps discipline**: a UI-side cap enforced independently of the
   engine's own limits, so a pathological result set cannot reach the renderer.

## Sources

`[literature]` from documented architecture, with both trees cloned locally
(`rust/zed`, `ts/vscode`). No decision here rests on a specific line, and the
[duplicate-`vscode`-clone hazard][plan] means no `[source-verified]` claim is made
against that tree. Related: [live-grep-hosts][hosts],
[interactive-contracts](./interactive-contracts.md).

<!-- References -->

[hosts]: ./live-grep-hosts.md
[picker]: ../../specs/hue/picker.md
[plan]: ./sparkles-baseline.md
