# Text lab

Preview installed font faces, real advances, and declared variable axes on
dark and light backgrounds. **Fonts** (`f`) opens the fuzzy picker; **Settings**
opens the generated settings sheet. The interface keeps a stable font unless
**UI follows specimen** is enabled. **F12** restores the stable interface.

```bash
dub run :text-lab -- --settings
dub run :text-lab -- --picker
dub run :text-lab -- --font /path/to/font.ttc --font-face-index 2
dub run :text-lab -- --font /path/to/variable.ttf --font-variation wght=700,opsz=24 --settings --no-loupe --shot /tmp/font.png
```

Sliders update live and commit one undo step on release. Escape cancels an
unfinished drag. The numeric badge opens exact number entry. Undo/redo (`u`/`U`
or Ctrl+Z/Ctrl+Y) follows settings edits and font selections chronologically;
returning to a font recalls its session axis values. Custom axes appear with
their declared names and tags; hidden axes have an explicit visibility option.

Outside editors the specimen keys remain available: `c` compositing, `h`
hinting, `s` shaping, `[`/`]` contrast, `m` loupe, `x` crosshair, `1`–`4` zoom,
`+`/`-` size, `p` screenshot, and `q` quit. Editors consume their own input.

For reproducible measurements:

```bash
dub run :text-lab -b checked -- --font /path/to/variable.ttf --sweep-frames 240 --debug gpu-timing --debug frame-trace=/tmp/font-sweep.json
dub run --single libs/ui-app/examples/specimen-font-benchmark.d -b checked
```

The first command runs real application frames; the second isolates CPU
preparation, binding, and rasterization. See the
[preview contract and validation limits](../../docs/specs/ui-app/font-preview.md).
