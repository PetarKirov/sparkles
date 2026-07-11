# Manim's text pipeline: LaTeX → dvi/xdv → SVG → `VMobject`

How Manim Community turns a string into animatable geometry. There is no glyph
rasterizer in Manim: **every** piece of text — a LaTeX formula, a Pango-shaped
label, a Typst snippet — is compiled to an **SVG of vector paths** and then
imported into the same cubic-`VMobject` scene graph as any hand-drawn shape.
This is the typesetting companion to the Manim Community deep-dive; the
object model it feeds is [`scene-graph.md`][scene-graph], shared terms are in
[`../concepts.md`][concepts].

---

## How it works

Three independent front-ends produce SVG; one importer converts SVG to
`VMobject` outlines.

```text
MathTex / Tex ──► tex_to_svg_file ──► latex/xelatex (subprocess) ──► .dvi/.xdv/.pdf ──► dvisvgm --no-fonts ──┐
Text / MarkupText ──► manimpango.text2svg (Pango + HarfBuzz shaping) ─────────────────────────────► .svg ───┼─► SVGMobject
TypstMobject ──► typst_to_svg_file ──► typst.compile(format="svg") (in-process) ───────────────────► .svg ──┘   (svgelements → cubic points)
```

### LaTeX: a multi-step subprocess pipeline

`tex_file_writing.py` is described in its module docstring as the _"Interface for
writing, compiling, and converting `.tex` files"_ ([`tex_file_writing.py:1`][tex-write]).
`tex_to_svg_file` ([`tex_file_writing.py:35`][tex-write]) drives four stages:

```python
# tex_file_writing.py:58 — write .tex, compile to dvi/xdv/pdf, convert to svg
tex_file = generate_tex_file(expression, environment, tex_template)
dvi_file = compile_tex(tex_file, tex_template.tex_compiler, tex_template.output_format)
svg_file = convert_to_svg(dvi_file, tex_template.output_format)
```

1. **`generate_tex_file`** ([`tex_file_writing.py:76`][tex-write]) wraps the
   expression in the template and writes it under `tex_dir`, named by
   `tex_hash` — a truncated SHA-256: `hasher.hexdigest()[:16]`
   ([`tex_file_writing.py:32`][tex-write]). This is the on-disk cache key for
   compiled TeX.
2. **`compile_tex`** ([`tex_file_writing.py:181`][tex-write]) shells out with
   `subprocess.run(command, stdout=subprocess.DEVNULL)` ([`:214`][tex-write]).
   The compiler is configurable: `make_tex_compilation_command`
   ([`tex_file_writing.py:118`][tex-write]) builds `latex`/`pdflatex`/
   `lualatex` invocations with `-output-format=`, `-halt-on-error`, and
   `-output-directory=`, and special-cases `xelatex`, which uses `-no-pdf` to
   emit `.xdv` instead of PDF ([`tex_file_writing.py:149`][tex-write]). A list of
   compilers can be chained.
3. **`convert_to_svg`** ([`tex_file_writing.py:226`][tex-write]) runs `dvisvgm`:

```python
# tex_file_writing.py:245 — dvisvgm turns glyphs into vector PATHS, not fonts
command = [
    "dvisvgm",
    *(["--pdf"] if extension == ".pdf" else []),
    f"--page={page}",
    "--no-fonts",          # ← convert font glyphs to <path> outlines
    "--verbosity=0",
    f"--output={result.as_posix()}",
    f"{dvi_file.as_posix()}",
]
```

The `--no-fonts` flag is the crux: it makes `dvisvgm` emit each glyph as a
standalone vector path rather than referencing an embedded font, so the SVG
Manim imports is pure geometry. If conversion fails the error suggests _"updating
dvisvgm to at least version 2.4"_ ([`tex_file_writing.py:261`][tex-write]).

The mobject side: `SingleStringMathTex(SVGMobject)`
([`tex_mobject.py:46`][tex-mob]) calls `tex_to_svg_file` in its constructor
([`tex_mobject.py:81`][tex-mob]) with `tex_environment="align*"` by default, and
passes `path_string_config={"should_subdivide_sharp_curves": True,
"should_remove_null_curves": True}` ([`tex_mobject.py:92`][tex-mob]) to the SVG
importer. `MathTex` ([`tex_mobject.py:227`][tex-mob]) and `Tex`
([`tex_mobject.py:607`][tex-mob]) subclass it to split a formula into
addressable sub-mobjects.

