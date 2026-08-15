# Grounding ledger — ocamlformat.md

Verification against `$REPOS/ocaml/ocamlformat` @ `20c4543119c82a51c2f3a9bf81620a7f31fe0e50`
(**depth-1 clone**).

## Verified verbatim (✓)

| Claim                                                                                                                           | Source                                                                   |
| ------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| The Warning-50 docstring-attachment message, incl. "OCamlformat does not support these cases" and `--no-comment-check`          | `lib/Translation_unit.ml:100-115`                                        |
| `Unstable of {iteration; prev; next; input_name}` as an error constructor                                                       | `Translation_unit.ml:42, 116`                                            |
| `if i >= conf.opr_opts.max_iters.v then … Error (Unstable {…})`                                                                 | `Translation_unit.ml:368-372`                                            |
| `Normalize_std_ast.equal std_fg conf std_t.ast std_t_new.ast`                                                                   | `Translation_unit.ml:326`                                                |
| `Normalize_std_ast.equal std_fg ~ignore_doc_comments:true` and `Normalize_std_ast.moved_docstrings`                             | `Translation_unit.ml:345, 349`                                           |
| `check_comments conf cmts_t ~old:ext_t ~new_:ext_t_new`; `check_all_locations`                                                  | `Translation_unit.ml:173, 290, 366`                                      |
| The `.unequal-ast` artifact suffix                                                                                              | `Translation_unit.ml:357`                                                |
| Both user-facing failure strings ("was not already formatted. ([max-iters = 1])"; "Cannot process %S … Please report this bug") | `Translation_unit.ml:124, 135`                                           |
| `max_iters` default **10**                                                                                                      | `lib/Conf.ml:268` (`max_iters= elt 10`), declared at `Conf.ml:1462-1470` |
| The recursive `print_check ~i` loop                                                                                             | `Translation_unit.ml:360-378`                                            |

## Not verbatim — synthesis, inference, or unchecked

| #   | Claim                                                                                             | Status | Note                                                                                                                          |
| --- | ------------------------------------------------------------------------------------------------- | ------ | ----------------------------------------------------------------------------------------------------------------------------- |
| 1   | "the most rigorous [verification] in this survey by a wide margin"                                | ◯      | Comparative claim over the 13 systems; supported by [verification.md](../verification.md)'s table                             |
| 2   | "Paradigm: **combinator**, built over OCaml's stdlib `Format` … via an `Fmt` layer"               | ⚠      | `lib/Fmt.ml` exists but was **not read**; the lineage is inferred from the name and from OCaml's `Format` being Oppen-derived |
| 3   | "Comment placement is checked" (as opposed to _decided_)                                          | ⚠      | `check_comments` is verified to exist and be called; its contents were not read                                               |
| 4   | "`ocp-indent` compatibility is an explicit concern"                                               | 🌐     | Not verified in this pass                                                                                                     |
| 5   | "Large option surface plus **profiles** (`conventional`, `default`, `janestreet`, `ocamlformat`)" | ⚠      | Profile names from general knowledge; `Conf.ml` was read only around `max_iters`                                              |
| 6   | "Whole document; `--check`; no range formatting or cursor"                                        | ⚠      | Negative claims, not traced through the CLI                                                                                   |
| 7   | "**Slow** — formatting runs up to `max-iters` times plus normalization"                           | ◯      | Follows from the verified loop; not measured                                                                                  |
| 8   | "D has exactly OCaml's hazard" (ddoc semantically attached)                                       | ◯      | The parallel is the survey's; the D half is established in [`dmd-lsp-baseline`](./dmd-lsp-baseline.md)                        |
| 9   | The whole "What a D formatter should take" section                                                | ◯      | Editorial — and it is the survey's single strongest recommendation, so worth marking as such                                  |

## Not verified here

- `Normalize_std_ast` itself — **what normalization actually ignores is the specification of what
  the formatter may change**, and it was not read. This is the most valuable unread file in the
  tree for anyone implementing the recommendation.
- The layout engine (`Fmt.ml`, the printing modules) — the doc makes no claims about layout quality.
