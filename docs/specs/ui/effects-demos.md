# `EFX`/`IMG` acceptance demos

Every feature in [effects.md](./effects.md) that a person can look at, and the
command that shows it. Each one is runnable from a clean checkout inside
`nix develop`, and each says what you should see — so a reviewer can accept or
reject it without reading the diff.

Two conventions:

- A GUI demo runs under `xvfb-run` so it needs no display, and writes a PNG.
  Drop the `xvfb-run` and the capture variable to watch it live instead.
- A terminal demo writes ANSI to stdout. Pipe it to `less -R`, or run the
  binary without `--render` for the interactive version.

Build once: `dub build :ui-gallery && dub build :hue`.

## Images (`IMG1`–`IMG5`)

| #   | What it shows                                                             | Command                                                                                            | Expected                                                                                                                                |
| --- | ------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | An image lays out as an ordinary box, and a cell grid degrades it visibly | `dub run :ui-gallery -q -- --render-plain --page primitives`                                       | An `image` row whose specimen reads `[a colo]` — the alt text, bracketed, truncated to the 8×2 cells the image's pixel size resolved to |
| D2  | The same handle drawn as real pixels on the GPU                           | `xvfb-run -a env UIG_SHOT=/tmp/img.png ./apps/ui-gallery/build/ui-gallery --gui --page primitives` | `/tmp/img.png` shows a colour-swatch image where the terminal showed `[a colo]`                                                         |
| D3  | `contain` preserves aspect; an unregistered handle falls back             | `IMGSHOT=/tmp/fit.png xvfb-run -a dub run --single docs/specs/ui/demos/imgshot.d`                  | Three panels: intrinsic size, a 40×12 box letterboxed, and `[not re]` for a handle nothing registered                                   |

## The bracket and tier 0 (`EFX1`–`EFX10`, `EFX24`)

| #   | What it shows                                                                           | Command                                             | Expected                                                                                                                                                                               |
| --- | --------------------------------------------------------------------------------------- | --------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D4  | Tier-0 effects running **in a terminal** — the claim `EFX24` exists to make falsifiable | `dub run :ui-gallery -q -- --render --page effects` | Five panels of identical widgets: `none` plain, `scanlines` with alternating darkened rows, `phosphor` green, `dim` uniformly darker, `spectrum` a 24-bit hue sweep across the columns |
| D5  | Nesting composes with ancestors rather than replacing them (`EFX2`)                     | same as D4, scroll to "nesting · dim inside dim"    | The inner panel is visibly darker than the outer one — it took both                                                                                                                    |
| D6  | A bracket never moves anything (`EFX6`)                                                 | `dub test :ui -- -i "ui.displayList.effect"`        | Frames identical with and without the effect; the op stream is the plain one plus exactly two ops                                                                                      |

## Tier 1, the registry and theming (`EFX11`–`EFX19`)

| #   | What it shows                                          | Command                                                                                                                             | Expected                                                                                                                                                     |
| --- | ------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| D7  | The same page on the GPU: tier 0 **and** tier 1        | `xvfb-run -a env UIG_SHOT=/tmp/fx.png ./apps/ui-gallery/build/ui-gallery --gui --page effects --window-width 60 --window-height 70` | The four tier-0 panels as in D4, plus a `curvature` panel whose text and borders visibly bow — rendered to a texture and warped                              |
| D8  | The tier boundary from the other side                  | D7's capture, "tier 1" section; then D4's terminal output                                                                           | The window says "this target renders the bracket to a texture"; the terminal says it paints unaffected. Same widget, same id, two declared answers (`EFX12`) |
| D9  | A theme rebinding built-ins to nothing (`EFX16`)       | `UIG_EFFECTS=off dub run :ui-gallery -q -- --render --page effects`                                                                 | All four panels identical to `none`. **No view changed** — the widgets still name the same ids                                                               |
| D10 | Every built-in ships both halves of its twin (`EFX13`) | `dub test :ui -- -i "ui.effect"`                                                                                                    | `eachCarriesBothHalvesOfItsTwin` passes: a D function and a GLSL artifact per built-in, each declaring the wrapper's signature                               |
| D11 | A missing effect cannot take a frame down (`EFX17`)    | `dub test :ui-tui -- -i "tier0EffectLandsInTheTerminal"`                                                                            | With no registry bound, the same op stream paints the subtree unaffected instead of failing                                                                  |

## The CRT (`EFX21`–`EFX23`)

| #   | What it shows                                               | Command                                                                                                                    | Expected                                                                                                                 |
| --- | ----------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ | ---------- |
| D12 | The focus halo outlines what was actually painted (`EFX23`) | `xvfb-run -a env HUE_GUI_SCREENSHOT=/tmp/halo.png HUE_GUI_PICKER= HUE_GUI_CRT=1 ./apps/hue/build/hue view README.md --gui` | The halo sits tight on the file picker's border — from the rect the paint site recorded, with no second layout per frame |
| D13 | `ui-app` grew no post-process bracket (`EFX22`)             | `grep -rniE "postprocess                                                                                                   | postpass" libs/ui-app/src`                                                                                               | No matches |

## Regression guards worth running

| #   | What it guards                                                                  | Command                                                        |
| --- | ------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| D14 | The op stays inside its 64-byte budget (`IMG1`)                                 | `dub test :ui -- -i "ui.canvas"`                               |
| D15 | The scissor box clamps to its target, not to a sentinel that casts to `int.min` | `dub test :ui-raylib -- -i "scissorBox"`                       |
| D16 | Every `WidgetKind` has a catalogue specimen                                     | `dub test :ui-gallery -- -i "primitivesCoversEveryWidgetKind"` |
