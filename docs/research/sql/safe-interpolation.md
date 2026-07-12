# Safe SQL Interpolation: A Case Study

A focused cross-cutting study of the one technique this survey's design centre depends on
most: **making the ergonomic `` sql`... ${value} ...` `` interpolation syntax the
_injection-safe_ one**. Every library in the [master catalog][index] makes parameter
binding its default ([concepts: statements, parameters & injection][safety]); this page
asks _how_ — which **language facility** each ecosystem uses to let a library tell a trusted
literal from an untrusted value — and culminates in **D's interpolated expression sequences
(IES)**, the mechanism a `sparkles:sql` safe-SQL layer would be built on.

**Last reviewed:** July 12, 2026

> [!NOTE]
> This is a synthesis/case-study page, not a library deep-dive. Its claims about a specific
> library restate that library's deep-dive (follow the links for verbatim citations); its
> D-specific claims are grounded in the repo's
> [IES guideline](../../guidelines/interpolated-expression-sequences.md),
> [`core.interpolation`][core-interpolation], and Adam D. Ruppe's
> [`interpolation-examples`][ie-repo] (pinned locally), plus a CI-verified runnable demo.

---

## The problem: string-building _is_ the vulnerability

SQL injection is not really a database problem; it is a **string problem**. The moment a
query is assembled by concatenating trusted SQL text with untrusted data —

```d
// The archetypal vulnerability (any language):
string q = "SELECT * FROM users WHERE name = '" ~ userInput ~ "'";
// userInput = "'; DROP TABLE users; --"  ->  the data becomes SQL
```

— the boundary between _structure_ (the query) and _data_ (the values) is erased. The
industry answer is **parameter binding**: send the query text and the data on separate
channels, so data is never parsed as SQL ([concepts: prepared statement][safety]). The
catch is ergonomics: the safe API (positional `?` placeholders + a parallel array of
arguments) is clumsy and easy to misalign, while the dangerous API (`"..." + value`) is the
one that reads naturally. **Safe interpolation** closes that gap: it makes the natural
`${value}` syntax compile to a parameterized statement, so the readable path _is_ the safe
path.

## The core pattern: separate structure from data

Strip away the syntax and every safe-interpolation mechanism does the identical thing:

1. The query **structure** is taken **only from trusted source-code literals**.
2. Every **interpolated value** becomes a **bound parameter** (`?` / `$n` / `:name`).

What differs is the **language facility** that lets a library _see_ the literal-vs-value
boundary at the call site. That facility is the whole story, and the ecosystems split into
five families.

---

## The mechanisms, by language facility

### Runtime tagged templates (JavaScript/TypeScript)

JS tagged templates hand the callee the literal segments and the interpolated values as
**separate arguments** — `` sql`a ${x} b` `` calls `sql(["a ", " b"], x)`. The value can
never join the literal array, so the tag binds it. [postgres.js][pgjs] makes the _same_
`sql` function both the query tag and the fragment/identifier builder; [Effect TS][effect-ts]
wraps the identical idea in an effect system, where every non-`Fragment` interpolation
becomes a bound `Parameter` and a `Statement` _is_ an `Effect`. Resolved at **runtime**.

```ts
// postgres.js / Effect TS — the ${id} is bound, not concatenated
const rows = await sql`SELECT * FROM users WHERE id = ${userId}`;
```

### Macro string interpolators (Scala)

Scala's `StringContext` splits `sql"a $x b"` into `parts` (the literals) and `args` (the
values); a macro-backed interpolator emits `?` for each arg and binds it. [doobie][doobie]'s
`sql"..."` / `fr"..."` (each `$x` needs a `Put[A]`) and [skunk][skunk]'s typed fragments
work this way — skunk's docs even state it **"never interpolates statement arguments."**
Expansion is compile-time; values bind at runtime.

### Quasi-quotation and AST macros (query-as-data)

The strongest form does not build a string _at all_: a macro reifies the query as an
**abstract syntax tree**, and interpolated values enter as **lifts** (bound params). Text is
produced only when a dialect renders the AST.

- [Quill][quill] — `quote { query[Person].filter(_.id == lift(id)) }` is a compile-time
  macro producing a `Quoted[T]` = AST + `Planter` lifts; the only injection surface is the
  explicit `#$` splice in its `sql"..."` escape.
