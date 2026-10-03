# Markdown Test Harness

This directory implements the test strategy from `libs/markdown/TESTING.md`.

## Commands

1. Ingest fixtures into deterministic generated corpus: `ldc2 -i -Ilibs/markdown/src -run libs/markdown/tests/adapters/ingest_all.d`
2. Run Tier A gate: `ldc2 -i -Ilibs/markdown/src -run libs/markdown/tests/runners/run_tier_a.d`
3. Run Tier B gate: `ldc2 -i -Ilibs/markdown/src -run libs/markdown/tests/runners/run_tier_b.d`
4. Run Tier C differential report: `ldc2 -i -Ilibs/markdown/src -run libs/markdown/tests/runners/run_tier_c_diff.d`
5. Run Tier D adversarial/pathological gate: `ldc2 -i -Ilibs/markdown/src -run libs/markdown/tests/runners/run_tier_d_fuzz_regression.d`

## Nix-Flake Source Pinning

`tests/corpus/flake.nix` defines upstream fixture sources. Exact pinned revisions should be materialized in `tests/corpus/flake.lock`.

Fixture JSONL files intentionally keep lightweight provenance (`sourceUrl`, `license`) while source pinning details live in `tests/corpus/sources.json` and flake lock metadata.
