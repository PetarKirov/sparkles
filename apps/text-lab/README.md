# Text lab

Preview installed font faces, real advances, and declared variable axes on
dark and light backgrounds. **Fonts** (`f`) opens the fuzzy picker; **Settings**
opens the generated settings sheet. The interface keeps a stable font unless
**UI follows specimen** is enabled. **F12** restores the stable interface.

Moving the picker selection previews the font immediately. Hover a row with
a mouse, or tap a row on touchscreens; **Use font** (or Enter) accepts it and
Escape/Cancel restores the original specimen without adding an undo entry.
The picker shows one regular representative per main family. Installed Noto
Sans/Serif script and UI satellites collapse under their main family; every
face remains available to fallback resolution.

Hover a specimen glyph, or touch it on mobile, to inspect its serving face,
collection member, fallback status, glyph ID/name, shaping metrics, source
cluster, and Unicode properties. Touch tooltips remain visible after release;
touch elsewhere or open a panel to dismiss them. Ligatures and combining
sequences report their source cluster rather than inventing a character-to-
glyph correspondence.

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
`+`/`-` size, `p` screenshot, and `q` quit. On touchscreens (such as Android),
pinch to increase or decrease the font size. Editors consume their own input.

**Specimen → Sample group** selects Unicode pages, including CJK, RTL, Indic,
historic scripts and emoji. `n`/`N` cycle groups; **Start at row** or Page Up/
Page Down reveals later samples. `--showcase cjk --no-loupe --shot /tmp/cjk.png`
captures a selected group. See the [sample inventory and coverage audit](../../docs/libs/ui-app/reference/unicode-showcase.md).

For reproducible measurements:

```bash
dub run :text-lab -b checked -- --font /path/to/variable.ttf --sweep-frames 240 --debug gpu-timing --debug frame-trace=/tmp/font-sweep.json
dub run --single libs/ui-app/examples/specimen-font-benchmark.d -b checked
```

The first command runs real application frames; the second isolates CPU
preparation, binding, and rasterization. See the
[preview contract and validation limits](../../docs/specs/ui-app/font-preview.md).

Use `--sweep-mode render` for fixed-font redraws, `size`, `weight`, or `axes`
to isolate changing settings. The default `all` varies size and every axis.
Pair each workload with `--settings` and `--ui-follows-specimen` to measure
those costs separately. Frame traces include CPU phases and GPU timestamps
when the device supports them; discard warmup before comparing distributions.
Use `--raster-workers 1`, `2`, `3`, or `4` to compare coverage batches;
`1` runs on the frame thread and the default is `2`.

On Android, put newline-separated CLI arguments in the app-private
`files/next-launch.args` before starting the activity. For example, use
`adb push` to copy an argument file to `/data/local/tmp/next-launch.args`, then:

```bash
adb shell am force-stop dev.petar_kirov.sparkles.text_lab
adb shell run-as dev.petar_kirov.sparkles.text_lab cp /data/local/tmp/next-launch.args files/next-launch.args
adb shell am start -W -n dev.petar_kirov.sparkles.text_lab/android.app.NativeActivity
```

Use absolute app-private paths for trace output and font files. The APK supplies
its bundled font directory automatically. The argument file is consumed before
launch, so the next interactive launch returns to the defaults, even after an
interrupted sweep. Retrieve a trace with `adb exec-out run-as` and `cat`.

Compare experimental coverage with `--coverage-mode cpu`, `edges`, or `bands`.
The CPU atlas remains the default; the GPU variants use the same hinted outline
preparation and retain CPU fallback for unsupported glyphs. `--coverage-report
PATH` writes worker elapsed-time sums and caller batch time, aggregated per frame.
These overlapping timings are separate from the frame/GPU trace.

The device driver rotates mode order over weight and size sweeps and retains
raw traces, worker reports, device capabilities and thermal conditions:

```bash
ANDROID_SERIAL=DEVICE_SERIAL dub run --single apps/text-lab/tools/profile-coverage.d -- adb /tmp/coverage 3 420
```

The shared packing operation can also run without a window:

```d
/+ dub.sdl:
    name "text_lab_coverage_bands"
    dependency "sparkles:ui-vulkan" version="*"
    buildType "checked" {
        buildOptions "optimize" "inline" "debugInfo"
    }
+/
import std.stdio : writefln;
import sparkles.base.buffer : UniqueBuffer;
import sparkles.font : RasterEdge;
import sparkles.shaders : vec4;
import sparkles.ui_vulkan.coverage_geometry : packCoverageEdges;

void main() @safe
{
    RasterEdge[2] sides = [RasterEdge(0, 0, 0, 12), RasterEdge(8, 12, 8, 0)];
    UniqueBuffer!vec4 geometry;
    const bands = packCoverageEdges(sides[], 12, true, geometry);
    writefln("bands %spx; stride %s; texels %s", bands.bandHeight, bands.stride, geometry.length);
}
```

```ansi
bands 4px; stride 2; texels 6
```

See [device measurements and limitations](../../docs/libs/ui-app/explanation/font-preview-performance.md)
for the comparison results. The current GPU variants have not met the 120 Hz gate.
