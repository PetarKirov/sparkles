# Sparkles Markdown Parser Specification

## Status

Draft v0.1

## Goal

Design a **best-in-class**, **spec-compliant**, **high-performance** Markdown engine for Sparkles, implemented in D, with:

1. Full CommonMark compatibility.
2. Opt-in support for all VitePress and Nextra markdown/MDX extensions and behaviors.
3. A rigorous, multi-ecosystem conformance suite.
4. Reproducible, cross-language benchmarks.

## Design Principles

This design follows Sparkles engineering guidance and explicitly applies:

1. Local reasoning and explicit contracts.
2. Functional, pipeline-oriented processing where possible.
3. Design-by-introspection (DbI): shell + optional hooks.
4. Clear separation between parsing semantics and rendering/presentation semantics.

## Non-Goals

1. Full VitePress site-generation behavior (routing, Vite asset graph, Vue compilation) inside the parser.
2. A browser runtime.
3. Non-markdown authoring UI/editor concerns.

## Deliverables

1. `libs/markdown` parser package.
2. `libs/markdown/SPEC.md` (this document).
3. `libs/markdown/TESTING.md` (detailed conformance, compatibility, adversarial, and benchmark strategy).
4. Conformance and compatibility corpus with provenance metadata.
5. Benchmark harness with adapters for major parsers.

## Compliance Targets

## CommonMark

1. Target spec: **CommonMark 0.31.2**.
2. Requirement: 100% pass on official CommonMark examples.
3. Requirement: linear-time behavior on known pathological families.

## GFM and Adjacent Extensions

1. VitePress-compatible surface should be available behind options.
2. Default mode remains strict CommonMark (+ minimal safety defaults).

## Nextra / MDX Compatibility

1. Provide a `nextra_compatible` profile that supports Nextra markdown + MDX authoring expectations.
2. Treat JSX/ESM in `.mdx` as first-class syntax in Nextra profile.
3. Keep Markdown-only profile independent from MDX-specific semantics.

## VitePress and Nextra Extension Matrix

The parser must support syntax and metadata needed by VitePress and Nextra features. Some are parse-time; others are transform/render-time.

### VitePress

| Feature                  | Syntax/Behavior                           | Phase                            | Default                 |
| ------------------------ | ----------------------------------------- | -------------------------------- | ----------------------- |
| Header anchors           | auto IDs for headings                     | post-parse transform             | on                      |
| Custom anchors           | `# Title {#id}`                           | block parse + post-parse         | on                      |
| Internal links           | `.md`/`.html`/extensionless normalization | render transform                 | on                      |
| External links attrs     | `target="_blank" rel="noreferrer"`        | render transform                 | on                      |
| YAML frontmatter         | leading `---` block                       | pre-parse split                  | on                      |
| GFM tables               | pipe table syntax                         | block extension                  | on in vitepress profile |
| Emoji shortcodes         | `:tada:`                                  | inline extension                 | on in vitepress profile |
| TOC token                | `[[toc]]`                                 | block extension + post transform | on in vitepress profile |
| Custom containers        | `::: info`, `::: tip`, etc                | block extension                  | on in vitepress profile |
| Container attrs          | e.g. `{open}`                             | attribute parser extension       | on in vitepress profile |
| `raw` container          | `::: raw`                                 | block extension + render hint    | on in vitepress profile |
| GFM alerts               | `> [!NOTE]` etc                           | block extension                  | on in vitepress profile |
| Fence language/meta      | ` ```ts {1} :line-numbers `               | fence info/meta parser           | on                      |
| Line highlight           | `{1,3-5}` and marker comments             | code metadata transform          | on in vitepress profile |
| Focus/diff/error markers | `[!code focus]`, `[!code --]`, etc        | code metadata transform          | on in vitepress profile |
| Line numbers             | global + per-block override               | render transform                 | on in vitepress profile |
| Code import              | `<<< @/file{...}`                         | preprocessor                     | on in vitepress profile |
| Code groups              | `::: code-group`                          | block extension                  | on in vitepress profile |
| Markdown include         | `<!--@include: ...-->`                    | preprocessor                     | on in vitepress profile |
| Math equations           | `$...$`, `$$...$$`                        | inline/block extension           | off (opt-in)            |
| Image lazy loading       | `loading="lazy"` behavior                 | render transform                 | off                     |

### Nextra

| Feature                        | Syntax/Behavior                             | Phase                         | Default              |
| ------------------------------ | ------------------------------------------- | ----------------------------- | -------------------- |
| MDX support                    | ESM imports/exports + JSX in `.mdx`         | mdx parse mode                | on in nextra profile |
| GFM core                       | strikethrough/tasklist/table/autolink       | block+inline extension        | on in nextra profile |
| Custom heading id              | `## Heading [#custom-id]`                   | heading post-process          | on in nextra profile |
| GitHub alerts                  | `> [!NOTE]` etc mapped to callout semantics | block extension + render hint | on in nextra profile |
| Code fence line highlight      | ` ```js {1,4-5} `                           | code metadata parse           | on in nextra profile |
| Code fence substring highlight | ` ```js /useState/ `                        | code metadata parse           | on in nextra profile |
| Code copy button metadata      | ` ```js copy ` / `copy=false`               | code metadata parse           | on in nextra profile |
| Code line numbers metadata     | ` ```js showLineNumbers `                   | code metadata parse           | on in nextra profile |
| Code filename/title metadata   | ` ```js filename="example.js" `             | code metadata parse           | on in nextra profile |
| Inline code language hint      | `` `let x = 1{:jsx}` ``                     | inline code extension         | on in nextra profile |
| Mermaid blocks                 | ` ```mermaid `                              | fenced block extension        | on in nextra profile |
| LaTeX inline                   | `$...$` when `latex` enabled                | inline extension              | off (opt-in)         |
| LaTeX display                  | ` ```math ` fenced blocks                   | fenced block extension        | off (opt-in)         |
| Internal links                 | markdown links transformed to app links     | render transform              | on in nextra profile |
| Static markdown image          | `![](...)` to image component semantics     | render transform              | on in nextra profile |

## Profiles

The engine exposes explicit profiles:

1. `commonmark_strict`.
2. `vitepress_compatible`.
3. `nextra_compatible`.
4. `gfm`.
5. `custom` (feature set assembled from options).

## Architecture

## High-Level Pipeline

```text
bytes
  -> decoding + newline normalization
  -> preprocessors (optional: include, snippet import, frontmatter split)
  -> block parser (Markdown) / MDX parser (profile-dependent)
  -> inline parser
  -> event stream
  -> AST builder (optional)
  -> post-parse transforms (anchors, toc, code metadata)
  -> renderer(s): HTML / XML / CommonMark / event sink
