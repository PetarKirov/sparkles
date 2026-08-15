# Grounding ledger — topiary.md

Verification against `$REPOS/rust/topiary` @ `a307aee6787602e51087c54f867976949feae383`
(**depth-1 clone**).

## Verified verbatim (✓)

| Claim                                                                                                                       | Source                                                                     |
| --------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| The README pitch, incl. "without having to write their own formatting engine or even their own parser"                      | `README.md`                                                                |
| The TOML query excerpt (`@leaf`, `@allow_blank_line_before`, `@append_hardline`) with its comments                          | `topiary-queries/queries/toml/formatting.scm`                              |
| The capture-name vocabulary (~30 names)                                                                                     | `grep -oh '@[a-z_.]*' topiary-queries/queries/*/formatting.scm \| sort -u` |
| 15 shipped languages                                                                                                        | `ls topiary-queries/queries/`                                              |
| `topiary-core/src/` file list (`lib.rs`, `pretty.rs`, `atom_collection.rs`, `tree_sitter.rs`, `language.rs`, `graphviz.rs`) | `ls`                                                                       |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                            | Status | Note                                                                                                                                                                                                                   |
| --- | ------------------------------------------------------------------------------------------------ | ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1   | **The capture → concept mapping table**                                                          | ◯      | Each capture name is verified to exist; **the semantics assigned to each are inferred from the names and the TOML example.** `topiary-core` was not read. This is the page's central artifact and its weakest evidence |
| 2   | "`@append_input_softline` — break iff the input had one here"                                    | ◯⚠     | Reading the name. Not verified in `pretty.rs`. If wrong, a load-bearing claim (it is cited from [concepts](../concepts.md) and the [comparison](../comparison.md)) is wrong                                            |
| 3   | "Measuring scopes decouple 'what determines whether this fits' from 'what breaks if it doesn't'" | ◯⚠     | Inferred from `@append_begin_measuring_scope` / `@append_end_measuring_scope`. Not verified                                                                                                                            |
| 4   | "**No column alignment** — the capture vocabulary has no `align`"                                | ✓      | Verified against the full capture list                                                                                                                                                                                 |
| 5   | "the queries produce a stream of _atoms_ … which `pretty.rs` renders"                            | ⚠      | From file names only                                                                                                                                                                                                   |
| 6   | "Under the hood the break decision is combinator-style fit testing over scopes"                  | ⚠      | Inferred; `pretty.rs` not read                                                                                                                                                                                         |
| 7   | "Topiary refuses to format when the tree contains errors"                                        | 🌐     | Not verified                                                                                                                                                                                                           |
| 8   | "an **idempotence check is part of the tool's own test discipline**"                             | 🌐     | Not verified                                                                                                                                                                                                           |
| 9   | "a soft `indent`/line-width configured per language in `languages.ncl`"                          | ⚠      | File exists; not read                                                                                                                                                                                                  |
| 10  | "tree-sitter-d … **already pinned in this repository's flake**"                                  | ✓      | `nix/packages/tree-sitter-d.nix` and the `AGENTS.md` description; verified in-repo                                                                                                                                     |
| 11  | The "What this means for D" assessment, incl. "unlikely to beat dfmt on quality"                 | ◯      | Editorial judgement                                                                                                                                                                                                    |

> [!WARNING]
> **`topiary-core` was not read at all.** Every claim about _how_ topiary formats — the atom
> stream, the fit testing, measuring-scope semantics, error handling — is inference from file and
> capture names. The claims about _what a formatting spec looks like_ (the query file, the capture
> vocabulary, the absence of `align`) are solid. Read `pretty.rs` before relying on rows 1–3, 5, 6.

## Not verified here

- `topiary-core/src/*.rs`, `topiary-cli`, `topiary-config`, `languages.ncl`, and 14 of the 15
  query files.
