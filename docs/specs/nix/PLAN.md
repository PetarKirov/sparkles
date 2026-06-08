# `sparkles:nix` — Delivery Plan

_Audience: contributors implementing the library. This document is
execution-only — milestones, verification, and risks. For the desired-state
specification read [SPEC.md](./SPEC.md); for the binding workflow read
[Integrating C Libraries](../../guidelines/importc-c-libraries.md)._

The library is an ImportC raw layer (`sparkles.nix.c`) plus a hand-written
high-level wrapper (RAII handles + `Expected`-based errors), built bottom-up
in the C-library dependency order (util → store → expr → flake). Each
milestone ends green: it compiles, `dub test :nix` passes, and the consumer
(`dub build :nix-eval`) builds.

## 1. Milestone overview

| #      | Deliverable                                                                                      | Depends on  |
| ------ | ------------------------------------------------------------------------------------------------ | ----------- |
| **M0** | Nix flake input + devshell wiring + `libs/nix` skeleton + ImportC shim that compiles & links     | —           |
| **M1** | Error/context/string foundation: `NixError`, `NixResult`, `NixContext`, `checkCall`, string sink | M0          |
| **M2** | Lifecycle + store + evaluation + value extraction/creation + `NixSession` (the core)             | M1          |
| **M3** | Flake support (`FlakeSettings`/`FetchersSettings`/`FlakeReference`/lock/outputs)                 | M2          |
| **M4** | `apps/nix-eval` example + README runnable example + docs                                         | M2 (M3 opt) |

M0 de-risks the whole effort (does ImportC parse the headers? does
pkg-config feed the include path?). M2 is the bulk. M3 layers on M2. M4 is
the user-facing demo.

## 2. Per-milestone detail

### M0 — Build plumbing (the de-risking milestone)

Ship in this order, each step verified before the next:

1. **Flake input.** Add to `flake.nix` `inputs`:
   ```nix
   nix = {
     url = "github:NixOS/nix";
     inputs.nixpkgs.follows = "nixpkgs";
   };
   ```
   `nix flake lock` to pin it.
2. **Devshell.** Add to `nix/shells/default.nix` `packages` the `out` + `.dev`
   of all six C libs (`inputs'.nix.packages.nix-{util,store,expr,fetchers,flake,main}-c`
   and each `.dev`). `pkg-config` is already present. Confirm in the shell:
   `pkg-config --cflags --libs nix-expr-c` prints include + link flags.
3. **`libs/nix` skeleton.** Create `libs/nix/src/sparkles/nix/c.c` (the
   `#pragma`-wrapped includes from SPEC §2) and `dub.sdl`
   (`targetType "sourceLibrary"`, `libs "nix-util-c" … "nix-main-c"`,
   `dflags "-preview=in" "-preview=dip1000"`). Add `package.d` =
   `public import sparkles.nix.c;` for now. Register `subPackage "libs/nix"`
   in the root `dub.sdl` (sorted). **`git add`** all new files.
4. **Prove it.** A trivial `@system unittest` that calls
   `nix_version_get()` and asserts the returned C string is non-empty.
   `dub test :nix` must pass.
5. **Verify pkg-config does the work**: rebuild with
   `env -u NIX_CFLAGS_COMPILE -u CPATH -u C_INCLUDE_PATH dub test :nix --force`
   — still finds `<nix_api_*.h>` ⇒ pkg-config (`sourceLibrary`) is correct.

> **Risk — `[[deprecated]]` in `nix_api_value.h`.** The raw C23 attribute
> may trip ImportC. If `dub test :nix` fails parsing it: (a) try LDC vs the
> gcc14 `dmd`; (b) if still failing, strip the attribute by post-patching
> the header in a tiny Nix derivation that wraps `nix-expr-c.dev`, or
> `sed`-patch into a local include dir put first on the ImportC path. Record
> the resolution in [[nix-c-api-binding-facts]].

> **Risk — GCC 15 `stddef.h`/`nullptr`.** Known ImportC issue (the toolchain
> overrides `dmd`→gcc14; LDC is unaffected). If it bites, build with LDC.

### M1 — Error / context / string foundation

`sparkles.nix.error` then `sparkles.nix.strings` (SPEC §4–§5):

1. `NixErrCode` enum (mirror of `nix_err`), `NixError` struct (code + GC
   message + `toString`), `NixResult!T` alias, `nixOk`/`nixErr` helpers.
2. `NixContext` move-only RAII (create/free/`ptr`/`check`). `check` reads
   `nix_err_code`; on non-OK copies `nix_err_msg` into a GC string and
   clears. Unit-test the error path by triggering a `NIX_ERR_KEY` (e.g.
   `nix_setting_get` on a bogus key).
3. `checkCall!fn` template (splice ctx ptr → call → check; `void` for
   `nix_err`-returning, `R` for value-returning) and `checkCallOptKey!fn`
   (`NIX_ERR_KEY` → `Nullable.null`). Confine pointer/FFI work to `@trusted`
   blocks.
4. `stringSinkCallback(W)` `extern(C)` trampoline + `collectStringInto`/
   `collectString`. Test by round-tripping `nix_version`-style strings and a
   setting value.

