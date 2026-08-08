# `sparkles:wired` — the baseline

The system under improvement: an inventory of what `sparkles:wired` can and
cannot express today, audited against the same six dimensions every
[deep-dive](./index.md#master-catalog) in this tree uses. The
[comparison](./comparison.md) doc's delta table is computed against this page.

| Field        | Value                                                                                 |
| ------------ | ------------------------------------------------------------------------------------- |
| Language     | D                                                                                     |
| Package      | `sparkles:wired` (`libs/wired`)                                                       |
| Spec         | [`docs/specs/wired/SPEC.md`][wired-spec] · [open issues][wired-issues]                |
| Category     | [Tier 1][tiers] (codegen via CTFE) with a partially reified policy table              |
| Dependencies | `sparkles:base`, `expected`, `optional`                                               |
| Size         | ~7.7 kLOC: `policy.d` (912) + `json/codec.d` (2 066) + the arena JSON engine (~4 700) |

> [!NOTE]
> File/line citations refer to the tree as of **August 9, 2026** (branch
> `docs/serde-research`, stacked on the `feat/core-cli/subcommands` reland).
> Three findings below are backed by runnable examples that CI compiles and
> runs — if wired's behaviour changes, this page goes red and must be updated.

---

## Overview

wired is an annotation-driven, `Expected`-based serialization library: a
format-generic **policy layer** (`sparkles.wired.policy`) of six `@Wire*` UDAs,
each templated on a format marker type, plus a **JSON backend**
(`sparkles.wired.json`) — an arena document engine and a derived codec that is
within ~2.3× of `yyjson` on the twitter corpus while remaining fully
declarative. The near-term design question this survey feeds: re-expressing the
just-landed CLI argument engine (`sparkles.core_cli.args`) as a second wired
format, bidirectionally (`argv` ⇄ struct), per
[`docs/specs/dman/command-schema.md`][command-schema].

The tour below is the working system in one program:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_baseline_tour"
    dependency "sparkles:wired" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

import std.stdio : writeln;
import sparkles.wired;

enum Level
{
    info,
    warning,
    fatal,
}

@WireCase!Json(CaseStyle.snakeCase)
struct Server
{
    @WireName!Json("db_host") string dbHost;
    ushort httpPort = 8080;
    @WireOptional!Json(WireSkip.whenDefault) string[] tags;
    Level logLevel = Level.info;
}

void main()
{
    auto s = Server("localhost");
    writeln(toJSON(s).value[]);

    auto parsed = fromJSON!Server(`{"db_host":"h","http_port":9,"log_level":"warning"}`);
    writeln(parsed.value.httpPort, " ", parsed.value.logLevel);

    auto bad = fromJSON!Server(`{"db_host":"h","http_port":"many"}`);
    writeln("error at ", bad.error.path[]);
}
```

```[Output]
{"db_host":"localhost","http_port":8080,"log_level":"info"}
9 warning
error at .http_port
```

Explicit `@WireName` beats the type-level case policy, `whenDefault` omits the
empty `tags`, enums encode by name, decode restores the same value, and a type
mismatch reports a `$`-rooted path — all from one declaration, both directions.

### Design philosophy

From [`SPEC.md`][wired-spec] §3: a format is a bare marker type and

> "a new format is just a new type — anyone can add one; there is no central
> format registry."

Every attribute resolves exact-format-first (`@WireName!Json` beats
`@WireName!AnyFormat` beats the default), implemented once in `pickAttr`
(`policy.d:248`) and folded per (format, type) into a flat
`static immutable FieldPolicy[]` in a single CTFE pass (`policy.d:648-786`).
That table — plain data the codec consumes — is wired's proto-reified schema,
and the substrate a `Cli` format would build on.

---

## Schema model & bidirectionality

**SUPPORTED, one level deep.** Encode and decode read the _same_
`fieldPolicies!(Json, T)` table (`codec.d:675` vs `codec.d:1195`), so keys,
enum names, and converters cannot drift; per-axis directionality is deliberate
and documented (`WireSkip` encode-only, `WireInvalid`/`WireMatch` decode-only,
`@WireConvert` with `from = void` is serialize-only). Deterministic output
(declaration-order fields, sorted AA keys) and the `whenDefault`/missing-key
symmetry are designed-in round-trip properties.

**The gaps:** `FieldPolicy` carries no types, no nesting, and no documentation —
it describes one type's fields, not a schema tree; there is no `Schema!T` value
([tier 3][tiers]) and no format-neutral intermediate. Consequently the walk
itself (`decodeNative`/`encodeNative`, two ~150-line `static if` ladders,
`codec.d:403-545`/`codec.d:1008-1144`) is JSON-local and hand-written — a
second format must rewrite it, and the divergences below exist _because_ it is
hand-written. There is no round-trip predicate or property-test helper.

**D verdict:** [(b)][tags] — the flat-arena `SchemaNode[]` upgrade is mechanical
(model: [zio-schema][zio-schema]'s ADT, [facet][facet]'s `Shape`).

### Probe-verified spec divergences

Two places where the hand-written walk silently under-delivers the SPEC, kept
here as a live regression marker:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "wired_baseline_divergences"
    dependency "sparkles:wired" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/

import std.stdio : writeln;
import sparkles.wired;

enum Mode
{
    fastPath,
    slowPath,
}

struct SlotPolicy
{
    @WireCase!Json(CaseStyle.snakeCase, WireTarget.key) int[Mode] table;
}

struct WithStatic
{
    int[3] xyz;
}

void main()
{
    // SPEC §5.2 says the key policy recases AA keys: {"table":{"fast_path":1}}.
    writeln(toJSON(SlotPolicy([Mode.fastPath: 1])).value[]);

    // SPEC §4.3 mandates static-array support; PLAN M4 gates on it.
    writeln("static arrays encode: ", __traits(compiles, toJSON(WithStatic([1, 2, 3]))));
}
```

```[Output]
{"table":{"fastPath":1}}
static arrays encode: false
```

The policy layer resolves `WireTarget.key`/`.value` correctly and its unit
tests pass (`policy.d:541-574`) — but the codec only consults slot-targeted
policies for two narrow shapes (`codec.d:699-712`), so AA keys and composed
wrappers (`Nullable!(E[])`, `E[][]`) fall back to type-level policy: wrong
output, no error. Static arrays (`T[N]`) are specified with exact-length decode
(SPEC §4.3) but have no branch in the codec at all. Neither is tracked in
[open-issues][wired-issues].

## Naming, optionality & defaults

**SUPPORTED, unusually well-factored; no aliases, no provenance.**

- Renaming: `@WireName!F` per field/member; `@WireCase!F(style[, target])` per
  type with field-level override; explicit names are verbatim; resolved-name
  uniqueness is a compile-time assert (`policy.d:777-786`).
- Optionality splits into two independent knobs — `WireSkip {never, whenEmpty,
whenDefault}` (encode omission) and `WireInvalid {reject, useDefault}`
  (present-but-invalid decode) — more than most surveyed libraries expose.
  `whenDefault` compares against `T.init` including member initializers, which
  is exactly the value a missing key restores, so omission round-trips
  (SPEC §5.4). Null-aware types (`Nullable`, `Optional`, `Ternary`) distinguish
  JSON `null` from missing on decode; directly-nested null-aware wrappers are
  compile-time rejected because their empties would collide.
- **ABSENT:** aliases (read-many/write-one) and direction-split renames;
  `@WireDefault(expr)` (defaults come only from field initializers, and the
  decoding-vs-constructor [default channels][presence] are not separated);
  unset-tracking (the decode seen-mask exists but is local to
  `decodeStructNative`, `codec.d:677` — no `Decoded!T`-style provenance).

**D verdict:** [(a)][tags] for aliases and the default channels;
[(b)][tags] for provenance — and the [presence problem][presence] is the one
axis flagged across the corpus as not retrofittable.

## Sum types & discrimination

**PARTIAL — untagged only; the largest structural gap.** `SumType` decode tries
every variant in declaration order (`codec.d:789-826`) under a per-field
`@(WireMatch.first)` / `@(WireMatch.exactlyOne)` strategy. `exactlyOne` decodes
_every_ variant per value (O(variants), allocating ones included) and reports
"no variant matched" without the per-variant reasons the SPEC promises
(SPEC §"error reporting" vs `codec.d:823-824`). There is **no tagged
representation at all** — none of the [four standard encodings][sum-reprs], no
discriminator configuration, no inferred sentinels, no catch-all variant. The
SPEC is candid that overlapping variants are ambiguous "often not merely in
rare corners" and names `@WireConvert` to an explicit tagged shape as the
workaround. D `union` and `class` are unsupported (`codec.d:544`).

This blocks the CLI work directly: a subcommand _is_ an externally-tagged union
([argv as a codec][argv-codecs]), and the bespoke args engine had to invent its
own dispatch because wired has none.

**D verdict:** [(a)][tags] for the four representations; [(b)][tags] for
sentinel inference and the compile-time disjointness proof no surveyed library
offers.

## Transformations & validation

**Conversions SUPPORTED; validation ABSENT.** `@WireConvert!(to, from = void,
F = AnyFormat)` carries two aliases; the wire type is _inferred_ from `to`'s
return type (so generic lambdas work), failure is expressed by returning an
`Expected` (throwing is explicitly unsupported), and the ordering against other
policies is pinned (converter outermost to naming/repr, innermost to
`@WireOptional`). Asymmetric serialize-only converters are first-class.

- **PARTIAL:** the signature is bare `Wire → Domain` — no [presence][converters],
  no context, no sibling access, no chaining, and no compositional
  [adapter][converters] form (`@WireAs`).
- **ABSENT:** any refinement/constraint layer. The only checks are type checks
  (integral range, enum membership, float finiteness). Domain invariants live in
  converters (conflating representation with validation, and unable to name
  _which_ constraint failed) or outside the library. The CLI engine's
  `allowedValues` is a one-off reimplementation of this missing axis.

**D verdict:** [(a)][tags] for `@WireCheck` with a rich result protocol and
cross-field rules; [(b)][tags] for presence-carrying converters and `@WireAs`.

## Errors & context

**Errors SUPPORTED and strong on structure; fail-fast only; no context.**
`JsonError` is a copyable, GC-free value carrying stage, `$`-rooted path
(prepended lazily while unwinding — the success path pays nothing), target
type, actual JSON kind, and a value summary; everything is
`Expected!(T, JsonError)` with no throwing wrappers. That is stronger than
serde's default (which needs a wrapper crate for paths) and close to Effect's
`ParseIssue` minus the tree.

- **ABSENT:** accumulation — one error slot, first failure aborts
  (`codec.d:294`, `codec.d:327-342`); a config/form/CLI consumer cannot get
  "all six bad fields at once".
- **ABSENT:** runtime context. Options are compile-time template parameters
  (zero-cost, but per-call-site only); no `Ctx` flows through the walk, so
  nothing context-dependent (locale, versions, already-parsed globals) can
  reach a converter.

**D verdict:** [(a/b)][tags] — sink-based accumulation and a defaulted `Ctx`
parameter are both established sparkles shapes (`PrettyPrintOptions!Hook`).

## Metadata, derivations & extensibility

**Format genericity SUPPORTED at the policy layer; everything downstream
ABSENT.** A new format inherits the whole `@Wire*` vocabulary and resolvers —
that is genuinely reusable — but must hand-write its walk (see above). There is
**no metadata axis** (`@WireDoc`/`@WireExample`/`@WireDeprecated` do not exist;
all six attributes are wire-mechanical) and therefore **no derivations**: no
JSON Schema, no help text, no generators, no doc tables. The bespoke args
engine's entire 438-line help system is precisely a derivation wired cannot
host today. Unknown fields are silently skipped (cheap extent-hop) with no
forbid/preserve knob (open issue O10); streaming exists on encode only; every
decoded string allocates despite the arena supporting borrowed slices.

**D verdict:** [(a)][tags] for the metadata axis and `--help`/JSON-Schema folds
once the schema is reified; [(b)][tags] for `@WireExtra` preservation and
borrowed-string decode.

---

## What the bespoke CLI engine expresses that wired cannot

The `sparkles.core_cli.args` package (2.7 kLOC, landed with the
[core-cli subcommands reland][core-cli-spec]) is the measure of the `Cli`
format's requirements. Of its ~15 capabilities beyond wired's surface, the
audit splits:

- **General serde axes wired should host** (5): short/long _aliases_; the
  `required` spelling (wired inverts the default); _validation_
  (`allowedValues`); _presentation metadata_ (`description`, `placeholder`,
  `hidden`, view-file help sections); _unknown-token preservation_
  (`parseKnownCli` is the "preserve" answer wired lacks entirely).
- **Legitimately format-local** (10): positional-vs-option-vs-subcommand roles
  and ordering, counters (`-vvv`), greedy arrays with a stop rule, `--`
  handling, boolean surface (`--no-x`, `yes/no` vocabulary), short-option
  bundling, per-option value help (`--opt=?`), command identity/dispatch with
  `run` handlers — these need wired to _expose its resolved schema well enough_
  for a CLI backend to decorate, not to absorb them.

## Assessment

**Three structural strengths:** the format-generic policy layer reduced to
plain CTFE data; the GC-free path-carrying error value with `Expected`
everywhere; performance-consciousness without giving up declarativeness
(arena + extent-skip + CTFE-resolved field order, with a JSONTestSuite
conformance gate).

**Five biggest gaps versus the surveyed state of the art:** no tagged sum
representations; no metadata axis and therefore no derivations; no
validation layer; fail-fast-only single-slot errors; and a one-level,
type-free reification with a hand-written walk — the root cause of the
probe-verified divergences above. The full capability-by-capability delta is
in [comparison.md](./comparison.md#the-delta-table).

## Sources

- [`docs/specs/wired/SPEC.md`][wired-spec] · [`PLAN.md`][wired-plan] · [`open-issues.md`][wired-issues]
- `libs/wired/src/sparkles/wired/policy.d` — the `@Wire*` UDAs and CTFE resolvers
- `libs/wired/src/sparkles/wired/json/codec.d` — the derived JSON codec
- [`docs/specs/core-cli/SPEC.md`][core-cli-spec] — the bespoke args engine being re-expressed
- [`docs/specs/dman/command-schema.md`][command-schema] — the CLI-as-wired-format design
- Related: [comparison][comparison] · [concepts][concepts] · [argv as a codec][argv-codecs]

<!-- References -->

[wired-spec]: ../../specs/wired/SPEC.md
[wired-plan]: ../../specs/wired/PLAN.md
[wired-issues]: ../../specs/wired/open-issues.md
[core-cli-spec]: ../../specs/core-cli/SPEC.md
[command-schema]: ../../specs/dman/command-schema.md
[tiers]: ./concepts.md#the-three-tiers
[tags]: ./concepts.md#d-feasibility-tags
[presence]: ./concepts.md#the-presence-problem
[sum-reprs]: ./concepts.md#sum-type-representations
[converters]: ./concepts.md#converters-vs-adapters
[zio-schema]: ./zio-schema.md
[facet]: ./facet.md
[argv-codecs]: ./argv-codecs.md
[comparison]: ./comparison.md
[concepts]: ./concepts.md
