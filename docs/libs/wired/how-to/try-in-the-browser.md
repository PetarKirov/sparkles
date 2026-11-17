# Try JSON, SDL and dub recipes in the browser

The playground below runs `sparkles:wired` itself, compiled to WebAssembly:
the same JSON and SDL readers and writers the library ships, and the dub
recipe schema (`sparkles:dub-manifest`) that Sparkles' tools and its Nix
evaluation read recipes with. Nothing is sent anywhere; the module runs in
this page.

<WiredPlayground />

## What each view shows

- **Document tree** parses the text and shows what the reader kept. For
  SDL, each tag with its line, its values and attributes, and its
  children; each value is its kind (`integer`, `string`, `dateTime`, …)
  and its canonical SDL spelling. For JSON, the value itself.
- **Canonical text** writes the document back: SDL in its canonical form,
  comments dropped; JSON indented by two spaces, members in source order.
- **dub recipe** decodes the text as a `dub.sdl` or `dub.json` and shows the
  recipe as the Nix module returns it: fields named as in D, empty ones
  left out. A recipe dub would reject is an error naming the line, the
  column and the reason, the same one `dub` tools in this repository
  report.

## Where the module comes from

The page loads `spk-wired.wasm`, built by `nix build .#wired-wasm` from
`libs/wired/wired-wasm` and checked against the same functions run
natively by `ci --check-wasm-modules`. Its single export, `spk_wired_run`,
takes one JSON request and writes one JSON response; the
[specification](../../../specs/wired/wasm/SPEC.md) describes both, and the
npm package `@sparkles-pkgs/wired` wraps the same module for JavaScript.
