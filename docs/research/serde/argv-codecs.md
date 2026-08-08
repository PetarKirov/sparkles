# argv as a codec (cross-language)

Can command-line parsing be a (de)serialization format — and can it run _backwards_, rendering a struct into the argv that would have produced it? Every ecosystem surveyed here answers the first question partially and the second one not at all; this deep-dive isolates the single structural reason why, and why D is the language where the answer changes.

| System                   | Language | Direction(s)                              | Subcommands                         | Link                           |
| ------------------------ | -------- | ----------------------------------------- | ----------------------------------- | ------------------------------ |
| `clap` (derive)          | Rust     | argv → struct                             | Yes — `#[command(subcommand)]` enum | [clap derive ref][clap-derive] |
| `serde_args`             | Rust     | argv → any `Deserialize`                  | Yes — enums are subcommands         | [docs.rs][serde-args]          |
| `clap-serde`             | Rust     | config → clap `Command` (**the inverse**) | n/a — it _defines_ them             | [repo][clap-serde]             |
| `facet-args`             | Rust     | argv → any `Facet` struct                 | **No** (documented)                 | [docs.rs][facet-args]          |
| `optparse-applicative`   | Haskell  | argv → `a`                                | Yes — `CmdReader`                   | [Hackage][opa]                 |
| `reverse_argparse`       | Python   | parser + `Namespace` → argv               | Inherits `argparse` subparsers      | [docs][revarg]                 |
| `argunparse`             | Python   | `dict` → argv (approximate)               | No                                  | [PyPI][argunparse]             |
| `yargs-unparser`         | JS       | `argv` object → argv (approximate)        | Partial                             | [npm][yargs-unparser]          |
| `sparkles.core_cli.args` | D        | argv → struct, plus `--help`              | Yes — `@Subcommands`                | [wired baseline][baseline]     |

> [!NOTE]
> This page surveys argv **as a codec**. The general (de)serialization axes it leans on — naming, optionality, sum-type discrimination, validation, presentation metadata — are defined once in [`concepts.md`][concepts], and the split between _general serde axes_ and _format-local CLI axes_ for Sparkles' own shipped engine lives in [`wired-baseline.md`][baseline].

---

## Overview

### The question

A CLI parser and a deserializer do the same job: take an external, untyped encoding and produce a typed value. `clap`'s derive macro and `serde`'s derive macro even look alike. So the recurring idea — visible in `serde_args`, `facet-args`, and half a dozen abandoned crates — is to make argv _one more format_ behind a general (de)serialization interface, and get CLI parsing for free from a data model built for JSON.

It half-works, and the reason it only half-works is worth stating precisely. Serde's classification of formats is binary: **self-describing** (JSON, YAML, CBOR — `deserialize_any` works, you can parse without knowing the target type) versus **non-self-describing** (bincode, postcard — a bare byte stream whose meaning is entirely the schema). Argv is neither. `--name` _is_ a key, but the token after it is untyped text whose meaning depends on the declared field type, and a bare `foo` carries no key at all. Argv sits in a third category serde has no name for: **key-describing but type-blind**. Forcing it into either bucket is where the crates that tried start losing features.

`serde_args` is the honest experiment. It genuinely parses argv into any `Deserialize` type, and its own documentation opens with the concession ([docs.rs][serde-args]):

> _"not every command line interface can be represented using it"_

and explains the exclusions structurally rather than as a to-do list: `#[serde(flatten)]`, internally-tagged and untagged enums, and `#[serde(other)]` are all unsupported because they _"require a self-describing deserializer"_ and _"the format defined by `serde_args` is not self-describing."_ Optional positional parameters are _"not supported at all"_ — the format _"requires that all positional arguments … be required arguments."_

### Why nobody has the render half

