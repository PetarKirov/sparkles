# Sparkles Markdown Testing and Benchmarking Specification

## Status

Draft v0.1

## Purpose

Define a rigorous, profile-aware validation strategy for `libs/markdown` that ensures:

1. Full CommonMark conformance in strict mode.
2. Clear and testable compatibility contracts for VitePress and Nextra features.
3. Reproducible differential analysis against leading parsers.
4. Stable performance with bounded behavior on adversarial inputs.

This document extracts and expands the testing and benchmarking strategy previously embedded in `libs/markdown/SPEC.md`.

## Table of Contents Plan

1. Scope and Terminology
2. Testing Principles
3. Test Tier Model and CI Gates
4. DbI Extension Contract Tests
5. Profile Contracts and Pass Criteria
6. Corpus Acquisition Strategy
7. Ingestion and Normalization Pipeline
8. Provenance, Licensing, and Reproducibility
9. Output Comparison and Oracle Policy
10. Profile-Specific Compatibility Packs
11. Differential Testing Program
12. Adversarial and Fuzz Testing
13. Safety and Security Validation
14. Benchmark Program and Fairness Rules
15. CI Execution Plan
16. Repository Layout and Tooling Plan
17. Milestones and Readiness Criteria
18. Open Questions and Decision Log Hooks

## Scope and Terminology

### Scope

1. Covers parser-level and markdown-stage transform behavior for all supported profiles.
2. Covers deterministic fixture ingestion, conformance execution, differential testing, fuzzing, and benchmarking.
3. Does not define framework-runtime behavior outside markdown-stage semantics (for example: full Vite build graph behavior, Vue runtime rendering, Next.js routing runtime).

### Terminology

1. **Profile**: a named feature contract (`commonmark_strict`, `gfm`, `vitepress_compatible`, `nextra_compatible`, `custom`).
2. **Tier**: a test classification with explicit gate severity.
3. **Fixture**: an individual input/output expectation with provenance metadata.
4. **Oracle**: the reference expectation used to decide pass/fail.
5. **Divergence cluster**: grouped differential mismatches across multiple parsers for the same semantic area.

## Testing Principles

The test architecture follows Sparkles guidance (local reasoning, explicit contracts, functional/declarative style, DbI shell-with-hooks design):

1. **Local Reasoning**: every failing fixture must map to one profile, one feature area, and one deterministic expectation.
2. **Explicit Contracts**: each profile has an explicit pass contract; no implicit extension bleed-through.
3. **Functional Pipeline**: fixture ingestion, normalization, canonicalization, execution, and reporting are deterministic stages.
4. **DbI Compatibility**: extension hooks are optional; absence must preserve baseline correctness.
5. **Separation of Concerns**: parse semantics and renderer/transform semantics are validated separately when possible.
6. **Reproducibility First**: source version pins, deterministic regeneration, stable canonicalization.

## Test Tier Model and CI Gates

### Tier Definitions

1. **Tier A (Normative Conformance, Hard Gate)**: official spec suites and strict profile must-pass tests.
2. **Tier B (Compatibility Packs, Hard Gate in Matching Profile)**: ecosystem expectation packs for VitePress/Nextra/GFM semantics.
3. **Tier C (Differential, Soft Gate by Default)**: cross-parser comparison and divergence analysis.
4. **Tier D (Adversarial/Fuzz/Pathological, Hard Gate for Safety)**: crash, timeout, unbounded memory, and complexity checks.

### Gate Policy

1. Pull requests must pass Tier A + applicable Tier B + Tier D.
2. Tier C is informational by default, but specific known-critical divergence checks may be promoted to hard gates.
3. Benchmarks are non-blocking for most PRs, but blocking for performance-sensitive areas and release branches.

### Failure Semantics

1. A fixture mismatch is a hard fail if it belongs to an enabled hard-gate tier.
2. A timeout, OOM, or crash in Tier D is always hard fail.
3. Differential mismatches are hard fail only if explicitly listed in a tracked allowlist policy.

## DbI Extension Contract Tests

The parser uses a shell-with-hooks model; tests must validate optionality and precedence explicitly.

