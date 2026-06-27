# D Developer Guidelines: Integrating Third-Party C Libraries (ImportC)

## Overview

This project binds C libraries with **ImportC** — the C compiler built into DMD
and LDC — instead of hand-written or generated bindings. The reference example
is `sparkles:ghostty`, which binds `libghostty-vt`.

Why ImportC:

- The D compiler parses the **real C header**, so struct layout, enum values,
  and function signatures can never drift from the upstream library. There is no
  `dstep`/`ctod` regeneration step to keep in sync.
- The exact header version is pinned by `flake.lock`, so ABI fidelity is
  guaranteed by construction.

Making a C library usable from D in this repo has four moving parts. Get all
four right and there is **no hardcoded include path anywhere** — dub discovers it
from `pkg-config`:

| Part                 | What it does                                                  | Where                                 |
| -------------------- | ------------------------------------------------------------- | ------------------------------------- |
| ImportC shim (`c.c`) | `#include`s the header; becomes a D module                    | `libs/<name>/src/sparkles/<name>/c.c` |
| `dub.sdl`            | compiles the `.c`, resolves flags via pkg-config              | `libs/<name>/dub.sdl`                 |
| pkg-config           | supplies `--libs` (link) **and** `--cflags` (ImportC include) | upstream `.pc` file                   |
| Nix devshell         | puts the library, headers, `.pc`, and `pkg-config` on `PATH`  | `nix/shells/default.nix`, `flake.nix` |

---

## The canonical example: `libs/ghostty`

### 1. The ImportC shim

`libs/ghostty/src/sparkles/ghostty/c.c`:

```c
// Mark every declaration `nothrow @nogc` on the D side; `pure` is omitted
// because these calls mutate terminal state. See dlang.org/spec/importc#pragma.
#pragma attribute(push, nogc, nothrow)
#include <ghostty/vt.h>
#pragma attribute(pop)
```

- **The file name becomes the D module.** `c.c` → `sparkles.ghostty.c`. Consumers
  write `import sparkles.ghostty.c;` and every declaration in the header is a
  callable D symbol (all `extern(C)` automatically).
- ImportC compiles this `.c` directly — a `.c`/`.i` file in the source tree is
  picked up and compiled with no extra directive.
