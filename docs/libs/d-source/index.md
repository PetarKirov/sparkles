# `sparkles:d-source`

Facts about D source text that need no semantic analysis, read with DMD's own
lexer. A build tool asks it which version identifiers a file can test, which
conditions a file builds from strings, and what a file imports, and gets the
answers the compiler would see, without running the compiler.

## What it reads

- **Tokens** (`sparkles.d_source.tokens`): `tokenize` returns a file's tokens
  as a kind, a text and a line, from `dmd:lexer`. Every string form, nested
  comment, `__EOF__` and shebang line is lexed as DMD lexes it. Lexing never
  fails: a malformed file yields the tokens DMD could read, and its compile
  reports the error.
- **Version facts** (`sparkles.d_source.mentions`): `scanSource` finds the
  identifiers a file names in `version (…)`, `debug (…)`, `version = …` and
  `debug = …`; every `mixin` or manifest constant whose string literals,
  joined, spell such a condition; every `mixin` that may import a module no
  declaration names; the module's name, its imports and its `unittest`
  blocks. `scanText` finds the same mentions in a file read as
  text, such as one under a string import root. `isVersionUses` resolves
  `sparkles.base.meta.isVersion` through a file's imports and returns each use
  with its argument.

The build graph uses these to prune the versions a dependency inherits and to
lint version tests ([build-graph D56](../../specs/build-primitives/build-graph/decisions.md#d56-planning-reads-d-source-with-dmd-s-lexer-and-parser-accepted)).

```d
import sparkles.d_source.mentions : scanSource;

const s = scanSource(`version (Trace) debug = Verbose;`);
assert(s.mentions[0].identifier == "Trace");
assert(s.mentions[1].identifier == "Verbose" && s.mentions[1].debug_);
```

## DMD's process-wide state

DMD's lexer keeps an identifier table and keyword globals for the whole
process, and neither is safe to touch from two threads at once. Every call
into DMD from this package runs inside `withDmdGlobals`
(`sparkles.d_source.dmd_globals`), which holds one lock and initializes the
globals on first use. `sparkles:dmd-fmt` and `sparkles:dmd-lsp` still keep
locks of their own: a process that links one of them must not lex through
both at once.
