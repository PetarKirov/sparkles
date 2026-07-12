# Grounding ledger — safe-interpolation.md

Source (D specifics): `$REPOS/dlang/interpolation-examples` @ `a8a5d4d` (2023-10-30) +
the repo's `docs/guidelines/interpolated-expression-sequences.md` + `core.interpolation`
(druntime). `$REPOS` = `/home/petar/code/repos`. This is a **synthesis/case-study** page:
its foreign-library claims restate the already-ledgered deep-dives (Effect TS, postgres.js,
doobie, skunk, Quill, Ecto, sqlx, sqlc, EF Core, persistent+esqueleto); this ledger grounds
the **D-specific** claims and the runnable example.

## Claims

| #   | Claim                                                                                                         | Type           | Source (local + locator)                                                         | Evidence                                                                                                                                                                                                      | Status                          |
| --- | ------------------------------------------------------------------------------------------------------------- | -------------- | -------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------- |
| 1   | An `i"..."` IES is not a string; it expands to a typed segment tuple (Header/Literal/Expression/value/Footer) | quote/behavior | `docs/guidelines/interpolated-expression-sequences.md` §3 (`:127-163`)           | "The compiler transforms it into a **sequence** of typed segments … `InterpolationHeader, ...segments..., InterpolationFooter`"                                                                               | ✓                               |
| 2   | IES does NOT implicitly convert to `string` — a deliberate anti-injection decision                            | quote          | `docs/guidelines/interpolated-expression-sequences.md` §2 (`:100`)               | "IES does not implicitly convert to `string`. This is a deliberate safety decision to prevent injection vulnerabilities."                                                                                     | ✓                               |
| 3   | Library dispatches on segment type: literal→text, expression→skip, value→placeholder+bind                     | behavior       | `$REPOS/dlang/interpolation-examples/lib/sql.d:40-48` (SQLite path)              | `static if (is(arg == InterpolatedLiteral!str, string str)) sql ~= str; … else sql ~= "?" ~ to!string(++number);`                                                                                             | ✓                               |
| 4   | The parameterized SQL skeleton is computed at compile time (CTFE), not per call                               | behavior       | `$REPOS/dlang/interpolation-examples/lib/sql.d:36-50`                            | `enum string query = () { string sql; … foreach(idx, arg; Args) … }();` (an `enum` = CTFE constant)                                                                                                           | ✓                               |
| 5   | The same user code emits different placeholders per engine (SQLite `?N`, Postgres `$N`, MySQL `?`)            | behavior       | `lib/sql.d:48` (`"?"~number`), `:78` (`"$"~idx`), `:100` (`"?"`)                 | three `execi` overloads; comment `:12-13` "all do it slightly differently … the user code works the same"                                                                                                     | ✓                               |
| 6   | `06-sql.d` demo: hostile `name` is bound, not injected                                                        | quote          | `$REPOS/dlang/interpolation-examples/06-sql.d:12-17`                             | "you might think this is sql injection... but it isn't! the lib uses the rich metadata … prepared statements …"; `string name = "' DROP TABLE', '"; db.execi(i"INSERT INTO sample VALUES ($(id), $(name))");` | ✓                               |
| 7   | `InterpolatedExpression!"code"` carries the source text of the expression (metadata only)                     | quote          | `docs/guidelines/interpolated-expression-sequences.md` §3 (`:141`, `:168`)       | "`InterpolatedExpression!\"code\"` … Source text of next expression"; ".expression enum"                                                                                                                      | ✓                               |
| 8   | Runnable demo output matches the `[Output]` block                                                             | figure         | CI: `ci --verify docs/research/sql/safe-interpolation.md` (this session)         | `✓ ran │ ✓ output matches` — `SQL: INSERT INTO sample (id, name) VALUES ($1, $2)` / `params: ["1", "'; DROP TABLE sample; --"]`                                                                               | ✓                               |
| 9   | `static foreach` over IES needs a per-iteration scope (`{{ }}`) for pattern captures                          | behavior       | ldc2 1.41 compile (this session) + guideline `styled_template` example (`:547`)  | first `{ }` build failed ("`s` is already defined"); `{{ }}` (as in `styled_template`) compiles                                                                                                               | ✓                               |
| 10  | `core.interpolation` is druntime (no external dep); IES = accepted DIP1036                                    | fact           | `lib/sql.d:3` (`import core.interpolation;`); guideline References (`:764,778`)  | druntime import; "DIP1036 — String Interpolation"                                                                                                                                                             | ◯ (DIP acceptance web-attested) |
| 11  | Python PEP 750 t-strings produce a `Template`, not a `str`, for safe interpolation                            | fact           | web (PEP 750)                                                                    | forward-looking; flagged web-attested in the page                                                                                                                                                             | ◯                               |
| 12  | C# `$"..."` can bind to `string` (unsafe) or `FormattableString` (safe); EF Core dual overloads               | behavior       | restated from [`ef-core.md`](../ef-core.md) (`FromSqlInterpolated`/`FromSqlRaw`) | ledgered in `grounding/ef-core.md`                                                                                                                                                                            | ✓ (via deep-dive)               |

## Discrepancies

None. The `{{ }}` scope requirement (row 9) is a D idiom, not a page error — the page's
embedded example uses `{{ }}` and CI-verifies.

## Unsourced / opinion

The "families rank cleanly by how early/enforced the split is" framing and the
`sparkles:sql` implications are editorial synthesis (grounded in the mechanisms above and the
[comparison](../comparison.md) design brief).

## Net

12 claims — 9 ✓ local-primary (D source + guideline + CI run), 1 ✓ via a sibling deep-dive
ledger, 2 ◯ web-attested (DIP1036 acceptance date, PEP 750). 0 discrepancies. The runnable
example is CI-verified.