- [Ecto][ecto] — query **macros** build an `%Ecto.Query{}`; the **`^` pin operator** marks a
  value as a bound parameter, and `fragment(...)` is the guarded raw escape.
- [persistent + esqueleto][pe] — a Template-Haskell **quasi-quoter**
  (`[persistLowerCase| … |]`) reifies the schema; esqueleto's `val` binds parameters.

### Macro-checked raw SQL (Rust/Go)

You still write SQL as a string literal, but a build step **validates** it and binds the
holes. [sqlx][sqlx]'s `query!("… WHERE id = $1", id)` checks the SQL against a real database
at compile time and infers the result type; [sqlc][sqlc] parses `-- name:`-annotated SQL
with an embedded real grammar and generates typed code. The value is always a separate,
bound argument.

### Interpolated strings that decompose into a format + args (.NET)

C# interpolated strings are the subtle case. `$"… {x} …"` can bind to a plain `string`
(**unsafe** — the hole is concatenated) _or_ to a `FormattableString` (**safe** — the hole is
a captured argument). [EF Core][ef-core]'s `FromSqlInterpolated($"… {id} …")` turns each hole
into a `@p0` parameter, while its `FromSqlRaw(string)` sibling carries the verbatim warning to
**"never pass a concatenated or interpolated string."** The safety therefore rides on
_choosing the right overload_ — a plain `$"..."` assigned to `string` silently loses the
boundary. This is the foot-gun D's design closes (below).

### Emerging: dedicated template strings (Python)

Python 3.14's **t-strings** (PEP 750) make `t"… {x} …"` evaluate to a `Template` object —
explicitly **not** a `str` — precisely so database and HTML libraries can bind or escape the
interpolations rather than receive a pre-built string. That a mainstream language is adding a
new literal form _whose whole purpose is safe interpolation_ is independent validation of the
design direction. _(Forward-looking; web-attested.)_

---

## The D approach: Interpolated Expression Sequences (IES)

D's [IES][d-spec-ies] (accepted as [DIP1036][dip1036], runtime types in
[`core.interpolation`][core-interpolation]) is the **most static** point on this whole
spectrum — the tagged-template idea moved to compile time and into the type system.

An `i"..."` literal is **not a string**. The compiler expands it, at compile time, into a
**typed tuple of segments**:

```d
int id = 1;
string name = "Alice";
auto ies = i"INSERT INTO sample (id, name) VALUES ($(id), $(name))";

// expands to a sequence equivalent to:
//   InterpolationHeader(),
//   InterpolatedLiteral!"INSERT INTO sample (id, name) VALUES (",  // trusted literal
//   InterpolatedExpression!"id",   // the SOURCE TEXT "id" — metadata only
//   id,                            // the runtime VALUE (untrusted)
//   InterpolatedLiteral!", ",
//   InterpolatedExpression!"name",
//   name,                          // the runtime VALUE (untrusted)
//   InterpolatedLiteral!")",
//   InterpolationFooter()
```

A library consumes it with a three-branch `static if` over the segment types — literal text
goes into the SQL verbatim, the expression-source is skipped, and every **value** becomes a
placeholder plus a bound parameter. Adam D. Ruppe's real-world binding
([`interpolation-examples/lib/sql.d`][ie-sql]) does exactly this, emitting the _right_
placeholder per engine (`?1`/`?2` for SQLite, `$1`/`$2` for Postgres, `?` for MySQL) from the
**same** user code:

```d
// lib/sql.d (SQLite path) — the load-bearing loop, abridged
foreach (idx, arg; Args)
    static if (is(arg == InterpolatedLiteral!str, string str))
        sql ~= str;                         // trusted literal -> query text
    else static if (is(arg == InterpolatedExpression!code, string code))
        {}                                  // expression source -> skip (metadata)
    else
        sql ~= "?" ~ to!string(++number);   // value -> placeholder; bound below
```

Its demo ([`06-sql.d`][ie-06]) drives the point home with a hostile value, and its own
comment answers the obvious worry:

> _"you might think this is sql injection... but it isn't! the lib uses the rich metadata
> provided by the interpolated sequence to use prepared statements appropriate for the db
> engine under the hood."_

