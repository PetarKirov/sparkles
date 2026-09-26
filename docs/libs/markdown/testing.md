# Markdown Testing Helpers

The `sparkles.markdown.testing` module contains fixture-driven helpers for conformance and compatibility testing.

## What The Module Provides

### Fixture Schema

`FixtureCase` is the normalized JSONL schema used by the test corpus:

- `id`
- `sourceUrl`
- `license`
- `dialect`
- `profile`
- `phase`
- `markdown`
- `expectedHtml`
- `expectedAst`
- `tags`
- `flags`

`FixtureFlags` adds execution metadata:

- `unsafe_`
- `requiresIO`
- `requiresMDX`
- `slow`

### Runner API

`FixtureRunOptions` controls suite execution:

- input fixture paths
- optional profile filter
- slow and MDX inclusion
- unsafe HTML allowance
- fail-fast behavior
- per-fixture timeout
- optional JSON summary output path

`runFixtureSuite` loads JSONL fixtures, parses markdown with the requested profile, renders HTML, canonicalizes results, and returns a `SuiteSummary`.

### Reporting Helpers

- `canonicalizeHtml` removes newline-formatting noise for robust comparisons
- `summaryToMarkdown` renders a human-readable markdown report
- `isSuitePassing` checks for zero failures
- `writeSuiteSummaryJson` emits machine-readable JSON output

## Typical Flow

1. Load fixtures from one or more JSONL files.
2. Run `runFixtureSuite`.
3. Inspect the returned `SuiteSummary`.
4. Render summary markdown or write JSON for CI/reporting.

## Relationship To The Spec

This module implements the workflow described in [the Markdown testing spec](../../specs/markdown/TESTING). It is the operational side of that design:

- the spec defines corpus policy and validation tiers
- `sparkles.markdown.testing` provides the reusable code needed to execute those suites

## When To Use It

Use this module when you need:

- deterministic fixture loading and writing
- stable HTML comparison across formatting differences
- a shared representation for parser conformance results
- a reusable runner for compatibility packs and differential tests
