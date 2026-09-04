# Concepts — substitute, build, execute

Three different jobs share the phrase "Linux on macOS". Mixing them up is
how `nix build nixpkgs#legacyPackages.aarch64-linux.hello` succeeding is
mistaken for `ci --test` having run on Linux.

## Substitute

Nix copies a realized store path from a binary cache into the local
`/nix/store`. The path's `system` is `aarch64-linux`; the bytes are a
Linux ELF (or a tree of them). No VM runs. Observed on this host,
2026-09-04:

```text
$ nix build nixpkgs#legacyPackages.aarch64-linux.hello --print-out-paths
copying path '/nix/store/846h582z2d4mifn4km7axlqllcyn6zdg-hello-2.12.3' from 'https://cache.nixos.org'...
$ file result/bin/hello
ELF 64-bit LSB pie executable, ARM aarch64, ... interpreter
/nix/store/...-glibc-2.42-67/lib/ld-linux-aarch64.so.1
```

The same for `x86_64-linux` (`ld-linux-x86-64.so.2`). Sparkles'
`packages.aarch64-linux.ci` likewise substitutes from
`https://sparkles.cachix.org` — GitHub Actions already built it.

Substituting does **not** need a Linux builder. Disabling
`external-builders` still fetches.

## Build

Nix must run the derivation's builder (`bash` + the build script) on a
machine whose `system` matches. On `aarch64-darwin` that is not this
kernel. Options:

1. **`external-builders`** — Nix execs a helper with a JSON description
   of the drv; the helper boots a Linux VM, mounts `/nix/store`, runs the
   builder, writes the output back. Determinate Nixd and IOHK
   `nix-linux-builder` implement this.
2. **SSH remote builder** — `builders = ssh-ng://builder@linux-builder ...`
   as in nix-darwin `nix.linux-builder`.
3. **Build inside a Linux VM** that has its own Nix daemon (Apple
   `container` with Nix installed). The host Nix is not involved.

A derivation that is _not_ in any cache cannot be substituted and needs
one of the above. `pkgs.symlinkJoin` of two already-substituted Linux
packages is a _new_ drv: without a builder it fails with
`Reason: platform mismatch` / `Current system: 'aarch64-darwin'`.

`nix print-dev-env .#devShells.aarch64-linux.ci` hits the same wall: the
shell's `nix-shell-env.drv` is unique and not cached, so eval succeeds
and realization fails.

## Execute

A Linux ELF cannot `execve` on Darwin, even when the CPU is aarch64 —
the ABI and syscall table differ. `file` on the substituted `hello` is
not a run. To execute you need a Linux kernel:

- Determinate / nix-darwin builders execute **only as a derivation
  builder**. There is no interactive `ci --test` shell.
- Apple `container` (and Containerization) boot a Linux VM per
  container. Bind-mount `/nix/store` and the ELF's interpreter
  (`ld-linux-*.so.1`, itself in the store) works. Observed:

  ```text
  $ container run --rm --arch arm64 --volume /nix/store:/nix/store alpine \
      /nix/store/846h58...-hello-2.12.3/bin/hello
  Hello, world!
  ```

  The same for the x86_64 `hello` with `--arch amd64 --rosetta`.

`ci --test` is execute, not build: it is `dub test` in a writable
working tree, using a D compiler on `PATH`. The Linux `packages.ci`
wrapper puts `ldc`, `dub`, and `git` on `PATH`. Combined with a store
bind-mount, that _is_ a Linux `ci --test`.

## The store bind-mount

Apple Virtualization.framework exposes host directories via VirtioFS.
Mounting `/nix/store` read-only into the guest is enough to run
substituted Linux paths. The guest does not need its own Nix. It cannot
_add_ store paths (the mount is read-only, and the Darwin nix-daemon
socket is not a Linux socket).

IOHK's builder uses the same trick for _builds_, plus an ext4 loop
image for `/build` because Apple's VirtioFS does not honour Linux
`DAC_OVERRIDE`.

## Enter a dev shell without building it

`ci --test` on CI runs inside `devShells.ci`: raylib, tree-sitter,
libghostty-vt, SDL3, elfutils and the rest are on `PKG_CONFIG_PATH` and the
linker path because stdenv's setup hooks put them there. The `ci` wrapper
alone is not that environment — the first Linux run here died linking
`diagram` with `cannot find -lraylib`.

The shell's output is `nix-shell-env` (Determinate Nix names the drv
`nix-shell.drv`), a derivation whose _build_ is trivial and whose _inputs_
are all the packages. Two facts make it enterable with no builder:

1. **Its environment is data.** `nix derivation show` instantiates the drv
   and prints `builder`, `env.stdenv`, `env.nativeBuildInputs`,
   `env.shellHook`, … as JSON. Instantiation is evaluation; nothing runs.