```

## Core Representation

1. Event stream is the primary representation for performance and streaming-style transforms.
2. AST is optional and built from events for consumers needing tree surgery.
3. Source positions are carried in both forms.
4. In MDX-enabled profiles, AST must preserve JSX and ESM node boundaries losslessly.

## Performance Constraints

1. O(n) parse time for typical and adversarial documents.
2. No catastrophic backtracking; avoid regex-heavy critical paths.
3. Low allocation strategy: arenas and reusable buffers.
4. Separate parse and render passes to preserve composability.

## Safety and Limits

1. Hard caps for maximum nesting depth, include depth, and file size.
2. Explicit option for dangerous HTML/protocols.
3. Default-safe URL and raw HTML handling.

## DbI Extension System (Shell With Hooks)

The parser core is the shell; extensions are hooks with optional capabilities.

## Required Hook Primitive

An extension must provide only identity and registration metadata.

## Optional Hook Primitives

1. `preprocessDocument`
2. `tryStartBlock`
3. `tryParseInline`
4. `onPostParse`
5. `onRenderNode`
6. `onError`

Absence of any optional primitive must preserve baseline correctness.

## Capability Detection

Capability checks are centralized in traits; no scattered ad-hoc `__traits(compiles, ...)`.

```d
enum bool hasPreprocessDocument(E, Ctx) = __traits(compiles, {
    E e = E.init;
    Ctx c = Ctx.init;
    e.preprocessDocument(c);
});
```

## Dispatch Precedence

1. Full override hook (if present)
2. Event-specific hook
3. Core fallback path

## API Sketch

```d
struct MarkdownOptions(Hook = void)
{
    Profile profile;
    Hook hook;
    bool sourcePos;
    bool safeMode;
    Limits limits;
}

ParseResult parse(string input, MarkdownOptions!Hook opts = MarkdownOptions!void());
string toHtml(ParseResult doc, RenderOptions opts = RenderOptions());
```

## Verification and Benchmarking

The complete strategy is defined in [TESTING.md](./TESTING.md).

At a high level:

1. Validation is profile-aware (`commonmark_strict`, `gfm`, `vitepress_compatible`, `nextra_compatible`, `custom`) and tiered (normative conformance, compatibility, differential, adversarial/fuzz).
2. Fixture ingestion is deterministic and provenance-aware (source URL, commit SHA, license metadata).
3. Comparison uses canonicalized HTML with explicit profile-scoped override policy for ambiguous cases.
4. Compatibility packs explicitly cover both VitePress and Nextra markdown/MDX semantics without conflating framework-runtime behavior.
5. Benchmarking compares major JavaScript, Rust, C, and Go implementations under pinned, reproducible fairness constraints.

## Success Criteria

1. 100% CommonMark conformance in strict profile.
2. 100% pass on selected VitePress compatibility packs in `vitepress_compatible` profile.
3. 100% pass on selected Nextra compatibility packs in `nextra_compatible` profile.
4. No known crash or unbounded-time cases in adversarial suite.
5. Performance in top tier of CommonMark-compliant implementations for at least parse-only throughput.

## Milestones

1. M1: Core parser skeleton + CommonMark block/inline baseline.
2. M2: CommonMark full compliance + sourcepos + safety defaults.
3. M3: Extension shell (DbI) + GFM primitives.
4. M4: Full VitePress-compatible feature set.
5. M5: Corpus ingestion automation and differential dashboard.
6. M6: Benchmark harness and optimization rounds.

## Risks and Mitigations

1. Divergent extension semantics across ecosystems; mitigate with profile-scoped expectations.
2. Include/snippet features introducing IO/security risk; mitigate with sandboxed path policy and explicit opts.
3. Benchmark bias across runtimes; mitigate with transparent adapters and separate in-process vs CLI metrics.
4. Extension complexity regressing performance; mitigate with optional hooks and zero-cost disabled branches.

## Open Questions

1. Should VitePress compatibility include Vue SFC/component interpolation semantics, or only markdown-stage behavior?
2. Should math rendering be parser-owned (MathJax/KaTeX coupling) or token-only with downstream renderer hooks?
3. Should default profile be strict CommonMark or VitePress-compatible for `libs/markdown` consumers?
4. What minimum Rust/Node/Go toolchain versions should benchmark CI pin?
5. When both VitePress and Nextra heading-id syntaxes are enabled, which one takes precedence in ambiguous headings?
