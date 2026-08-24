# D codemods — a distinct product on the formatter's substrate

_**Status:** roadmap, nothing implemented · **Date:** 2026-08-25 · **Scope:** automated,
type-aware source transformation for D · **Requirement IDs:** `CDM*`_

[D9][spec] put token rewriting inside the formatter's scope, and the moment it did, a second thing
became easy to conflate with the first. This page draws the line and gives the second thing its own
roadmap.

**The formatter respells; a codemod transforms.** Both emit `TextEdit[]`, both run on the same token
spine, and a user might reasonably ask for either with the words "fix my code" — but they differ in
the one property that decides how they can be shipped: **whether the tool needs to know types.**

---

## Where the line is

|              | **Formatter rewrites** ([D9][spec] tier 2)                             | **Codemods**                                                                                    |
| ------------ | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| Input        | tokens, plus the offset oracle                                         | tokens **and resolved types** (`sparkles:dmd-lsp`)                                              |
| Guarantee    | the program means the same thing                                       | the program means something _deliberately different or narrower_                                |
| Verification | mechanical, per rule (decode-and-compare, syntactic equivalence)       | type-checked at the site; ultimately, the build                                                 |
| Application  | whole file, unattended, on save                                        | per site, reviewed, usually once                                                                |
| Idempotent   | required                                                               | usually, but not definitionally                                                                 |
| Failure mode | wrong bytes                                                            | wrong program                                                                                   |
| Examples     | `alias X = Y;`, `q"…"` instead of escapes, import sorting, `=>` bodies | `format(…)` → IES, deprecated-API migration, `enum` → `static immutable`, library version bumps |

The test is not "how big is the change" — swapping a string literal's delimiter and swapping
`format` for an IES literal look equally local. The test is **whether a purely syntactic argument
establishes safety**. `q"EOS…EOS"` and `"…"` decode to identical code units, so a decoder settles
it. `format("%s %s", a, b)` returns a `string` while `i"$(a) $(b)"` is a compile-time sequence that
deliberately does not convert to one — so only the _callee's_ signature settles it, and that needs
a type. Anything in the second class belongs here, not in the formatter.

## Precedent

The ecosystems that split these two tools cleanly are the ones whose users are happiest running
either unattended:

| Tool                           | Position                                                                                    |
| ------------------------------ | ------------------------------------------------------------------------------------------- |
| `go fix`                       | separate binary from `gofmt`; migrates APIs across releases                                 |
| `clang-tidy`                   | separate from `clang-format`; type-aware checks with `--fix`, per-check opt-in              |
| `dotnet format analyzers`      | analyzers-with-fixers, distinct from whitespace formatting                                  |
| ruff                           | one binary, but `format` and `check --fix` are separate subcommands with separate rule sets |
| `jscodeshift` / `ts-morph`     | codemods as a library; formatting deliberately delegated to prettier                        |
| IntelliJ / Roslyn code actions | per-site, reviewed, offered by the editor rather than applied in bulk                       |

The recurring shape: **codemods run through the formatter, never instead of it.** A codemod edits,
and the formatter then lays the result out — which means a codemod author never writes layout code,
and the two tools' test suites do not overlap.

---

## Architecture

```
sparkles:dmd-lsp   ──types, symbols, ddoc──┐
                                           ├─→  sparkles:dmd-codemod  ──TextEdit[]──→  sparkles:dmd-fmt  ──→  file
sparkles:dmd-fmt   ──spine, offsets────────┘        (rules)                              (layout)
```

- **CDM1 — Rules are data + a predicate + an edit producer.** A rule declares what it matches
  (token pattern, oracle fact, or resolved type), and returns edits. No rule prints layout; the
  formatter runs last, unconditionally.
- **CDM2 — Every rule is opt-in and individually named**, like `clang-tidy` checks. There is no
  "run all codemods" default, ever.
- **CDM3 — Application is per site with a reason string**, so a CLI can print, an LSP can offer a
  code action, and a review can read _why_ a site changed.
- **CDM4 — The verification story is the build.** A codemod run is followed by a compile of the
  affected modules; a rule that cannot be validated that way (because the change is in a
  `version`-gated arm, say) reports the site as **unverified** rather than applying silently.
- **CDM5 — Reuse the formatter's suppression mechanism.** `// dfmt off` ranges, verbatim regions
  and inactive arms are already the formatter's single suppression path (D5); codemods honour the
  same markers rather than inventing a second spelling.

## Roadmap

| Phase  | Contents                                                                                                                                               | Depends on                     |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------ |
| **C0** | The rule API, edit application and conflict resolution, the test harness (reuse the formatter's `.cases` shape from [the testing spec][testing])       | dmd-fmt M5 edits               |
| **C1** | Syntactic rules that the formatter declines because they are _migrations_, not respellings — deprecated-API renames, `dfmt`→`dmd-fmt` config migration | C0                             |
| **C2** | Type-aware rules. First rule: **`format("%s %s", a, b)` → `i"$(a) $(b)"`**, applied only where the callee accepts IES ([`P155`][decisions])            | `sparkles:dmd-lsp` type oracle |
| **C3** | Editor surface — LSP code actions, so a rule is offered at the site rather than run in bulk                                                            | C2, dmd-lsp server             |
| **C4** | Project-wide runs: git-aware application, per-rule commits, dry-run reports                                                                            | C1–C3                          |

C2 is the phase that justifies the split. Until types are available, a codemod tool is just a
formatter with a worse name.

## What this is not

- **Not a linter.** A rule here always has a fix; diagnostics without fixes belong in
  `sparkles:dmd-lsp`.
- **Not a refactoring engine.** Renames, extract-function and signature changes are editor
  operations over a whole project's symbol graph; they are dmd-lsp's, and their correctness
  argument is different again.
- **Not on by default, and not part of `dmd-fmt --check`.** A formatter that fails CI because a
  codemod is available would make the formatter unusable, which is precisely the confusion this
  page exists to prevent.

## Traceability

- Spec: [the decision record][spec] (`D9` fixes the formatter's half of the line) ·
  [the testing spec][testing] (the `.cases` harness C0 reuses)
- Research: [the decision inventory][decisions] — `P155` is C2's first rule, and §J's hazard notes
  are the seed of the rule catalogue
- Libraries: `sparkles:dmd-lsp` (types), `sparkles:dmd-fmt` (spine, edits, layout)

[spec]: ./index.md
[testing]: ./testing.md
[decisions]: ../../research/code-formatting/prettier-decisions.md