### Hook Optionality Baseline

1. `Hook = void` baseline tests are mandatory for every extension-capable subsystem.
2. Absence of any optional hook primitive must preserve baseline correctness.
3. Optional primitive tests must prove no semantic drift in fallback mode.

### Capability Detection Integrity

1. Capability traits must be tested against exact call expressions, not member-name existence only.
2. Trait truth tables must include positive, negative, and signature-mismatch fixtures.
3. Traits must be centralized and reused; tests should fail on ad-hoc capability probes.

### Dispatch Precedence Guarantees

1. Full override hook behavior must take precedence over event-specific hooks.
2. Event-specific hooks must run before fallback behavior where defined.
3. Fallback behavior must remain the semantic reference implementation.

### Attribute and Safety Propagation

1. Hook-enabled and hook-disabled paths must preserve expected safety attributes.
2. `@safe`/`nothrow`/`@nogc` expectations for critical hot paths must be validated where applicable.
3. Stateful and stateless hook variants must both be covered for storage/behavior correctness.

## Profile Contracts and Pass Criteria

### `commonmark_strict`

1. 100% pass on CommonMark 0.31.2 official examples.
2. No extension syntax accepted unless explicitly configured through `custom`.
3. Linear-time behavior on published pathological families.

### `gfm`

1. Conforms to selected GFM-compatible behaviors (tables, task lists, autolinks, strikethrough).
2. Must not regress strict CommonMark semantics where GFM does not change behavior.

### `vitepress_compatible`

1. Passes all VitePress markdown-stage compatibility packs.
2. Preserves explicit boundary between parser stage and full framework runtime semantics.
3. Supports metadata-bearing code fences and include/snippet behavior behind explicit options.

### `nextra_compatible`

1. Passes Nextra markdown + MDX syntax and metadata packs.
2. Preserves JSX/ESM boundaries in AST losslessly when MDX mode is enabled.
3. Ensures markdown-only profiles remain independent from MDX semantics.

### `custom`

1. Test selection is generated from enabled feature set.
2. Any enabled feature must import all associated pack assertions.
3. Disabled features must prove non-activation using negative fixtures.

## Corpus Acquisition Strategy

### Source Selection Criteria

1. Widespread adoption and demonstrated conformance quality.
2. Transparent licensing suitable for fixture redistribution or reproducible fetch.
3. Stable test organization with version pinning.
4. Coverage breadth across syntax, edge cases, and pathological behavior.

### Upstream Sources

#### CommonMark / C / Cross-Language Core

1. `commonmark/commonmark-spec` (`spec.txt`, JSON examples when available).
2. `commonmark/cmark` (regression, pathological, security-focused fixtures).
3. `github/cmark-gfm` (GFM-specific behavior).

#### JavaScript / TypeScript

1. `commonmark/commonmark.js`: `test/spec.txt`, `test/regression.txt`, `test/smart_punct.txt`.
2. `markdown-it/markdown-it`: CommonMark fixtures + markdown-it extension fixtures.
3. `micromark/micromark`: CommonMark, IO, misc, and stress fixtures.
4. `markedjs/marked`: CommonMark and GFM JSON fixtures + REDoS regressions.
5. `remarkjs/remark` stack: AST/transform-oriented compatibility behavior.
6. `shuding/nextra`: docs and package fixtures for markdown/MDX authoring behavior.
7. `mdx-js/mdx`: parser/compiler fixtures for ESM/JSX and MDX edge cases.

#### Rust

1. `pulldown-cmark/pulldown-cmark`: specs and suite tests.
2. `kivikakk/comrak`: CommonMark + GFM derivatives with Rust-specific assertions.
3. `wooorm/markdown-rs`: extension fixtures and fuzz-leaning corpora.

#### Additional High-Criteria Sources

1. `mity/md4c` for extension/pathology behavior signals.
2. `yuin/goldmark` for robust CommonMark + extension coverage in Go.

### Update Cadence

1. Scheduled refresh at least monthly for pinned fixtures.
2. Immediate refresh for security advisories or major upstream test additions.
3. All refreshes run through deterministic regeneration and diff review.

## Ingestion and Normalization Pipeline