```d
int id = 1;
string name = "' DROP TABLE', '";
db.execi(i"INSERT INTO sample VALUES ($(id), $(name))");   // safe: name is bound
```

### A runnable, injection-neutralizing demo

The mechanism, self-contained (no database, no external dependency — `core.interpolation` is
in druntime). `buildQuery` accepts an IES and returns the parameterized SQL alongside its
out-of-band binds; the `InterpolationHeader`/`InterpolationFooter` parameters are type-level
guards that make the function callable _only_ with `i"..."`, never a plain string:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_safe_sql_interpolation"
+/

import core.interpolation;
import std.array : appender;
import std.conv : to;
import std.stdio : writeln;

// A query paired with its out-of-band bind parameters — never a single string.
struct SafeQuery
{
    string sql;
    string[] params;
}

SafeQuery buildQuery(Seq...)(InterpolationHeader, Seq data, InterpolationFooter)
{
    auto sql = appender!string;
    string[] params;
    int n;
    static foreach (item; data)
    {{
        // A literal fragment from the SOURCE CODE — trusted, goes in verbatim.
        static if (is(typeof(item) == InterpolatedLiteral!s, string s))
            sql ~= s;
        // The source text of an interpolated expression ("id", "name") — metadata only.
        else static if (is(typeof(item) == InterpolatedExpression!c, string c))
        {
        }
        // Anything else is the runtime VALUE — untrusted: bind it out-of-band.
        else
        {
            sql ~= "$" ~ (++n).to!string;
            params ~= item.to!string;
        }
    }}
    return SafeQuery(sql[], params);
}