The second question — struct → argv — has no serious implementation in any surveyed ecosystem. `clap` has no `to_args`. `optparse-applicative` has no unparser (a sweep of Hackage, Hoogle for `unparse`, the upstream issue tracker, and the surrounding ecosystem — `optparse-generic`, `optparse-simple`, `options`, `cmdargs`, `harg`, `barbies` — turns up nothing that renders argv from a value). `serde_args` and `facet-args` are parse-only by construction.

The obstruction is one line of type signature. In `optparse-applicative` the parser is a GADT whose combining constructor is ([`Options.Applicative.Types`][opa-types]):

```haskell
MultP :: Parser (x -> a) -> Parser x -> Parser a
```

The **structure is inspectable** — you can enumerate every `Option x` in the tree without running anything. The **function is not**. Given a finished value of type `a`, nothing in the type connects any particular `Option` to any particular part of it. In `Config <$> strOption (long "host") <*> option auto (long "port")` you can see two options, and you can see a `Config`, and there is no arrow anywhere from `--host` to `configHost`.

Every partial solution that exists supplies the missing link **nominally**, and their limitations are exactly proportional to how weak the nominal link is:

- **`reverse_argparse`** (Python) requires _both_ halves — it takes _"a `argparse.Namespace` of parsed command line arguments, along with the `argparse.ArgumentParser` that generated it, and then unparse[s] everything into the exact list of command line arguments that was used"_ ([docs][revarg]). The nominal link is `action.dest`, the string naming the `Namespace` attribute. It documents its own approximation: it _"will take into consideration any default values, along with any transformations that have been made after argument parsing (e.g., path resolution, etc.)"_ — i.e. post-parse mutation makes reconstruction best-effort, and it must compare against `default` to decide whether to emit a flag at all.
- **`argunparse`** (Python) and **`yargs-unparser`** (JS) drop the parser entirely and turn a dict's keys into flags. Both are explicitly approximate: no arity, no counters, no knowledge of which spellings the parser would have accepted.
- **`clap`** (Rust) has the mapping at compile time and **throws it away** — `clap_derive` generates parse code from the struct and keeps nothing that runs the other way.

The result generalizes cleanly:

> **Unparsing works exactly when the option is bound to a named slot, and is impossible when it is bound through an anonymous function.**

That is the whole finding, and it is why this is a D opportunity rather than a D chore: an option UDA on a **named struct field** is a named slot by construction, in both directions, at compile time. What `optparse-applicative` can never recover from an opaque `x -> a`, D reads back with `__traits(identifier, T.tupleof[i])`:

```d
struct Opts
{
    @Option("host|H", "server host") string   host = "localhost";
    @Option("port|p", "server port") ushort   port = 8080;
    @Option("verbose|v", counter: true) int   verbose;
    @Argument                        string[] files;
}

// All three are the SAME compile-time walk over Opts.tupleof:
Expected!(Opts, CliError) parseCliArgs(Opts)(scope const(char)[][] argv);
void                      renderCliArgs(Opts, W)(in Opts o, ref W sink);  // the missing half
void                      formatHelp(Opts, W)(ref W sink);
```

