/++
`sparkles:tui` — a full-screen, interactive terminal-UI library.

$(B Status: scaffolding.) The library's runtime, backend, input, colour,
layout, and widget modules are intentionally not written yet. The core
rendering architecture — a $(I line-diff) buffer of styled byte-lines versus a
$(I 2-D cell-grid) with per-cell diffing — is being decided by measurement, not
picked up front. The deciding evidence is the render-cost benchmark under
`libs/tui/bench/render/` (a standalone package with its own manifest, like
`libs/wired/bench`), driven by `sparkles:test-runner --bench --perf`.

The feature inventory, the delta from the existing `sparkles:core-cli`
substrate, and the open architectural questions live in the spec at
`docs/specs/tui/` (`index.md` + `PLAN.md`). Until the benchmark resolves the
rendering core, only this package skeleton and the benchmark harness exist.
+/
module sparkles.tui;