### Pipeline Stages

1. **Fetch**: clone/fetch pinned upstream commit SHAs.
2. **Extract**: collect fixture files using source-specific adapters.
3. **Normalize**: convert into a single JSONL schema.
4. **Annotate**: attach provenance, tags, profile hints, and gate class.
5. **Validate**: schema validation + duplicate ID checks + deterministic sort.
6. **Publish**: write generated corpus and manifest files.

### Normalized Fixture Schema (JSONL)

```json
{
  "id": "source:case",
  "sourceRepo": "owner/repo",
  "sourcePath": "path/to/file",
  "sourceCommit": "abcdef123456",
  "sourceUrl": "https://...",
  "license": "BSD-2-Clause",
  "dialect": "commonmark|gfm|vitepress|nextra|mdx",
  "profile": "commonmark_strict|gfm|vitepress_compatible|nextra_compatible|custom",
  "phase": "parse|post_parse|render|preprocess",
  "markdown": "...",
  "expectedHtml": "...",
  "expectedAst": null,
  "tags": ["emphasis", "containers", "pathological"],
  "flags": {
    "unsafe": false,
    "requiresIO": false,
    "requiresMDX": false,
    "slow": false
  }
}
```

### Determinism Requirements

1. Stable fixture ordering by `id`.
2. Stable serialization formatting.
3. Stable newline normalization and UTF-8 handling.
4. No wall-clock dependent metadata in generated fixtures.

## Provenance, Licensing, and Reproducibility

1. Every fixture set must include source repository, path, commit SHA, and license identifier.
2. Manifest files must include generation timestamp in UTC and generator version hash.
3. Regeneration script output must be byte-stable for the same inputs.
4. License policy must block ingestion from incompatible or unknown licenses.
5. Fixtures requiring local transformations must preserve source mapping annotations.

## Output Comparison and Oracle Policy

### Canonical Comparison

1. Compare canonicalized HTML, not raw serialized strings.
2. Canonicalizer must normalize attribute order, ignorable whitespace, and equivalent entity forms.
3. Canonicalizer must preserve semantically significant whitespace and code blocks.

### Oracle Precedence

1. Profile-specific expected output for a fixture.
2. Source-tagged expectation from upstream fixture.
3. Canonical fallback expectation with explicit override note.

### Ambiguity Handling

1. Ambiguous syntax is labeled with dialect tags and explicit decision notes.
2. Multiple acceptable outputs are handled via expectation sets only when the ambiguity is intentional and documented.
3. Any newly discovered ambiguity requires an issue + override rationale before merge.

## Profile-Specific Compatibility Packs

### CommonMark Strict Packs

1. Official CommonMark examples (complete).
2. Strict-mode negative fixtures for extension syntax rejection.
3. Pathological delimiter/link nesting complexity checks.

### GFM Packs

1. Tables, task lists, autolinks, strikethrough.
2. Intra-word edge cases and parser precedence interactions.
3. Compatibility checks against cmark-gfm and selected JS parsers.

### VitePress Packs

1. Heading anchors and custom IDs (`{#id}`), including collision handling.
2. TOC token behavior (`[[toc]]`) at parser and transform boundaries.
3. Containers (`info`, `tip`, `warning`, `danger`, `details`, `raw`) with title and attrs.
4. GitHub alert block syntax.
5. Fence metadata parsing (`{1,3-5}`, `:line-numbers`, marker comments).
6. Focus/diff/error markers (`[!code focus]`, `[!code --]`, etc).
7. Code groups and snippet imports (`<<<`).
8. Markdown include semantics (`<!--@include: ...-->`) with line ranges, region anchors, heading anchors.
9. Internal/external link transforms and image transform hints.
10. Math opt-in behavior (`$...$`, `$$...$$`) and disabled-by-default behavior.

### Nextra/MDX Packs

1. MDX syntax integration: imports/exports/JSX islands mixed with markdown.
2. Custom heading IDs (`[#id]`) and collision policy.
3. GitHub alert mapping to callout semantics.
4. Shiki-style fence metadata:
   1. Line highlight ranges (`{1,4-5}`).
   2. Substring highlight (`/useState/`).
   3. Copy metadata (`copy`, `copy=false`).
   4. Line numbers (`showLineNumbers`).
   5. Filename/title (`filename="example.js"`).
