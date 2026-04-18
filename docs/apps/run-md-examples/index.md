# run-md-examples

`scripts/run_md_examples.d` extracts runnable `dub` single-file examples from Markdown files.

## What It Does

- Runs embedded examples and prints their output
- Verifies output blocks against actual program output
- Updates output blocks with fresh snapshots
- Detects and normalizes duplicate Markdown reference links

## Usage

```bash
./scripts/run_md_examples.d README.md
./scripts/run_md_examples.d --verify README.md
./scripts/run_md_examples.d --update README.md
./scripts/run_md_examples.d --dedup-reference-links README.md
./scripts/run_md_examples.d --fix-reference-links README.md
```

## Related Docs

- [core-cli](../../libs/core-cli/)
