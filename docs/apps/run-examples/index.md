# run-examples

`scripts/run-examples.sh` runs the single-file examples in `libs/core-cli/examples/`.

## What It Does

- Iterates over each `core-cli` example
- Runs each example via `dub run --single`
- Builds `term_size.d` without running it because it expects interactive input

## Usage

```bash
./scripts/run-examples.sh
```

Run it inside the dev shell when you need the project toolchain:

```bash
nix develop -c ./scripts/run-examples.sh
```