2. **`nix-shell` never builds it either.** `nix-shell` exports the drv's
   env, sets `IN_NIX_SHELL`/`NIX_BUILD_TOP`/`TMPDIR`, sources
   `$stdenv/setup` (which runs every setup hook and builds `PATH`,
   `PKG_CONFIG_PATH`, the cc-wrapper flags), then `runHook shellHook`.
   `nix develop` does the same through `get-env.sh`, which _is_ a build —
   that is why `nix print-dev-env` hits `platform mismatch` here and
   `nix-shell`'s recipe does not.

So the dispatcher realizes every store path the JSON names (73 on
`aarch64-linux`, 74 on `x86_64-linux`; substitutes, since CI built them),
writes a script that
replays `nix-shell`'s rc with the store's own bash as its interpreter, mounts
it into the container, and execs `ci` from inside the entered shell:

```bash
#!/nix/store/…-bash-5.3p15/bin/bash
export stdenv='/nix/store/…-stdenv-linux'
export nativeBuildInputs='/nix/store/…-delta-0.19.2 /nix/store/…-ci-0.1.0 …'
export shellHook='…'
export IN_NIX_SHELL=impure
export NIX_BUILD_TOP=/tmp TMPDIR=/tmp TEMPDIR=/tmp TMP=/tmp TEMP=/tmp
export NIX_STORE=/nix/store
export NIX_BUILD_CORES=13
export HOME=/tmp
p="$PATH"
dontAddDisableDepTrack=1
[ -e "$stdenv/setup" ] && source "$stdenv/setup"
PATH="$PATH:$p"; unset p
set +e +u +o pipefail
if [ "$(type -t runHook)" = function ]; then runHook shellHook; fi
unset NIX_ENFORCE_PURITY
exec '/nix/store/…-ci-0.1.0/bin/ci' "$@"
```

The script is a file, not `--env`: the exported `shellHook` alone is 8 KiB.
A linked `git worktree` needs one more mount: its `.git` is a file naming
the main repository's git dir, so the dispatcher mounts
`git rev-parse --git-common-dir` read-only too — otherwise the inner `ci`'s
`git rev-parse --show-toplevel` finds no repository.
Inside, `pkg-config --libs raylib` answers, `$SPARKLES_TS_GRAMMAR_PATH` is
set, and `LIBRARY_PATH` carries elfutils/libpfm/libkqueue — the hook's
Linux branch, verbatim.

## Substituters are per-flake

`sparkles.cachix.org` is not in the global `nix.conf`; the flake's
`nixConfig` adds it, and Nix applies that only to a flake-scoped command
(after the one-time trust prompt that `~/.local/share/nix/trusted-settings.json`
records). So `nix build /nix/store/…-sparkles-dmd-import-paths` on a bare
store path consults `cache.nixos.org` alone and reports "no substituter
that can build it" for every sparkles-built input, while `nix path-info
--store https://sparkles.cachix.org` on the same path succeeds. The
dispatcher therefore substitutes the shell's inputs $(I through the flake
reference): `nix build --keep-going …#devShells.<system>.ci`. The shell's
own build then fails with `platform mismatch`, as expected — but Nix
realizes a derivation's inputs before it reaches that check, and
`--keep-going` lets every substitution finish. When the shell output is
cached (x86_64, via the `nix-build` job's `.#all`) the command simply
succeeds. Afterwards the dispatcher checks that each input exists.

The first aarch64 run worked without this only because the earlier
`print-dev-env` attempt had already pulled those paths into the local store.

## Which revision

The shell's inputs include `packages.ci`, whose source fileset is
`apps/ci/src` plus the transitive `libs/*/src` closure. An uncommitted edit
anywhere in there makes the working tree's shell a derivation no cache has,
and there is no builder — so the dispatcher never evaluates `.#`. It
evaluates `git+file://<repo>?rev=<sha>#devShells.<system>.ci` at `HEAD`,
then the branch's `@{upstream}`, then the merge-base with main, then main
itself (`origin/main`, or `origin/HEAD` / `main` when that ref was never
fetched), taking the first whose `packages.<system>.ci` substitutes and
whose shell inputs all arrive (`--host-ci-rev` pins one).
The tests still run against the bind-mounted working tree; only the
_environment_ is from the committed revision. The one thing that cannot be
tested this way is an edit to the dev shell itself.

## `external-builders` protocol

From [DeterminateSystems/nix-src#78][pr78]: Nix looks up
`external-builders` (JSON array of `{systems, program, args}`). For a
matching system it execs `program` with `args` plus a path to a JSON
document:

```json
{
  "builder": "/nix/store/...-bash/bin/bash",
  "args": ["-e", "/nix/store/...-builder.sh"],
  "env": { "HOME": "/homeless-shelter" },
  "storeDir": "/nix/store",
  "realStoreDir": "/nix/store",
  "tmpDir": "/tmp/nix-build-.../build",
  "tmpDirInSandbox": "/build"
}
```

"External" means external to Nix's in-process sandbox, **not** remote.
The helper is local. Determinate's helper is `/usr/local/bin/determinate-nixd builder`.

<!-- References -->

[pr78]: https://github.com/DeterminateSystems/nix-src/pull/78