- `#pragma attribute(push, …)` ([spec](https://dlang.org/spec/importc#pragma))
  stamps attributes onto **every** C declaration so callers can stay in
  `@nogc nothrow` code. Supported storage classes: `nogc`, `nothrow`, `pure`
  (unrecognized ones are ignored). Omit `pure` for any library that holds state.
  **Do not cast C function pointers to fake attributes** — use the pragma; it is
  the only honest way to give the bindings `@nogc`/`nothrow`.
- Keep the shim to just the wrapped `#include`(s). Put any D-side conveniences
  (RAII wrappers, helpers) in separate `.d` modules.

### 2. The `dub.sdl`

`libs/ghostty/dub.sdl` (trimmed):

```sdl
name "ghostty"
dflags "-preview=in" "-preview=dip1000"

libs "ghostty-vt"

configuration "library" {
    targetType "sourceLibrary"
}
```

Three things matter:

- **`libs "ghostty-vt"`** — the link-library name. dub resolves it through
  pkg-config (next section), which supplies _both_ the link flags and the ImportC
  include path.
- **`targetType "sourceLibrary"`** — required for the pkg-config include to reach
  ImportC. See [the gotcha](#the-sourcelibrary-gotcha-read-this).
- The `.c` shim is auto-discovered; no `cSourcePaths` needed when it sits next to
  the `.d` sources.

### 3. How dub feeds pkg-config into ImportC

dub compiles `.c`/`.i` files with the D compiler (ImportC) automatically. For
libraries resolved via pkg-config (dub#3085), `resolveLibs()` does this for each
`libs` entry:

1. `pkg-config --exists <name>`, then `pkg-config --exists lib<name>` — so
   `ghostty-vt` matches the `libghostty-vt.pc` package.
2. `pkg-config --libs <pkg>` → linker flags (`-L…`, `-l…`).
3. `pkg-config --cflags <pkg>` → C preprocessor flags, **each prefixed with
   `-P`** so `-I/…/include` becomes `-P-I/…/include` — exactly what ImportC's
   preprocessor needs to resolve `<ghostty/vt.h>`.

The result: one `libs "ghostty-vt"` line configures linking _and_ the ImportC
include path automatically, with no hardcoded `-I`.

Related explicit directives (dub#2544, #2818), for libraries that ship **no**
`.pc` file:

- `cImportPaths "<dir>"` — C header search directories.
- `cSourcePaths "<dir>"` — directories of `.c` sources to compile.

Prefer pkg-config; reach for `cImportPaths` only when there is no `.pc`
([see below](#when-there-is-no-pkg-config-pc-file)).

### The `sourceLibrary` gotcha (read this)

> dub's `resolveLibs()` (`source/dub/compilers/utils.d`) **clears `libs` and
> skips pkg-config for `library` and `staticLibrary` targets** — it defers
> library flags to the final executable link.

Consequence: the pkg-config `--cflags` (i.e. the ImportC include path) are
applied **only where the package is compiled into an executable or test target**.

- If the binding is `targetType "library"`, its `.c` is compiled during the
  _library_ build → no pkg-config runs → ImportC cannot find the header, unless
  some ambient env (e.g. nix's `NIX_CFLAGS_COMPILE`) happens to supply it. That
  is fragile and non-portable.
- Making the binding **`targetType "sourceLibrary"`** means its sources are
  compiled _inside each dependent's_ (executable/test) build, where
  `resolveLibs()` runs pkg-config and the `-P-I` flags reach ImportC. This is why
  `sparkles:ghostty` is a `sourceLibrary`.
- The `unittest` configuration builds a test-runner executable, so
  `dub test :ghostty` also gets pkg-config and works.

### 4. Environment (Nix)

The library, its headers, and its `.pc` must be discoverable: `pkg-config` on
`PATH` and `PKG_CONFIG_PATH` pointing at the `.pc`.

In `nix/shells/default.nix`, add to the devshell `packages`:

```nix
pkgs.pkg-config
inputs'.ghostty.packages.libghostty-vt        # runtime lib (.so + .pc)
inputs'.ghostty.packages.libghostty-vt.dev    # headers + dev .pc → PKG_CONFIG_PATH
```

- The **`.dev` output** carries the headers and the development `.pc`. Without it,
  pkg-config can't find the package and ImportC can't find the header.
- If the upstream is itself a flake, add it as an input in `flake.nix` with
  `follows` to dedupe `nixpkgs`/`systems`:

  ```nix
  ghostty = {
    url = "github:ghostty-org/ghostty";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.systems.follows = "systems";
    inputs.flake-compat.follows = "flake-compat";
    inputs.home-manager.follows = "home-manager";
  };
  ```

  For a plain nixpkgs library, just use `pkgs.<lib>` and `pkgs.<lib>.dev`.

- **`git add` new files before building under Nix.** The flake evaluates the git
  tree, so a freshly created `c.c`/`dub.sdl` is invisible to `nix develop` until
  staged (see [AGENTS.md](./AGENTS.md)).

### 5. Toolchain requirements & gotchas

- **dub version.** The pkg-config `--cflags` → `-P` behavior needs a dub that
  includes dub#3085. The repo pins it via `dlang-nix` in `nix/d-toolchain.nix`
  (`dub-1_43_0-alpha-5efed36`). An older dub silently won't pass the include to
  ImportC.
- **DMD ImportC vs GCC 15 headers.** DMD's ImportC preprocessor can't parse GCC
  15's `stddef.h` (the C23 `nullptr` keyword is unknown to the D parser).
  `nix/d-toolchain.nix` overrides `dmd` to build against `gcc14Stdenv` on
  GNU systems; macOS uses clang and is unaffected. If you see `nullptr`-related
  ImportC parse errors, this is why — use LDC or the gcc14 `dmd`.
- **Don't be fooled by `NIX_CFLAGS_COMPILE`.** ImportC shells out to the nix `cc`
  wrapper, whose `NIX_CFLAGS_COMPILE` _also_ satisfies includes inside the
  devshell. That can mask a missing pkg-config setup that fails outside Nix —
  always run the verification below.

### Verifying pkg-config is doing the work

Inside the devshell:

```console
$ dub build :terminal -v 2>&1 | grep pkg-config
Using pkg-config to resolve C preprocessor flags for raylib, libghostty-vt.
```

To prove the include comes from pkg-config and not the nix `cc` wrapper, unset
the nix C-include env and rebuild:

```console
$ env -u NIX_CFLAGS_COMPILE -u CPATH -u C_INCLUDE_PATH dub build :terminal --force
```

- Still builds → pkg-config (#3085) is supplying the include. ✅
- `fatal error: <header>: No such file or directory` → the binding is probably a
  plain `library` instead of `sourceLibrary`, or the `.dev` output / pkg-config
  is missing.

---

## Adding a new C dependency, step by step

1. **Make the library available (Nix).**
   - Flake library: add a flake input in `flake.nix` (with `follows`), then add
     `inputs'.<input>.packages.<lib>` **and** `…​.<lib>.dev` to the devshell
     `packages` in `nix/shells/default.nix`.
   - nixpkgs library: add `pkgs.<lib>` and `pkgs.<lib>.dev`.
   - `pkgs.pkg-config` is already in the devshell.
   - Confirm: `pkg-config --cflags --libs <pcname>` prints include + link flags.
2. **Create the binding sub-package** `libs/<name>/`:
   - `src/sparkles/<name>/c.c`:
     ```c
     #pragma attribute(push, nogc, nothrow)   // drop attrs the lib violates; never add `pure` if it has state
     #include <foo/foo.h>
     #pragma attribute(pop)
     ```
   - `dub.sdl`:

     ```sdl
     name "<name>"
     dflags "-preview=in" "-preview=dip1000"

     libs "<linkname>"                 // must match the pkg-config package (modulo a `lib` prefix)

     configuration "library" {
         targetType "sourceLibrary"    // REQUIRED — see the gotcha
     }

     configuration "unittest" {
         dependency "silly" version="~>1.1.1"
         dflags "-checkaction=context" "-allinst"
         dflags "-defaultlib=libphobos2.so" "-L-fuse-ld=gold" platform="linux-dmd"
         dflags "--link-defaultlib-shared" "--linker=gold" platform="linux-ldc"
         lflags "--export-dynamic" platform="linux-ldc"
     }
     ```

   - Register it in the root `dub.sdl`: add `subPackage "libs/<name>"` (keep the
     list sorted).

3. **`git add`** the new files so the flake/devshell sees them.
4. **Use it from D**: `import sparkles.<name>.c;` and call the C symbols.
   Optionally add a thin RAII wrapper (`struct` with a destructor calling the C
   `*_free`, `@disable this(this)`) in a separate module — but keep it honest:
   the pragma already supplies the attributes, so no function-pointer casts.
5. **Verify**: `dub test :<name>` passes, the consumer (`dub build :<app>`)
   builds, and the unset-`NIX_CFLAGS_COMPILE` check above still finds the header.

---

## When there is no pkg-config `.pc` file

pkg-config is the clean path. If upstream ships no `.pc`:

- Set `cImportPaths "<dir>"` to the header directory. Unlike pkg-config, this
  applies at library-compile time too — but the directory must be known. Derive
  it in Nix and pass it via an env var consumed in `dub.sdl`, e.g.
  `dflags "-P-I$FOO_INCLUDE"`, exporting `FOO_INCLUDE` from the devshell
  `shellHook`. This is the pre-#3085 pattern; **avoid it when a `.pc` exists.**
- For linking without pkg-config, `libs "<name>"` resolves to `-l<name>`; ensure
  the `-L` directory is on the linker search path (nix `buildInputs` handle this).

---

## ImportC limitations worth knowing

- **Module name is the file _stem_.** ImportC names the module after the file's
  base name, ignoring the package path: `sparkles/ghostty/c.c` becomes module
  `c`. That is fine for one binding, but when a build links **two** ImportC
  bindings that both use `c.c`, their modules collide (`module 'c' … conflicts
with another module c`). Give each shim a **unique stem** —
  `libs/utf8proc/src/sparkles/utf8proc/utf8proc_c.c` (module `utf8proc_c`), with
  `package.d` doing `public import sparkles.utf8proc.utf8proc_c;`. The canonical
  `c.c` is only safe while a binary pulls in at most one such binding.
- **Macros.** ImportC exposes simple object-like `#define INT_CONST 5` as manifest
  constants, but **function-like macros and `static inline` functions are not
  reliably importable.** Re-declare the value in D (`enum X = 1004;`) or call a
  wrapper from the `.c`. (We hit this with libghostty's `GHOSTTY_MODE_FOCUS_EVENT`
  and the device-attribute `#define`s — re-declared as D `enum`s.)
- **Fortified `<wchar.h>` is unparseable.** A heavy system header that includes
  `<wchar.h>` (e.g. `<notcurses/notcurses.h>`) pulls glibc's `bits/wchar2.h`,
  whose `_FORTIFY_SOURCE` inline wrappers use compiler builtins ImportC doesn't
  implement (`__builtin_dynamic_object_size`, `__builtin_va_arg_pack`). The nix cc
  wrapper forces `_FORTIFY_SOURCE`, so `-P-D_FORTIFY_SOURCE=0` can't override it.
  If the symbol you need has a **primitive signature**, skip the header and
  declare just its prototype in the shim — the symbol resolves from the `.so`.
  (notcurses' `ncstrwidth` is `int(const char*, int*, int*)`, so the shim is one
  line, no `#include`.)
- **A shim that _defines_ functions needs `cSourcePaths`.** Declaration-only shims
  (whose symbols live in the `.so`) are pulled in via `-I` + import and link fine.
  But if the shim **defines** a wrapper (e.g. to hide a versioned/renamed symbol —
  ICU renames `ubrk_open`→`ubrk_open_76` via macros), the import-only path doesn't
  emit the body → undefined-reference at link. Add `cSourcePaths "src/sparkles/<name>"`
  so dub compiles the `.c` as a real source. Its module is then the bare **stem**
  (`import icu_c;`, not `import sparkles.icu.icu_c;`).
- **Embedding Python (PyD), not ImportC.** Calling Python _from_ D in-process is
  done with PyD (the engine behind `$REPOS/dlang/autowrap`), not an ImportC shim.
  See `libs/base/tools/text-conformance/src/sparkles/text_conformance/layer10_python_wcwidth.d`
  for the working pattern (pin pyd to the untagged D-2.111-compat commit; read
  result lists element-wise; `__import__` inside comprehensions).
- **`const` on parameters.** ImportC may drop top-level `const` on function
  parameters; match the _generated_ signature (declare a callback's param
  non-`const` if the generated decl is non-`const`).
- **Sized structs.** Many C APIs lead a struct with `size_t size;` as a version
  tag — set it (`s.size = S.sizeof;`) before passing the struct out/in, as the
  upstream C examples do.

---

## Checklist

- [ ] `.c` shim wraps the `#include` in `#pragma attribute(push, nogc, nothrow)`
      (no `pure` if the library is stateful).
- [ ] Binding package is `targetType "sourceLibrary"`.
- [ ] `libs "<name>"` matches the pkg-config package name (modulo a `lib` prefix).
- [ ] Devshell has `pkg-config` + the library + its `.dev` output (and a flake
      input if upstream is a flake).
- [ ] New files `git add`-ed before building under Nix.
- [ ] Registered in the root `dub.sdl` `subPackage` list (sorted).
- [ ] Verified the include comes from pkg-config (unset-`NIX_CFLAGS_COMPILE` build).
- [ ] `dub test :<name>` passes.

## See also

- [AGENTS.md](./AGENTS.md) — environment/build/test, `git add` new files, layout.
- [Code Style](./code-style.md) — safety attributes (annotate non-templates,
  infer on templates).
- ImportC spec: <https://dlang.org/spec/importc> ·
  pragma: <https://dlang.org/spec/importc#pragma>
- dub PRs: [#2544](https://github.com/dlang/dub/pull/2544) (cSourcePaths/
  cImportPaths) · [#2818](https://github.com/dlang/dub/pull/2818) (cImportPaths
  DMD/LDC fix) · [#3085](https://github.com/dlang/dub/pull/3085) (pkg-config
  `--cflags`).