Two caveats keep this honest, and both are developed below: `value == T.init` is only a proxy for "not supplied" (see [defaults](#naming-optionality--defaults)), and spelling equivalences mean the law is **`parse(render(x)) == x` only** — never `render(parse(s)) == s`.

---

## How the parse-only state of the art works

### clap-derive, read as an argv codec

`clap`'s derive layer is four traits: `Parser` (top level), `Args` (a reusable, flattenable set), `Subcommand` (an enum of commands), and `ValueEnum` (a fixed value set that both validates and self-documents in `--help`).

```rust
#[derive(Parser)]
#[command(name = "app", version, about, rename_all = "kebab-case")]
struct Cli {
    /// Increase logging verbosity.
    #[arg(short, long, action = ArgAction::Count)]
    verbose: u8,                                    // -vvv → 3

    #[arg(long, value_parser = clap::value_parser!(u16).range(1..=65535))]
    port: u16,

    #[arg(long, num_args = 1..=3, value_delimiter = ',')]
    files: Vec<PathBuf>,                            // --files a,b,c

    #[arg(long, conflicts_with = "quiet", requires = "port")]
    loud: bool,

    #[arg(long, global = true)]                     // inherited by all subcommands
    color: Option<ColorChoice>,

    #[command(subcommand)]
    cmd: Command,
}
```

The piece most worth copying is **type-directed inference**: the field's D-equivalent-of-`Deserialize` shape decides its CLI behaviour with no attribute at all.

| Field type          | Inferred behaviour                   |
| ------------------- | ------------------------------------ |
| `bool`              | flag, `ArgAction::SetTrue`           |
| `Option<T>`         | optional, may be absent              |
| `Option<Option<T>>` | optional flag with an optional value |
| `Vec<T>`            | `ArgAction::Append`, repeatable      |
| `Option<Vec<T>>`    | repeatable and optional              |
| `T`                 | required                             |
| `u8` + `Count`      | occurrence counter                   |

Three further mechanisms carry weight for a codec design:

- **`ArgAction`** — _"Behavior of arguments when they are encountered while parsing"_ ([docs.rs][clap-action]): `Set`, `Append`, `SetTrue`, `SetFalse`, `Count`, `Help`/`HelpShort`/`HelpLong`, `Version`. This is **repetition semantics**, and it has no slot in any fixed data model: `Append` looks like a `seq`, but a `seq` in JSON is one bracketed value while in argv it is _N_ separate occurrences, and no data model distinguishes `--x 1 --x 2` from `--x [1,2]`.
- **`num_args`** — arity _per occurrence_ (`0`, `1`, `1..=3`, `0..`), independent of `ArgAction`. How many tokens an option eats is a parsing decision the data model has no channel to express.
- **Doc comments become help.** `///` on a field becomes `Arg::help`; a blank-line-separated second paragraph becomes `long_help`.

The constraint vocabulary (`conflicts_with`, `requires`, `ArgGroup`, `required_unless_present`) is where the derive layer's compile-time knowledge runs out. `clap` handles a `conflicts_with = "quiet"` naming a nonexistent argument as a programming error discovered by _running_ the CLI: the docs for `Command::debug_assert` say the method exists to _"Catch problems earlier in the development cycle,"_ because _"Most error states are handled as asserts under the assumption they are programming mistake and not something to handle at runtime"_ ([docs.rs][clap-debug-assert]) — and even then it warns that it _"will not help with asserts in `ArgMatches`, those will need exhaustive testing of your CLI."_ A whole class of CLI bug is, in Rust, a test-coverage problem.

### optparse-applicative's inspectable parser

Haskell's answer is the opposite architecture: the parser is a **value you can walk without running**. `Parser a` is _"an option parser returning a value of type `a`"_ with five constructors — `NilP`, `OptP`, `MultP`, `AltP`, `BindP` — and `OptReader` has four (`OptReader`, `FlagReader`, `ArgReader`, `CmdReader`) covering value options, flags, positionals and subcommands ([`Options.Applicative.Types`][opa-types]).

```haskell
mapParser     :: (forall x. ArgumentReachability -> Option x -> b) -> Parser a -> [b]
treeMapParser :: (forall x. ArgumentReachability -> Option x -> b) -> Parser a -> OptTree b
evalParser    :: Parser a -> Maybe a     -- the default value, if every option has one
```

These two rank-2 traversals are the **entire** help, usage and completion mechanism. A rank-2 function visits every `Option x` regardless of what `x` is, and `OptTree` preserves the `MultP`/`AltP` nesting so a usage line can render `(--a | --b) --c` rather than a flat list. `Completer` rides along inside `CReader`.

The cliff is `BindP`: the `Parser` has been a `Monad` since 0.13, and `BindP :: Parser x -> (x -> Parser a) -> Parser a` hides its right branch behind a function that is invisible until `x` is known. Any parser using it is only partially inspectable — its later options cannot appear in `--help` or completions. This is [Rendel and Ostermann's second objection to `Monad`][invertible] observed in production code, not in a paper.

---

## Schema model & bidirectionality

The ten axes below are the ones a fixed 29-type data model cannot host. They are the reason `serde_args` exists as a curiosity rather than as anyone's CLI framework, and the checklist any argv codec must answer.

| #   | Axis                                                                   | Why a fixed data model can't host it                                          |
| --- | ---------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| 1   | **Occurrence counting** (`-vvv` → 3)                                   | the model visits a field once; "this key appeared N times" is not expressible |
| 2   | **Arity / `num_args` ranges**                                          | token consumption is a parser decision with no data-model channel             |
| 3   | **Cross-field constraints** (`conflicts_with`, `requires`, `ArgGroup`) | serde has no cross-field vocabulary anywhere                                  |
| 4   | **Global args inherited by subcommands**                               | enum decoding is strictly nested: tag consumed, then variant content          |
| 5   | **Optional positionals / default subcommand**                          | `serde_args` documents both as unsupported                                    |
| 6   | **Positional-vs-named at all**                                         | struct keys are strings; a positional has no key                              |
| 7   | **Parser modes** (`--`, interspersed flags, `trailing_var_arg`, `-1`)  | pure parser configuration, no data-model representation                       |
| 8   | **Layered sources** (default → config → env → argv)                    | one `deserialize` call has one input; merging happens outside                 |
| 9   | **Help generation**                                                    | needs doc comments + constraint metadata; both are discarded                  |
| 10  | **`value_parser` ranges and custom validation**                        | validation is not a (de)serialization concern in serde's model                |

`facet-args` is the more honest attempt precisely because it refuses the framing: rather than squeezing argv into a fixed model, it **extends the reflection vocabulary** with `args::positional`, `args::named`, `args::short`, and `args::counted`, so axes 1 and 6 become first-class. It is still explicitly _"CLI argument parsing (WIP)"_ ([docs.rs][facet-args]) and has two documented failures that map straight onto the table: it is _"always parsing to a struct (not an enum, vec etc.)"_ — no subcommands — and positional `Vec` fields are greedy, where _"Positional args of type `Vec` (or anything that has a `Def::List`) will soak up all the positional arguments — if followed by `positional` arguments of type `String` for example, those will never get filled"_ (axis 2 and axis 5 colliding). See [`facet.md`][facet] for the reflection model itself.

`clap-serde` is worth naming because it is a common source of confusion: it deserializes a **clap `Command` definition** from TOML/JSON/YAML. That is config-driven CLI _definition_, not argv-as-serde — and its existence is evidence for the thesis, since clap's model is richer than serde's, so the natural direction of travel is serde → clap-config, never argv → serde.

**D verdict: (b), and the design instruction it implies decides the whole project.** Do not model argv as "just another format over a fixed data model"; model it as a format that **contributes its own vocabulary to an open model**. Once the model is open, axes 1, 2, 6 and 7 are just UDAs the argv codec reads and every other codec ignores — the "data model can't host it" problem is a consequence of Rust's fixed 29 types, not a law. Axis 8 argues for a specific architecture worth committing to up front: decode each source into a _partial_ struct where every field carries an unset state, then merge by precedence — that decision dictates the codec's output type. Bidirectionality is where the real leverage is: rendering a struct back to a minimal command line prints the command that reproduces a run, generates completions, builds child-process invocations, and makes round-trip testing possible. Nobody else ships it. See [`concepts.md#d-feasibility-tags`][tags].

---

## Naming, optionality & defaults

Argv naming is unusual in carrying **two** spellings per slot (`-p` / `--port`) plus, in most engines, an alias list. Sparkles' shipped engine folds both into one string split on `|` — `@Option("L|log-level")`, where a one-character name renders as `-x` and a longer one as `--xx` ([`help_formatting.d`][args-help]). Aliases are the one CLI naming axis that is arguably a _general_ serialization feature rather than a CLI-local one, since a JSON codec accepting historical key spellings wants exactly the same thing.

Optionality has an inverted default relative to a document format. `clap` and Sparkles' `@Option(required: true)` treat a field as optional-with-default unless marked required; a serde-style model treats every field as required unless marked optional. Same information, opposite polarity — a shared vocabulary must pick one spelling and desugar the other.

Defaults are where the render direction first gets hard. `value == T.init` is only a **proxy** for "the user did not supply this". A CLI that renders `--port 8080` because the user explicitly typed it, and omits it when the default happened to be 8080, needs a per-field `wasSet` bitmask carried alongside the struct — a `ulong` for up to 64 fields. `reverse_argparse` documents the same problem from the other end: it must compare each attribute against `default` to decide whether to emit a flag, and cannot tell an explicit default from an absent one.

**D verdict: (a) for naming and optionality — an alias list and a required/optional marker are plain UDA data over a `.tupleof` walk. (b) for faithful default handling**, because the `wasSet` bitmask changes the parse function's return type and has to be threaded through merge and render. Worth deciding before any code, not after.

---

## Sum types & discrimination

Subcommands are argv's sum type, and they discriminate the way an **externally tagged** enum does: the first bare word selects the branch, and everything after it is decoded in that branch's namespace. That is the one enum representation that works without a self-describing format, which is why `serde_args` can support subcommands at all while it cannot support `untagged` or internally-tagged enums.

Two features push past what a plain tagged union expresses, and both appear in every real CLI:

- **Command identity is richer than a type.** A branch has a `name`, an `aliases[]` list, and possibly an `isDefault` marker meaning "the parent may run with no subcommand at all" ([`internal.d`][args-internal]). A `SumType` has variant _types_ — no names, no aliases, no default variant.
- **Global arguments cross the branch boundary.** `--color` declared at the top level must keep claiming tokens that appear _inside_ the selected subcommand's region. Serde's nested decoding has no mechanism for an outer level to stay live once the tag is consumed; `optparse-applicative` handles it because `CmdReader` is just another `Option` in a tree the outer parser still owns.

**D verdict: (b).** A tagged union over per-subcommand structs with a CTFE-built name → branch switch covers identity, aliases and the default branch; rendering picks the active branch and prefixes its verb. Global args are tractable for the same reason `flatten` is tractable in D: the full key set across the subcommand boundary is compile-time known, so the codec can keep the outer key set live while decoding the inner one. Neither is free — both are CTFE work over the whole type graph rather than a per-field decision. Sparkles' engine already ships this shape (`@Subcommands` plus nested `@Command` structs), exercised by five real CLI reconstructions under `libs/core-cli/examples/cli/` ([`git.d`][ex-git], [`docker.d`][ex-docker], [`gh.d`][ex-gh], [`dub.d`][ex-dub], [`systemctl.d`][ex-systemctl]).

---

## Transformations & validation

Two distinct things travel under one name here. **Transformation** is `--port 8080` becoming a `ushort` — a per-field parse from text, which every codec has. **Validation** is `.range(1..=65535)`, `allowedValues`, and the constraint graph (`conflicts_with`, `requires`, `ArgGroup`), and it is a layer serde deliberately does not have; the Rust ecosystem bolts it on with separate `validator`/`garde` derives that run after deserialization.

`clap`'s `value_parser` fuses the two, which is ergonomic and costs it the schema: a `value_parser` is an opaque function, so `--help` cannot describe what it accepts beyond a hand-written string. This is the general trap — **attributes as data, not function pointers** — and it applies with force to argv, because argv is the format where the schema is _rendered to the user_ as the primary artifact.

The cross-field constraint graph is the axis with the sharpest D story. `@Conflicts("quiet")` naming a field that does not exist is, in `clap`, a runtime panic in debug builds discovered by exhaustive CLI testing. In D the codec sees every field of the type simultaneously, so the same mistake is a `static assert` with a readable message at the point of declaration.

**D verdict: (a) for the constraint graph — a genuine, demonstrable advantage over `clap`, not a parity feature.** Verifying that every name mentioned in a conflicts/requires edge resolves to a real field, and that the resulting graph is consistent, is a CTFE walk over `.tupleof` with no runtime cost. Value-space constraints (`allowedValues`, numeric ranges) are **(a)** as long as they stay declarative data the help renderer can read back; the moment a constraint becomes a lambda it is **(c)** and `--help` goes blind. Keep them as data.

---

## Errors & context

Argv errors are unusual in the survey because the error _is_ the user interface. A JSON codec's error is read by a developer with the input file open; a CLI's error is read by someone who typed one wrong word, and the expected response is a suggestion plus the relevant fragment of `--help`.

That difference has not translated into richer error _types_. Sparkles' shipped engine models the failure as `CliError { kind (parse|help), message, help, exitCode }` ([`error.d`][args-error]) — a flat string message with **no path**, which is strictly weaker than a document codec's path-carrying error. The `kind` field carrying `help` is itself a tell: `--help` is not an error, but there is nowhere else to put "stop and print this," so the error type absorbs a control-flow signal.

Two structural notes:

- **Accumulation matters more here than elsewhere.** Serde is fail-fast and single-error by design; for argv, reporting only the first of three bad flags means three round trips through the user's shell history.
- **Unknown-token passthrough is a first-class mode, not an error.** A wrapper CLI needs "parse what you recognize, hand me the rest" — Sparkles spells it `parseKnownCli`/`keepUnknown` ([`internal.d`][args-internal]). That is the _preserve_ answer to unknown fields, which most document codecs implement as reject-or-drop and nothing else.

**D verdict: (b), and thinly.** The error model is not an argv-specific problem — it is the general path-carrying, accumulating error design applied to a format whose "path" is short (a flag name, a subcommand chain, a positional index). The finding here is an _absence_: nothing in the argv literature pushes error design forward, and the CLI engine should inherit whatever the general codec settles on rather than keep its own weaker type.

---

## Metadata, derivations & extensibility

This is the dimension where argv is not a peer format but the extreme case. For JSON, presentation metadata is optional garnish. For argv, `--help` **is the schema, rendered** — and it is generated from exactly the material a conventional codec discards: doc comments, placeholders, section groupings, hidden flags, enumerated value sets, and default values.

`optparse-applicative` is the design to learn from: `mapParser`/`treeMapParser` mean help, usage and completions are not special-cased features but three **derivations over one inspectable structure**. The structure is walked; the rendering is a fold. When `BindP` makes part of the structure uninspectable, all three derivations degrade together — proof that they really are one mechanism.

Sparkles' engine reaches the same place from the other side: its help layer consumes `description`, `shortDescription`, `placeholder`, `usage`, `epilog`, `sections`, `helpSections` (string-imported view files) and `viewsRoot` ([`uda.d`][args-uda]), plus `hidden` on commands, options and arguments. Per-option value help — `--opt=help`, `--opt=?`, `--opt?` rendering a screen that enumerates enum members, boolean spellings and `allowedValues` — is a derivation over the resolved schema, and it only works because those constraints are declarative data rather than functions.

The generalization worth carrying forward: an argv codec needs a **format-neutral intermediate** that both the parse and render directions and the help renderer agree on. [`effect-schema.md`][effect-schema]'s `toCodecStringTree` is the cleanest statement of it in the survey — a string-tree IR derived from the schema, used for rendering rather than for decoding. That is precisely the shape `--help`, usage lines and completions all want.

**D verdict: (a).** `__traits(docComment)` supplies the prose that Rust's macros cannot see (they receive tokens, not semantics), UDAs supply defaults, ranges and enumerated values, and `sparkles:ui` already renders the tables. Help, usage, per-option value help, completions and the render direction become **five folds over one `.tupleof` walk** — the same walk that parses. The rule that makes it work is the one from the validation section: attributes as data, never function pointers.

---

## Strengths

- **The type is the interface.** One struct declaration yields parsing, help, usage and — in the D formulation — rendering, with no duplicated definition to drift.
- **Type-directed inference removes most attributes.** `bool` means flag, `Vec<T>` means repeatable, `Option<T>` means optional; `clap` shows a whole CLI declared with almost no explicit configuration.
- **Doc comments as help** puts the documentation where the maintainer already writes it, and keeps it adjacent to the field it describes.
- **Subcommands map exactly onto tagged unions**, the one sum-type representation that needs no self-describing input — the argv shape and the codec shape genuinely coincide here.
- **Help/usage/completions are derivations, not features.** `optparse-applicative` demonstrates that one inspectable structure plus a traversal yields all three, so they cannot fall out of sync with the parser.
- **Bidirectionality has real, unserved uses**: printing the command that reproduces a run, generating completions, constructing child-process invocations, and property-testing the parser against its own renderer.

## Weaknesses

- **Argv is key-describing but type-blind**, a category no existing codec taxonomy names — so any design that inherits a self-describing/non-self-describing split inherits the wrong split.
- **Ten CLI axes have no home in a fixed data model** (the table above), and they are disproportionately the ones that make a CLI good rather than merely functional.
- **Constraint checking is a runtime concern everywhere it exists.** `clap` turns a typo in `conflicts_with` into a debug-build panic found by testing.
- **The render direction is lost at the derive boundary** in every parse-only system: the struct-field ↔ flag mapping exists at compile time and is discarded.
- **Canonicalization has no canonical answer.** `--port 8080`, `--port=8080` and `-p8080` parse identically; a renderer must pick one, so `render(parse(s)) == s` is simply false.
- **Explicit-vs-default is not recoverable from the value alone** — every unparser in the survey documents this, and none solves it.
- **Layered sources sit outside the codec.** Config-file/env/argv precedence needs a partial-value representation and a merge pass that no single `deserialize` call provides.

---

## Key design decisions and trade-offs

| Decision                                                                   | Rationale                                                                                                          | Trade-off                                                                                                            |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------- |
| Model argv as a format contributing vocabulary to an **open** model        | The ten unhostable axes are artifacts of a fixed type list, not of argv                                            | Every codec must tolerate UDAs it does not understand; "one data model" stops being a single closed enumeration      |
| Type-directed inference first, attributes only for the rest (`clap`)       | Most fields need no configuration; the declaration stays readable                                                  | Inference is invisible — changing `T` to `Option<T>` silently changes the CLI contract                               |
| Attributes as **data**, never function pointers                            | `--help`, per-option value help and completions are folds over the same data; a lambda is opaque to all three      | Constraints must be expressible declaratively; genuinely custom validation moves outside the schema                  |
| Subcommands as an externally tagged union with a CTFE name → branch switch | The only tagged representation that works without self-describing input; matches argv's actual grammar             | Aliases, hidden commands and a default branch are extra metadata a bare `SumType` does not carry                     |
| Check the constraint graph at **compile time**                             | A `conflicts_with` naming a nonexistent field is a declaration error, not a runtime state                          | Requires the codec to see the whole type at once — impossible for a token-level macro, natural for CTFE              |
| Carry a `wasSet` bitmask beside the parsed struct                          | Distinguishes an explicitly-passed default from an absent one; required for faithful rendering and source layering | Changes the parse function's return type and propagates through merge and render — decide before writing code        |
| State the round-trip law as `parse(render(x)) == x` only                   | Spelling equivalences make the other direction false by construction                                               | The law is quotiented by an equivalence, so property tests must compare values, never strings ([theory][invertible]) |
| Let the CLI error type inherit the general codec's path-carrying error     | Nothing argv-specific improves on it, and the current flat-string form is strictly weaker                          | `--help` is a control-flow signal currently smuggled through the error type; it needs a separate channel             |

---

## Sources

- [clap derive reference — the four traits, type-directed inference, doc-comment help][clap-derive]
- [`clap::ArgAction` — repetition semantics (`Set`/`Append`/`Count`/`SetTrue`/…)][clap-action]
- [`clap::Command::debug_assert` — constraint checking as a debug-build assert][clap-debug-assert]
- [`serde_args` — argv into any `Deserialize`, and its documented limits][serde-args]
- [`clap-serde` — the inverse direction: a clap `Command` deserialized from config][clap-serde]
- [`facet-args` — reflection-vocabulary extension; no subcommands, greedy `Vec` positionals][facet-args]
- [`facet` — the reflection model `facet-args` builds on][facet-repo]
- [`optparse-applicative` on Hackage][opa] · [`Options.Applicative.Types` — the `Parser` GADT, `mapParser`/`treeMapParser`][opa-types]
- [`reverse_argparse` — parser + `Namespace` → argv, and its best-effort caveat][revarg]
- [`argunparse` (Python)][argunparse] · [`yargs-unparser` (JS)][yargs-unparser]
- [Serde data model — the 29 types and the self-describing split][serde-data-model]
- Sparkles' shipped engine: [`args/uda.d`][args-uda] (vocabulary) · [`args/internal.d`][args-internal] (parser) · [`args/help_formatting.d`][args-help] (rendering) · [`args/error.d`][args-error]
- Example CLI reconstructions: [`git.d`][ex-git] · [`docker.d`][ex-docker] · [`gh.d`][ex-gh] · [`dub.d`][ex-dub] · [`systemctl.d`][ex-systemctl]
- Related: [survey index][index] · [concepts][concepts] · [comparison][comparison] · [wired baseline][baseline] · [serde][serde] · [facet][facet] · [Effect Schema][effect-schema] · [invertible syntax][invertible] · [Haskell codecs][haskell]

<!-- References -->

[clap-derive]: https://docs.rs/clap/latest/clap/_derive/index.html
[clap-action]: https://docs.rs/clap/latest/clap/enum.ArgAction.html
[clap-debug-assert]: https://docs.rs/clap/latest/clap/builder/struct.Command.html#method.debug_assert
[serde-args]: https://docs.rs/serde_args/latest/serde_args/
[clap-serde]: https://github.com/aobatact/clap-serde
[facet-args]: https://docs.rs/facet-args/latest/facet_args/
[facet-repo]: https://github.com/facet-rs/facet
[opa]: https://hackage.haskell.org/package/optparse-applicative
[opa-types]: https://hackage.haskell.org/package/optparse-applicative/docs/Options-Applicative-Types.html
[revarg]: https://reverse-argparse.readthedocs.io/en/latest/
[argunparse]: https://pypi.org/project/argunparse/
[yargs-unparser]: https://www.npmjs.com/package/yargs-unparser
[serde-data-model]: https://serde.rs/data-model.html
[args-uda]: ../../../libs/core-cli/src/sparkles/core_cli/args/uda.d
[args-internal]: ../../../libs/core-cli/src/sparkles/core_cli/args/internal.d
[args-help]: ../../../libs/core-cli/src/sparkles/core_cli/args/help_formatting.d
[args-error]: ../../../libs/core-cli/src/sparkles/core_cli/args/error.d
[ex-git]: ../../../libs/core-cli/examples/cli/git/git.d
[ex-docker]: ../../../libs/core-cli/examples/cli/docker/docker.d
[ex-gh]: ../../../libs/core-cli/examples/cli/gh/gh.d
[ex-dub]: ../../../libs/core-cli/examples/cli/dub/dub.d
[ex-systemctl]: ../../../libs/core-cli/examples/cli/systemctl/systemctl.d
[index]: ./index.md
[concepts]: ./concepts.md
[tags]: ./concepts.md#d-feasibility-tags
[comparison]: ./comparison.md
[baseline]: ./wired-baseline.md
[serde]: ./serde.md
[facet]: ./facet.md
[effect-schema]: ./effect-schema.md
[invertible]: ./invertible-syntax.md
[haskell]: ./haskell-codecs.md
