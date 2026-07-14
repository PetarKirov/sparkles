# Cutting a Release

How to version, tag, and publish `sparkles`. The repo ships as a **single
monorepo version**: one `vX.Y.Z` tag moves all eight sub-packages together, and
that tag is the authoritative version — there is no `version` field in any
`dub.sdl`.

> [!IMPORTANT]
> A published version is **immutable**. Once you push a `vX.Y.Z` tag,
> code.dlang.org ingests it and downstream consumers cache it. Re-tagging or
> force-pushing an already-published version poisons their caches. Get the
> commit green and on `main` _before_ you tag.

## Versioning policy

- **One version for the whole repo.** dub derives the version from the git tag
  (`git describe`), so every sub-package — `sparkles:base`, `sparkles:core-cli`,
  `sparkles:versions`, … — is released at the same `X.Y.Z`. A downstream project
  that pins `sparkles:base "~>0.4.0"` and `sparkles:core-cli "~>0.4.0"` is
  guaranteed a mutually consistent set.
- **The tag is the source of truth.** No `dub.sdl` carries a `version` field, by
  design.

  > [!WARNING]
  > Do **not** "bump the version" by adding or editing a `version` field in a
  > `dub.sdl`. There isn't one, and adding one overrides the tag-derived version
  > and breaks the single-version invariant. The only place a release version
  > lives is the git tag.