5. Inline code language hints (`{:lang}`).
6. Mermaid and `math` fences.
7. Internal link and static markdown image transforms.
8. Inline/display LaTeX behavior when opt-in enabled and disabled.

### Cross-Profile Conflict Packs

1. Documents enabling both VitePress and Nextra heading ID syntaxes.
2. Precedence expectations for ambiguous heading annotations.
3. Negative tests ensuring one profile's extensions do not leak into another profile.

## Differential Testing Program

### Parser Matrix

1. Sparkles parser.
2. cmark / cmark-gfm.
3. commonmark.js.
4. markdown-it.
5. micromark.
6. marked.
7. pulldown-cmark.
8. comrak.
9. markdown-rs.

### Differential Modes

1. **Spec mode**: strict CommonMark corpus comparison.
2. **Extension mode**: subset corpora where multiple parsers support relevant features.
3. **Stress mode**: adversarial families to compare complexity and failure modes.

### Divergence Reporting

1. Group mismatches by syntax category (`emphasis`, `html_block`, `containers`, `mdx_boundary`, etc).
2. Emit per-case canonical outputs and parser-by-parser diffs.
3. Track top divergence clusters over time as trend metrics.
4. Promote stable, justified divergences to documented override rules.

## Adversarial and Fuzz Testing

### Adversarial Families

1. Deep nesting (lists, blockquotes, delimiters).
2. Emphasis/link delimiter ambiguity explosions.
3. HTML block boundary edge cases.
4. Container termination ambiguity.
5. Include/snippet recursion and large-file stress.

### Fuzzing Modes

1. Grammar-guided generation for valid and near-valid markdown.
2. Mutation fuzzing seeded from real fixtures and previous crashes.
3. Structure-aware mutation for MDX tokens and JSX boundary conditions.

### Triage Pipeline

1. Crash capture with minimized reproducer generation.
2. Automatic bucketing by stack signature and feature tags.
3. Regression fixture promotion after fix.
4. Time and memory budget enforcement in CI.

### Mandatory Safety Checks

1. No unhandled crashes.
2. No unbounded-time cases for known pathological classes.
3. No memory blowups above configured caps.

## Safety and Security Validation

### URL and Raw HTML Policies

1. Safe-mode defaults for dangerous schemes and raw HTML passthrough.
2. Explicit opt-in fixtures for unsafe mode behavior.
3. Round-trip checks ensuring safe mode does not accidentally relax via extensions.

### Include/Snippet IO Safety

1. Sandbox path policy enforcement.
2. Include depth and file-size limit enforcement.
3. Symlink/path traversal denial fixtures.
4. Deterministic errors with source positions.

### Limit Enforcement

1. Maximum nesting depth.
2. Maximum include depth.
3. Maximum input size.
4. Maximum token/event count for parser safety mode.

## Benchmark Program and Fairness Rules

### Benchmark Questions

1. Is parse throughput competitive with top implementations?
2. Is parse+render throughput competitive?
3. Are latency and memory costs stable at scale?
4. Are pathological workloads bounded linearly?

### Competitor Matrix

#### JavaScript/TypeScript

1. commonmark.js
2. markdown-it (default and CommonMark modes)
3. micromark
4. marked

#### Rust

1. pulldown-cmark
2. comrak
3. markdown-rs

#### C / Go

1. cmark
2. cmark-gfm
3. md4c
4. goldmark

### Workloads

1. Tiny (comments/short docs).
2. Medium (README/docs pages).
3. Large (books and concatenated corpora).
4. Extension-heavy (GFM/VitePress/Nextra feature stress).
5. Pathological (known stressor families).

### Metrics

1. Throughput (MB/s), parse-only.
2. Throughput (MB/s), parse+HTML render.
3. Latency p50/p95/p99.
4. Peak RSS.
5. Allocations (count/bytes), when available.
6. Startup overhead for CLI competitors.

### Fairness Rules

