# `sparkles:wired` WebAssembly builds — Delivery plan

_Companion to [SPEC.md](./SPEC.md). Each W-milestone is independently green:
it builds, its packages' tests pass, and no later milestone is needed to make
an earlier commit valid. The Nix slices come first because they retire an
exception the repository already carries; the site and npm slices stay coarse
until their decisions are made._

## W0 — Feasibility prototype

Done on `feat/wired-wasm-nix` (`07558a94d`, `92a4cfa0e`); its measurements
are [SPEC §8](./SPEC.md#_8-prototype-evidence). It answered the blocking
questions: whether a D program with its runtime runs under `builtins.wasm`
(yes), whether its answers agree with the regular-expression readers (on
every repository recipe), and what it costs (0.294 ms a call; slower than a
regular expression, faster than today's readers once each recipe is parsed
once). The prototype is not the production module: W1 replaces it.

## W1 — The recipe schema, buildable

Obligations: WW1, D3. Move the recipe schema, unchanged, into
`sparkles:dub-manifest`, which depends on `sparkles:wired` and
`sparkles:base` alone; `build-primitives` depends on it. The module keeps
its name (D3).

Gate: `dub test` of the new package and of `build-primitives` pass; the
new package builds for `wasm32-unknown-wasip1` with the flake's WASI LDC;
`ci --build-each-commit` builds both; the spec-evidence check resolves.

## W2 — The Nix module

Done: `libs/dub-manifest/dub-manifest-nix-wasm` (`dub-manifest-nix-wasm`), its oracle and
`agreement.nix`; evidence in [SPEC §8](./SPEC.md#delivered-evidence).

Obligations: WW2–WW6, WW15 for the module package. The entry layer of the
prototype, completed: the `{ text; name; }` argument, `dub.json` by name,
WW5's error values, and a native unit test of the value conversion against
a recording fake of the host functions (the conversion is ordinary D; only
the imports are wasm).

Gate: a Nix check, on an evaluator with the builtin, decodes a fixture
corpus (every repository recipe, a JSON recipe, and recipes that fail to
lex, to parse, and to validate) and compares each answer with the native
decode's, printed by a native helper as the same attribute set; every
rejection returns `error` with the native reader's position and message,
and none aborts evaluation.

## W3 — The recipe table and the fallback

Done: `nix/lib/recipe-facts.nix`, `manifest-graph.nix` reading through it,
`facts-agreement.nix`, `ci --check-nix-wasm` and the `nix-wasm` CI job;
evidence in [SPEC §8](./SPEC.md#delivered-evidence).

Obligations: WW7, WW9, WW10, WW11. `manifest-graph.nix` reads through the
table; the regular-expression reader becomes the table's fallback
producer, stripping comments and reading every configuration; the
agreement check runs over every recipe, with WW10's seeded fixtures: a
dependency quoted in a comment, and a top-level dependency after a
configuration.

Gate: the flake's outputs evaluate to the same derivations before and after
(the table changes how recipes are read, not what is built); WW11's
measurement recorded for both paths; the agreement check passes and is
seen to fail on its seeded divergences.

Prerequisite for turning the Nix path on in the flake: W4's pin. Before
it, W3 lands with the module supplied explicitly (WW8), which CI exercises
in the agreement check only.

## W4 — The pinned module

Done, the pin last: `nix/nix-wasm-pin.json`, the fetch in
`manifest-graph.nix`, `apps/ci/tools/pin-nix-wasm.d` (builds a revision's module,
commits it to the orphan branch `nix-wasm-modules` and writes the pin), and
`ci --check-nix-wasm` rebuilding the pinned revision and running both
agreement checks with the pinned module.

Obligations: WW8, D2. A pin file names a revision and the module's hash;
the module built at that revision is published and fetched by hash during
evaluation; a check rebuilds the pinned revision and requires a
byte-identical module; WW10's check runs with the pinned module too, so a
schema change that the pin would reject cannot merge without moving it.
Then switch the flake's default to the Nix path where `builtins ? wasm`
holds.

Gate: an evaluation with the builtin fetches the pinned module and builds
nothing before it finishes; the rebuild check passes; a recipe using a
directive the pinned module rejects fails the agreement check. Then record,
in [editing §7](../sdl/editing.md#7-migration-coverage), that the
exception's readers are now the fallback of WW7.

## W5 — Portability

Done: `sparkles.wired.wasm_portability` (4 `@wasm` tests) and
`sparkles.build_primitives.dub_manifest_wasm` (3), run by `ci
--test-extracted`; the Nix module joins `ci --build-each-commit`'s
WebAssembly packages. The first run found a 64-bit-only index in the SDL
lexer's month table, fixed before them.

Obligations: WW15. `@wasm` tests over each format's reader, writer, typed
codec and errors, and the recipe schema's forms and rejections; run them
under `ci --test-extracted`.

## W6 — Playground

Done: `libs/wired/wired-wasm` (`spk-wired.wasm`, 1552 KB after `wasm-opt -Oz`),
`WiredPlayground.vue` on `docs/libs/wired/how-to/try-in-the-browser.md`,
the module in `docs-wasm` and `--stage-docs-wasm`, and 11 requests in
`ci --check-wasm-modules`'s corpus (TCM9), all agreeing with `wiredRun`
run natively.

Obligations: WW12. A reactor on the module contract's interface with one
request export; a site component; the TCM5 table, TCM8 size record and
TCM9 corpus extended.

## W7 — npm package

Obligations: WW12; WW13, WW14, D6. Planned when W4 has landed; each first
refines its section of the specification, then follows the module
contract's gates (TCM8 size record, TCM9 agreement).
