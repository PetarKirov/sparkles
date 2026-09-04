# Recommendations

**Last reviewed:** September 4, 2026

## Do this now

1. **Run Linux tests through Apple `container` and a substituted
   `packages.aarch64-linux.ci` / `packages.x86_64-linux.ci`.** That is
   `ci --host-system aarch64-linux`
   / `x86_64-linux`. It matches what this laptop can actually do today:
   caches have the Linux `ci` wrapper; the gated builder cannot compile
   missing paths; `container` can exec ELFs.
2. **Run without `--fail-fast`** and watch for a stalled log: the
   pre-existing `event-horizon` hang reproduces here in 2 of 3 runs, and
   a killed test binary lets the sweep continue.
3. **Probe before you debug.** `ci --linux-host-probe` reports
   Determinate (gated), Apple `container` (running or not),
   nix-darwin's `/etc/nix/machines`, and `extra-platforms`.
4. **Disable `external-builders` when substituting.** A configured-but-
   gated helper turns a cache hit into a 400. The dispatcher passes
   `--option external-builders '[]'` for that reason.
5. **Never evaluate `.#` for a Linux output.** The dirty tree is a
   derivation nobody built. Evaluate `git+file://…?rev=` at a revision CI
   has seen; the dispatcher does, and says which one it picked.

## Do this when a builder is actually needed

Uncached Linux drvs (`symlinkJoin`, `devShells.*.ci`'s `nix-shell-env`,
a dirty `packages.ci` not yet in cachix):

1. **Prefer IOHK `nix-linux-builder`** over waiting on the Determinate
   gate: same `external-builders` protocol, ungated, `nix-linux-shell`
   when a build fails. Pin
   [`65ecc7687e0df4b3e634e3e026f8e7822a961800`][iohk].
2. **Or enable nix-darwin `nix.linux-builder`** with
   `package = pkgs.darwin.linux-builder-vz` and
   `systems = [ "aarch64-linux" "x86_64-linux" ]` if a persistent
   NixOS guest is acceptable.
3. **If Determinate grants the feature**, raise `--cpu-count` in the
   `external-builders` JSON (default 1). Re-enable the helper for
   realize; keep Apple `container` for `ci --test`.

## Do not

- Treat `nix build .#packages.aarch64-linux.hello` as evidence that
  tests ran. That is a substitute.
- Bind-mount Darwin `SPARKLES_TS_GRAMMAR_PATH` into the guest. Grammar
  bundles contain native code; realize
  `.#packages.aarch64-linux.ts-grammars`.
- `symlinkJoin` Linux tools on Darwin. New drv, platform mismatch.
- Use `container machine`'s `$HOME` mount as the sparkles worktree.
  The repo is on `/Volumes/Dev`.

## Dispatcher contract

`apps/ci/src/linux_host.d`:

- `--linux-host-probe` — report backends, exit 0.
- `--host-system aarch64-linux|x86_64-linux` — pick the first of `HEAD`,
  `@{upstream}`, `merge-base origin/main`, `origin/main` whose
  `packages.<system>.ci` substitutes and whose shell inputs all arrive;
  `nix derivation show` that revision's `devShells.<system>.ci`;
  substitute its inputs through the flake ref (`--keep-going`, since the
  shell drv itself cannot build here); write an `enter.sh` that replays
  `nix-shell`'s rc; `container system start` if needed; `container run`
  with `/nix/store:ro`, the checkout at its own path, the script's
  directory; exec `ci` with `--host-system`/`--host-ci-rev` stripped so a
  cached Linux `ci` (which may not know the flags) is not fed them.
- `--host-ci-rev REV` — pin that revision instead of the chain.
- `DC` crosses from the host only as a bare compiler name; CI's matrix
  sets it the same way (`ldc2` on aarch64, `ldc2`/`dmd` on x86_64).

The inner `ci` and the whole environment are the **cached** revision's.
Library tests run from the **mounted worktree**. Developing `apps/ci` or
the dev shell itself still needs a push (or a builder).

## Follow-ups

- Push `.#all-desktop` for `aarch64-linux` in CI so more of the
  closure substitutes (today the aarch64 shell _output_ is never cached;
  the dispatcher does not need it, `nix develop` on an arm box would).
- Optional: a `container machine` image with Nix in-guest, for the
  days cachix does not have `packages.ci`.
- Optional: IOHK as a nix-darwin module once someone wants uncached
  Linux builds locally.

<!-- References -->

[iohk]: https://github.com/input-output-hk/nix-linux-builder/blob/65ecc7687e0df4b3e634e3e026f8e7822a961800/README.md
[baseline]: ./sparkles-baseline.md