- **Pre-1.0 SemVer.** While the major is `0`, the
  [SemVer](https://semver.org/) rule is that anything may break. This repo uses
  the common pre-1.0 refinement:

  | Bump                | When                                                       | Example                                                    |
  | ------------------- | ---------------------------------------------------------- | ---------------------------------------------------------- |
  | **minor** (`0.Y.0`) | New features and/or **breaking** changes                   | `v0.2.0` (breaking error API), `v0.4.0` (removed `semver`) |
  | **patch** (`0.Y.Z`) | Backward-compatible fixes, or small non-breaking additions | `v0.0.2`, `v0.0.3` (fixes + minor additions)               |

  So before 1.0, a breaking change rides a **minor** bump — it does _not_ force a
  major. (Conventional-commit `feat(x)!:` / `fix(x)!:` markers still flag the
  break in history; they just don't imply a major while we're on `0.x`.)

- **`v` prefix.** Tags are `vX.Y.Z`; dub strips the leading `v`, so `v0.4.0`
  resolves as dub version `0.4.0`. Non-SemVer tags (e.g. the stray
  `befire-rebase`) are ignored by dub and are not releases.

## Cutting a release

> [!TIP]
> Most of this checklist is automated by the `release` tool:
>
> ```bash
> nix run .#release            # interactive: stats → bump → notes → local tag
> nix run .#release -- --auto --agent claude-code --stage push-tag
> ```
>
> It scans the tags, summarizes the commits, suggests the bump (using the policy
> above), gathers the notes (your `$EDITOR` or a CLI LLM agent), runs the
> pre-flight checks, and goes as far as `--stage` allows (default: a local
> annotated tag). The steps below are the reference it implements — and the
> fallback when you'd rather do it by hand.

A checklist. Each step assumes the toolchain from `nix develop` / `direnv`.

1. **Pick the version** per the policy above. Decide minor vs. patch from the
   changes since the last tag (`git log v<last>..HEAD`).

2. **Land everything on `main` first.** The flake and tag both evaluate the git
   tree, so all release content must be **committed** (not just staged) and
   pushed. Confirm you're on `main` and up to date.

3. **Pre-flight — everything green.** Run the full CI locally; do not tag a red
   tree.

   ```bash
   nix run .#ci -- --test --fail-fast          # dub test for every sub-package
   nix run .#ci -- --verify --files README.md  # README examples match output
   ```

   Lint (link check, formatting) runs via the pre-commit hooks; make sure the
   tip commit passed them.

4. **Refresh human-facing version strings.** Grep for the _old_ version and
   update any hardcoded mentions (e.g. the README status line / "Early stage"
   text). The dub badges read code.dlang.org live and need no edit.

   ```bash
   git grep -n "v0\.4\.0\|0\.4\.0"   # replace the old version where it's literal
   ```

5. **Write the release notes** as the annotated-tag body (see format below).

6. **Create the annotated tag** — always `-a`, because the body _is_ the
   changelog:

   ```bash
   git tag -a v0.5.0   # opens $EDITOR; paste subject + body
   # or: git tag -a v0.5.0 -F notes.md
   ```

7. **Push the tag**, then **publish a GitHub Release** for it (reuse the tag body
   as the release notes):

   ```bash
   git push origin v0.5.0
   gh release create v0.5.0 --notes-from-tag    # publishing fires the Release workflow
   ```

   Publishing the Release is what runs the
   [`release`](../../.github/workflows/release.yml)
   workflow that pings code.dlang.org for immediate ingestion and pins the
   release's `.#all` closure on Cachix (see below). The
   window between pushing the tag and publishing the Release is your last chance
   to delete a mistaken tag — but treat it as best-effort, not a safety net (the
   registry can ingest a pushed tag on its own before you publish).

## Catching up with `release --split`

When many unreleased commits have piled up (hundreds since the last tag), one
release would bury the changelog. `release --split` segments the backlog into a
**chain of releases** instead:

```bash
nix run .#release -- --split --agent claude-code                  # local tags
nix run .#release -- --split --agent claude-code --stage push-tag # and push
```

1. Every unreleased commit is associated with the PR that introduced it (via
   the GitHub GraphQL API — this repo rebase-merges, so `gh` is required even
   for local tags).
2. The agent proposes contiguous segments — boundary commit, theme, bump, and
   per-segment `highlights`. The tool validates the reply: no PR may straddle a
   boundary, bumps are floored at the policy above (under-bumps are escalated),
   and versions chain from the latest tag.
3. You review the plan table, decide what happens to any unreleased trailing
   remainder (WIP the agent left out), and confirm. Pushing is still gated by
   its own confirmation naming every tag.
4. Each segment then gets agent-written notes (reviewed in `$EDITOR` unless
   `--auto`) and an annotated tag **on its boundary commit**, oldest first.

Notes stay **curated**: work-in-progress inside a segment may be omitted and is
documented in the release where it completes (that tag's notes summarize the
whole arc). Prompts, raw replies, and the validated plan are kept under
`.result/release-split/<timestamp>/` for later review — never a blocker.

If a split run stops early, the created tags stand; re-running `--split`
resumes naturally, because the backlog now starts at the last created tag. The
full contract lives in [`docs/specs/release/SPEC.md`](../specs/release/SPEC.md).

## Release notes — the annotated-tag body

The annotated tag's message **is** the changelog; there is no separate
`CHANGELOG.md`. Follow the established shape:

- **Subject:** `vX.Y.Z — <short theme>` (em dash, lowercase-ish theme). This is
  what shows up in `git tag` listings and GitHub's releases.
- **Body:** blank line, then sections grouped by **area**, each with an
  underlined heading. Reuse the area names from the commit-scope convention
  (`core-cli`, `versions`, `ci`, `Build / Nix`, `Docs`, …).

```
v0.5.0 — <theme>

New sub-packages
----------------
- sparkles:foo — one-line description
  - notable capability
  - notable capability

core-cli
--------
- New: <feature>

BREAKING — core-cli
-------------------
- <what changed and why>

  Migration:
    Before: oldCall(args...)
    After:  newCall("message", args...)

Docs
----
- <doc change>
```

Put every breaking change under a `BREAKING — <area>` heading with a concrete
**Migration** block — that section is the first thing a consumer reads when a
`~>` constraint pulls in a new minor.

## Publishing to code.dlang.org

`sparkles` is a **single registered package** on
[code.dlang.org](https://code.dlang.org/packages/sparkles); the sub-packages are
addressed as `sparkles:base`, `sparkles:core-cli`, etc., all sharing the repo
version.

- **There is no upload step.** code.dlang.org is registered against the GitHub
  repo and a background scanner periodically polls it for new `vX.Y.Z` tags
  ([`dub-registry`'s `updatePackages`](https://github.com/dlang/dub-registry/blob/8060161910f9012ec3659c317be8fa3f4e6bd439/source/dubregistry/registry.d)).
  So _any pushed tag_ eventually becomes a public version on its own schedule —
  which is why pushing the tag, not publishing the Release, is the real point of
  no return.
- **The `release` workflow's registry ping just makes ingestion immediate.** On a
  _published_ GitHub Release it `POST`s the registry's update endpoint
  (`https://code.dlang.org/api/packages/sparkles/update`) so the new version
  appears in seconds instead of waiting for the background poll. Gating on the
  Release event (rather than the tag push) buys a short grace period to delete a
  bad tag before we actively nudge the registry — best-effort, per the warning
  above. The endpoint takes an optional `secret`; set the `DUB_REGISTRY_SECRET`
  repo secret only if the package was registered with one.
- **Internal deps use `path=`, and that's fine for consumers.** Within the repo,
  sub-packages depend on each other via `path="../.."`. When a downstream project
  fetches `sparkles` at a tag, the whole monorepo tree is present in that single
  fetched version, so those path deps resolve inside it. External consumers still
  reference sub-packages **by version** (`dependency "sparkles:base"
version="~>0.5.0"`).
- **`version="*"` consumers float to the newest tag.** The README examples (and
  any `version="*"` dependency) resolve against the registry and will pick up the
  release as soon as it's ingested. README examples keep `version="*"` precisely
  so end users always get the latest; in-repo files use `path=` instead (see
  [AGENTS.md § In-repo dub dependency paths](./AGENTS.md)).

## Pinning the release closure on Cachix

Besides the registry ping, the `release` workflow builds `.#all` (the
aggregate from `nix/packages/all.nix`: the full dev shell, every package, and
every standalone example) on each supported system, pushes it to the Cachix
cache, and pins it under the stable name `latest-<system>` (e.g.
`latest-x86_64-linux`). Cachix has no unpin command, so retention works by
re-pinning: each release creates a new revision of the same pin, and
`--keep-revisions 3` keeps the last three releases' closures pinned while
older ones become garbage-collectable. Only the highest `v*` tag moves the
pins, so re-publishing an old release (or the racing runs of a `release
--split` chain) can't move them backwards. Current pins are listed at
`https://app.cachix.org/cache/<cache>/pins`.

## Pitfalls checklist

- [ ] Tag the commit **after** it's green and pushed to `main` — published
      versions are immutable; never force-push a tag consumers may have fetched.
- [ ] Use an **annotated** tag (`git tag -a`); the body is the changelog.
- [ ] `vX.Y.Z` format — dub strips the `v`; non-SemVer tags aren't releases.
- [ ] Don't add a `version` field to any `dub.sdl`; the tag is authoritative.
- [ ] Pre-1.0, a breaking change is a **minor** bump, not a major.
- [ ] All release content **committed** (not just staged) before tagging — the
      git tree is what gets evaluated.
- [ ] Update hardcoded version strings (README status line); badges are live.
- [ ] Every breaking change has a `BREAKING — <area>` section with a Migration
      block.