### Non-math text: manimpango (Pango + HarfBuzz)

`Text` and `MarkupText` (both `SVGMobject`, [`text_mobject.py:302`][text-mob] and
[`:841`][text-mob]) route through **`manimpango`** (`import manimpango`,
[`text_mobject.py:66`][text-mob]) — Manim's Cython binding over Pango, which does
Unicode [text shaping][shaping] (HarfBuzz) and font selection. `Text._text2svg`
([`text_mobject.py:799`][text-mob]) calls:

```python
# text_mobject.py:818 — Pango shapes and rasterizes text into an SVG of paths
svg_file = manimpango.text2svg(
    settings, size, line_spacing, self.disable_ligatures,
    str(file_name.resolve()), START_X, START_Y, width, height, self.text)
```

`MarkupText` uses `MarkupUtils.text2svg(...)`
([`text_mobject.py:1367`][text-mob]) for Pango-markup input, and `register_font`
([`text_mobject.py:1487`][text-mob], `manimpango.register_font`) makes a font
file visible to `manimpango.list_fonts()`. The output SVG is again pure paths,
consumed by the same importer.

### Typst: in-process, single-step

The newest front-end skips the subprocess dance. `typst_file_writing.py` —
_"Interface for writing, compiling, and converting `.typ` files via the `typst`
Python package"_ ([`typst_file_writing.py:1`][typst-write]) — compiles Typst
markup **directly to SVG in-process**:

```python
# typst_file_writing.py:100 — one call, no dvisvgm intermediate
svg_bytes = typst_compiler.compile(str(typ_file), format="svg", font_paths=font_paths or [])
```

It caches by the same scheme (`_typst_hash` = `hexdigest()[:16]`,
[`typst_file_writing.py:32`][typst-write]) and is gated behind the optional
`typst>=0.14` extra ([`pyproject.toml`][pyproject]); importing `TypstMobject`
without it raises _"TypstMobject requires the 'typst' Python package"_
([`typst_file_writing.py:73`][typst-write]).

---

## Glyph outline extraction: SVG → cubic `VMobject`

All three front-ends converge on `SVGMobject` ([`svg_mobject.py`][svg-mob]),
which parses the file with **`svgelements`** (`import svgelements as se`,
[`svg_mobject.py:11`][svg-mob]): `se.SVG.parse(...)`
([`svg_mobject.py:205`][svg-mob]), then walks groups and shapes
(`get_mobjects_from`, [`svg_mobject.py:264`][svg-mob]) turning each `se.Path`
into a `VMobjectFromSVGPath` ([`svg_mobject.py:385`][svg-mob]). The per-segment
conversion is `handle_commands` ([`svg_mobject.py:561`][svg-mob]) — this is the
[glyph-outline-extraction][glyph] step, and it is **basis-aware**:

```python
# svg_mobject.py:575 — the cubic (Cairo) branch: elevate everything to 4-point cubics
if self.n_points_per_curve == 4:
    def add_quad(start, cp, end):        # quadratic → cubic (exact 2/3 elevation)
        add_cubic(start, (start + cp + cp) / 3, (cp + cp + end) / 3, end)
    def add_line(start, end):            # line → cubic (handles on the segment)
        add_cubic(start, (start + start + end) / 3, (start + end + end) / 3, end)
```

For each SVG path segment — `se.Move`, `se.Line`, `se.QuadraticBezier`,
`se.CubicBezier`, `se.Close` ([`svg_mobject.py:622-649`][svg-mob]) — the cubic
backend stores cubics verbatim (`[start, cp1, cp2, end]`,
[`svg_mobject.py:582`][svg-mob]) and _elevates_ lines and quadratics into cubics,
the same `2/3` rule the hand-built geometry uses ([`scene-graph.md`][scene-graph],
[`bezier-eval.d`][ex-bezier]). The OpenGL branch instead _lowers_ SVG cubics to
two quadratics via `get_quadratic_approximation_of_cubic`
([`svg_mobject.py:602`][svg-mob]). The result is written straight into the
mobject's `points` array ([`svg_mobject.py:651`][svg-mob]) — from there, text is
indistinguishable from any other `VMobject` and animates identically.