### M2 — Core: lifecycle, store, eval, values, session

Build the evaluator surface (SPEC §6–§9, §11):

1. **`sparkles.nix.library`** — `initNix` (once-guarded, value-type cached
   error), `nixVersion`, `getSetting`/`setSetting` (mutex-guarded),
   `GcThreadGuard` no-op stub + the threading-model doc comment.
2. **`sparkles.nix.value`** — `ValueType` enum + `Value` handle
   (incref postblit / decref dtor, `adopt`/`retain` package factories,
   `type`/`isNull`). No state-dependent ops here.
3. **`sparkles.nix.store`** — `Store` (refcounted; `open` with dummy://
   default, `uri`/`storeDir`/`version_`, `parsePath`, `isValidPath`),
   `StorePath` (name/dup/free). Realise/derivations behind a version guard.
4. **`sparkles.nix.eval`** — `EvalStateBuilder` + `EvalState`
   (`create`/`build`, `eval`), then the value operations as `EvalState`
   methods: `force`/`forceDeep`/`valueType`; `requireInt/Float/Bool/String
/Path` (+ `requireStringInto`); `listSize`/`requireList`/`listAt`;
   `attrCount`/`requireAttr`/`requireAttrOpt`/`attrNames`;
   `mkInt/Float/Bool/Null/String/Path/List/Attrs`; `call/callMulti/applyLazy`;
   `realiseString`.
5. **`NixSession`** facade in `package.d` (init + store + eval bundled) +
   re-exports of the public surface.

Tests (all on one thread, dummy store): scalars (`1+2`, `3.14`, `true`,
`"hi"`), a list (`[1 2 3]` → `requireList` → `requireInt` each), an attrset
(`{x=1; y="hi";}` → `attrNames`/`requireAttr`/`requireAttrOpt` incl. a
missing key → null), type-mismatch → `NixError`, a thrown eval
(`builtins.throw "boom"`) → `NixError` with the message, round-trip
construction (`mkAttrs`/`mkList` → extract). Prefer the project's check
helpers where they fit; otherwise assert on `NixResult` directly.

### M3 — Flakes

`sparkles.nix.flake` (SPEC §10): the six handles + `EvalStateBuilder.flakes`
wiring. Integration test mirroring the Rust `flake_lock_load_flake`: write a
tiny `flake.nix` to a temp dir (use `sparkles:test-utils` tmpfs helpers),
`setSetting("experimental-features","flakes")`, build a flakes-enabled eval
state, parse `path:<dir>#frag`, lock (virtual mode), get `outputs`, select +
`requireString` an output, assert. Guard on Nix ≥ 2.26.

### M4 — Example app + docs

1. `apps/nix-eval` (`targetType "executable"`, deps `sparkles:nix` +
   `sparkles:core-cli`): parse args, open a `NixSession`, evaluate, and
   recursively render the `Value` by `ValueType`. Optional `--flake` path.
   Register `subPackage "apps/nix-eval"` in the root `dub.sdl` (sorted).
2. A runnable `README.md` example per the
   [`[Output]` convention](../../guidelines/AGENTS.md#runnable-readme-examples)
   (uses `version="*"`), verified with `nix run .#ci -- --verify`.
3. Per-library docs stub under `docs/libs/nix/` (Diátaxis) is encouraged but
   may follow.

## 3. Verification checklist

- [ ] `dub test :nix` green; the unset-`NIX_CFLAGS_COMPILE` rebuild still
      finds the headers (pkg-config proven).
- [ ] `dub build :nix-eval` builds; the demo evaluates int/list/attrs.
- [ ] `nix run .#ci -- --test --fail-fast` passes for the new package.
- [ ] README example verifies (`nix run .#ci -- --verify --files README.md`).
- [ ] New files `git add`-ed before any `nix develop`/flake build.
- [ ] Atomic commits per AGENTS.md (`build(nix)` flake wiring first, then
      `feat(nix)` per layer, then `feat(terminal)`-style `feat(nix-eval)`).

## 4. Workflow orchestration

M0 and M1 are mostly sequential and small — do them inline. M2's value
operations (the many `require*`/`mk*`) are independent once the `Value`
handle and `checkCall` exist and can be fanned out across agents (one per
operation group) with a final integration-test pass; M3 likewise (one agent
per flake handle). Use a workflow for those fan-outs when implementing,
reviewing each layer's tests before moving up the stack.

## 5. Risks & open decisions

- **`[[deprecated]]` / ImportC C23 attributes** — see M0 risk. Resolved
  empirically in M0; this gates everything.
- **`github:NixOS/nix` version drift** — the flake input may resolve to a
  Nix whose C API differs slightly from the 2.35-dev headers read during
  design. Pin via `flake.lock`; gate newer calls with `version (Nix_2_x)`.
- **Single-thread constraint** — accepted for v1 (SPEC §6.3). A real
  `GcThreadGuard` (binding `<gc/gc.h>`, pkg-config `bdw-gc`, `-lgc`) is the
  first post-v1 extension if multi-threaded eval is needed.
- **`@nogc` lean vs. reality** — the wrapper layer is GC-using by design
  (SPEC §12); `@nogc` sink overloads are provided where they matter.