void main()
{
    int id = 1;
    string name = "'; DROP TABLE sample; --"; // hostile input

    auto q = buildQuery(i"INSERT INTO sample (id, name) VALUES ($(id), $(name))");

    writeln("SQL:    ", q.sql);
    writeln("params: ", q.params);
}
```

```[Output]
SQL:    INSERT INTO sample (id, name) VALUES ($1, $2)
params: ["1", "'; DROP TABLE sample; --"]
```

The hostile `name` lands in `params` as `$2`; it never touches the SQL text. This example is
compiled and run by CI ([AGENTS § runnable examples](../../guidelines/AGENTS.md#runnable-readme-examples)).

### Two properties that set IES apart

- **The SQL skeleton is a compile-time constant.** The `InterpolatedLiteral` segments carry
  their text as _template parameters_, so the parameterized query string is computed by
  [CTFE][ctfe] — there is no per-call string-building, which matters for `@nogc`/hot paths.
  (Ruppe's `lib/sql.d` computes its `enum string query` entirely at compile time.)
- **An IES cannot silently decay into a `string`.** The [IES guideline][ies-guide] states it
  plainly: _"IES does not implicitly convert to `string`. This is a deliberate safety
  decision to prevent injection vulnerabilities."_ Where C#'s `$"..."` can be assigned to a
  `string` and lose its bound-parameter structure, `i"...$(x)"` **will not compile** where a
  `string` is expected — the boundary is enforced by the type system, closing the .NET
  overload foot-gun by construction.

D also keeps, uniquely alongside Python's coming t-strings, the **source text of each
interpolation** (`InterpolatedExpression!"code"`) — irrelevant to binding, but a free win for
structured logging and query debugging.

---

## Comparison

| Ecosystem / facility                                        | Syntax              | Boundary resolved  | Prevents accidental string-building? | Keeps expression source? |
| ----------------------------------------------------------- | ------------------- | ------------------ | ------------------------------------ | ------------------------ |
| JS tagged templates ([pg.js][pgjs], [Effect TS][effect-ts]) | `` sql`… ${x}` ``   | Runtime            | Yes (tag receives arrays)            | No                       |
| Scala `StringContext` ([doobie][doobie], [skunk][skunk])    | `sql"… $x"`         | Compile (expand)   | Partial                              | No                       |
| Quotation / AST ([Quill][quill], [Ecto][ecto])              | `quote{…}` / `^x`   | Compile            | Yes (query is an AST)                | n/a                      |
| Macro-checked SQL ([sqlx][sqlx], [sqlc][sqlc])              | `query!("… $1", x)` | Compile (vs DB)    | Yes                                  | No                       |
| C# `FormattableString` ([EF Core][ef-core])                 | `$"… {x}"`          | Runtime            | **No** (degrades to `string`)        | No                       |
| Python t-strings (PEP 750)                                  | `t"… {x}"`          | Runtime            | Yes (`Template` ≠ `str`)             | Yes                      |
| **D IES** ([DIP1036][dip1036])                              | `i"… $(x)"`         | **Compile (CTFE)** | **Yes (IES ≠ `string`)**             | **Yes**                  |

The families rank cleanly by _how early_ and _how enforced_ the structure/data split is. D's
IES sits at the strong corner: the split is resolved at compile time, the parameterized query
is a compile-time constant, and the type system refuses the unsafe fallback — while remaining
a general language feature (the same `i"..."` powers HTML escaping, URL encoding, and the
repo's own [`styled_template`](../../libs/base/src/sparkles/base/styled_template.d)).

---

## Implications for `sparkles:sql`

For the effects-first design this survey informs, IES is the obvious substrate for the
safe-SQL layer, and it composes cleanly with the ideas the [comparison][comparison] draws
from the effect systems:

- **The `sql` capability is an IES-accepting query constructor.** A function of the shape
  `(InterpolationHeader, Args…, InterpolationFooter)` that yields a prepared statement — the D
  analogue of [Effect TS][effect-ts]'s move where the injected service _is_ the `sql` tag, so
  obtaining "the database" and "the safe way to write a query" are one act.
- **Dialect rendering at compile time.** Compute the parameterized skeleton via CTFE and pick
  the placeholder style (`?` / `$n` / `:name`) from a [Quill][quill]-style `Idiom` — Ruppe's
  `lib/sql.d` already demonstrates per-engine placeholders from one call site.
- **The boundary is type-enforced, not convention.** Because an IES cannot decay into a
  `string`, the safe path is the _only_ path — no `FromSqlRaw`-style escape hatch is reachable
  by accident; a raw-SQL escape must be spelled out explicitly (`.unsafe`), matching every
  well-designed library in the survey.
- **It stays below the ORM line.** Safe interpolation gives typed, composable, injection-proof
  queries with zero identity-map / unit-of-work machinery — exactly the "functional data
  mapper that stops below the full-ORM rung" the [comparison][comparison] recommends.

---

## Sources

- **D IES:** the repo's [Interpolated Expression Sequences guideline][ies-guide];
  [`core.interpolation`][core-interpolation]; the [D spec on interpolation][d-spec-ies];
  [DIP1036][dip1036]. Real-world binding: Adam D. Ruppe's
  [`interpolation-examples`][ie-repo] — [`lib/sql.d`][ie-sql] and [`06-sql.d`][ie-06].
- **Foreign mechanisms:** each restates its own deep-dive — [Effect TS][effect-ts],
  [postgres.js][pgjs], [doobie][doobie], [skunk][skunk], [Quill][quill], [Ecto][ecto],
  [sqlx][sqlx], [sqlc][sqlc], [EF Core][ef-core], [persistent + esqueleto][pe] — and the
  shared vocabulary in [concepts][safety].
- **Python t-strings:** PEP 750 (web-attested, forward-looking).

<!-- References -->

[index]: ./index.md
[comparison]: ./comparison.md
[safety]: ./concepts.md#statements-parameters-and-sql-injection
[effect-ts]: ./effect-ts.md
[pgjs]: ./postgres-js.md
[doobie]: ./doobie.md
[skunk]: ./skunk.md
[quill]: ./quill.md
[ecto]: ./ecto.md
[sqlx]: ./sqlx.md
[sqlc]: ./sqlc.md
[ef-core]: ./ef-core.md
[pe]: ./persistent-esqueleto.md
[ies-guide]: ../../guidelines/interpolated-expression-sequences.md
[d-spec-ies]: https://dlang.org/spec/istring.html
[core-interpolation]: https://dlang.org/phobos/core_interpolation.html
[dip1036]: https://github.com/dlang/DIPs/blob/master/DIPs/other/DIP1036.md
[ctfe]: https://dlang.org/spec/function.html#interpretation
[ie-repo]: https://github.com/adamdruppe/interpolation-examples
[ie-sql]: https://github.com/adamdruppe/interpolation-examples/blob/master/lib/sql.d
[ie-06]: https://github.com/adamdruppe/interpolation-examples/blob/master/06-sql.d
