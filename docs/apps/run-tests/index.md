# run-tests

`scripts/run-tests.sh` is the repository-wide test runner for Sparkles subpackages.

## What It Does

- Reads subpackages from the root `dub.sdl`
- Creates each package `build/` directory if needed
- Runs `dub test` for every subpackage

## Usage

```bash
./scripts/run-tests.sh
```

Run it inside the dev shell when you need the project toolchain:

```bash
nix develop -c ./scripts/run-tests.sh
```