> [!NOTE]
> Because text is geometry, a glyph is _not_ pixel-snapped or hinted the way a
> font rasterizer would. The path outlines are scaled to `font_size` after
> import (`SingleStringMathTex.font_size`, [`tex_mobject.py:112`][tex-mob]), so
> text remains resolution-independent and interpolates point-for-point in a
> `Transform` once point counts are aligned ([`scene-graph.md`][scene-graph]).

---

## Typesetting & text (analysis)

Mapping the front-ends onto the survey's axis:

| Concern            | LaTeX (`MathTex`/`Tex`)                 | Pango (`Text`/`MarkupText`)     | Typst (`TypstMobject`)      |
| ------------------ | --------------------------------------- | ------------------------------- | --------------------------- |
| Engine             | `latex`/`xelatex`/`lualatex` subprocess | `manimpango` (Pango + HarfBuzz) | `typst` package, in-process |
| Intermediate       | `.dvi` / `.xdv` / `.pdf`                | none (direct to SVG)            | none (direct to SVG)        |
| SVG converter      | `dvisvgm --no-fonts`                    | Pango's Cairo SVG surface       | Typst's SVG exporter        |
| [Shaping][shaping] | TeX's math + font metrics               | HarfBuzz complex-script shaping | Typst's own shaper          |
| Cache key          | `sha256(tex)[:16]`                      | `_text2hash` (color-aware)      | `sha256(source)[:16]`       |
| Dependency         | full TeX install + `dvisvgm` (external) | `manimpango` (bundled binding)  | optional `typst` extra      |

The through-line is that all text lands in the **cubic** `VMobject` layout on the
default Cairo backend, so [`latex-to-svg`][latex] and [`text-shaping`][shaping]
are _front-ends_ to the one vector-geometry model; nothing about text has its own
rasterization or its own animation code. The determinism of the SHA-256 filenames
also feeds the render cache described in [`caching.md`][caching].

---

## Sources

- [`manim/utils/tex_file_writing.py`][tex-write] — `tex_to_svg_file`,
  `compile_tex` (subprocess), `make_tex_compilation_command`, `convert_to_svg`
  (`dvisvgm --no-fonts`), `tex_hash`.
- [`manim/mobject/text/tex_mobject.py`][tex-mob] — `SingleStringMathTex`,
  `MathTex`, `Tex`; SVG import config.
- [`manim/mobject/text/text_mobject.py`][text-mob] — `Text`, `MarkupText`,
  `manimpango.text2svg` / `MarkupUtils.text2svg`, `register_font`.
- [`manim/utils/typst_file_writing.py`][typst-write] — in-process Typst → SVG.
- [`manim/mobject/svg/svg_mobject.py`][svg-mob] — `svgelements` parse,
  `handle_commands` basis-aware SVG-path → cubic `points`.

Related: the Manim Community deep-dive · [`scene-graph.md`][scene-graph] ·
[`caching.md`][caching] · [`../concepts.md`][concepts] · [`manimgl`][manimgl].
Probe: [`bezier-eval.d`][ex-bezier].

<!-- References -->

[scene-graph]: ./scene-graph.md
[caching]: ./caching.md
[concepts]: ../concepts.md
[manimgl]: ../manimgl.md
[glyph]: ../concepts.md#glyph-outline-extraction
[latex]: ../concepts.md#latex-to-svg
[shaping]: ../concepts.md#text-shaping
[ex-bezier]: ../examples/bezier-eval.d
[tex-write]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/tex_file_writing.py
[typst-write]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/utils/typst_file_writing.py
[tex-mob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/text/tex_mobject.py
[text-mob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/text/text_mobject.py
[svg-mob]: https://github.com/ManimCommunity/manim/blob/4d25c031/manim/mobject/svg/svg_mobject.py
[pyproject]: https://github.com/ManimCommunity/manim/blob/4d25c031/pyproject.toml