1. Pin versions and use release builds.
2. Run in isolated, CPU-pinned environments.
3. Warm-up plus repeated runs with summary statistics.
4. Compare equivalent feature sets only.
5. Publish full commands and raw outputs.

### Benchmark-to-Test Coupling

1. Use benchmark corpora as non-functional regression fixtures.
2. Trigger benchmark smoke tests for parser hot-path changes.
3. Record trend lines and alert on statistically significant regressions.

## CI Execution Plan

### Pipeline Phases

1. `validate-fixtures`: schema, provenance, determinism checks.
2. `tier-a`: strict conformance.
3. `tier-b`: profile compatibility packs.
4. `tier-d`: adversarial + fuzz regression corpus.
5. `tier-c`: differential reporting.
6. `bench-smoke`: quick benchmark sanity checks.
7. `bench-full` (scheduled/manual): full competitor benchmark matrix.

### Suggested Gate Matrix

| Job         | Pull Request                  | Main Branch | Release Branch       |
| ----------- | ----------------------------- | ----------- | -------------------- |
| Tier A      | required                      | required    | required             |
| Tier B      | required (affected profiles)  | required    | required             |
| Tier C      | report-only                   | report-only | selective required   |
| Tier D      | required                      | required    | required             |
| Bench Smoke | required for hot-path changes | required    | required             |
| Bench Full  | optional/manual               | scheduled   | required pre-release |

### Reporting Requirements

1. Emit machine-readable JSON summary and human-readable markdown report.
2. Include profile-level pass rates and top failing categories.
3. Publish fixture IDs for all failures and divergence clusters.

## Repository Layout and Tooling Plan

```text
libs/markdown/
  SPEC.md
  TESTING.md
  tests/
    corpus/
      tier_a/
      tier_b/
      tier_c/
      tier_d/
      generated/
        fixtures.jsonl
        manifest.json
    adapters/
      ingest_commonmark_spec.d
      ingest_cmark.d
      ingest_micromark.d
      ingest_nextra.d
      ingest_mdx_js.d
    runners/
      run_tier_a.d
      run_tier_b.d
      run_tier_c_diff.d
      run_tier_d_fuzz_regression.d
    canonicalize/
      html_canonicalizer.d
  bench/
    adapters/
      cmark.sh
      cmark_gfm.sh
      commonmark_js.mjs
      markdown_it.mjs
      micromark.mjs
      marked.mjs
      pulldown_cmark.rs
      comrak.rs
      markdown_rs.rs
      md4c.sh
      goldmark.go
    corpora/
    run_bench.d
    results/
```

### Tooling Requirements

1. Deterministic fixture ingestion command (single entry point).
2. Per-tier test runner commands with profile filters.
3. Differential report generator with stable output format.
4. Benchmark runner with reproducible environment capture.

## Milestones and Readiness Criteria

1. **M1**: Tier A pipeline + CommonMark strict gate operational.
2. **M2**: Tier B VitePress and Nextra packs established with profile isolation.
3. **M3**: Tier C differential dashboard and divergence triage workflow.
4. **M4**: Tier D fuzz/adversarial CI and crash minimization pipeline.
5. **M5**: Benchmark harness integrated with smoke + scheduled full runs.

### Release Readiness

1. 100% pass in Tier A for `commonmark_strict`.
2. 100% pass for selected Tier B packs in `vitepress_compatible` and `nextra_compatible`.
3. No unresolved Tier D crash/timeout/memory failures.
4. Benchmarks in expected performance band with no unexplained regressions.

## Open Questions and Decision Log Hooks

1. Should VitePress compatibility include Vue component interpolation semantics or markdown-stage behavior only?
2. Should math rendering ownership remain token-only or include renderer coupling?
3. What is the default profile for consumers of `libs/markdown`?
4. Which minimum Node/Rust/Go toolchain versions are pinned for benchmark CI?
5. When both VitePress `{#id}` and Nextra `[#id]` heading ID syntaxes are active, which precedence rule applies?

Each answer should be captured in an ADR with:

1. Decision statement.
2. Affected profile(s).
3. Fixture impacts.
4. Compatibility and migration notes.
