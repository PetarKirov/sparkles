# Font library and document fonts

`sparkles.ui_app.font_library` is the mechanism a font picker runs over: it
discovers fonts on a background pool, lists their families, ranks them for a
fuzzy picker, and prepares the files a chosen font draws from. Text-lab's
face picker runs on it, and the editor's document-font settings (`EAP16`)
are to. The
families and the document font's settings come from
[`sparkles.font.families`](../../font/reference/api.md).

## Discovery

`FontLibrary.start(directories, cacheDirectory)` builds a `sparkles:font`
catalog off the frame thread: from `directories` when given, else from
`$SPARKLES_FONTS_PATH` and the platform's fonts. Call `poll()` from the
owning thread each frame; it dispatches completions and returns whether
anything changed. When `ready` is set, `entries` lists every face and
`families` lists the catalog's families, with `familyNames` beside them.
`error` names what failed; discovery never blocks a frame. `stop()` joins
the workers before their buffers are released.

## Picking a family

`FontFinder.families(families, names, showAll)` installs the families as a
picker corpus: the monospace families only, unless `showAll` is set. A
monospace family has one advance, or a CJK face's two, and the ASCII letters
and digits, so emoji and notation faces stay out of the default list.
`search(picker)` publishes the best 128 matches into a `PickerState!128`;
`matching(query)` returns them as indices into `families`, best first.
`entryIndex(row)` maps a picker row back to its family. Reinstall the corpus
when the show-all switch changes. `corpus(entries)` is the face-level
picker text-lab uses, one row per family's regular face.

## Preparing a document font

`familyIndex(name)` finds a family by name, ignoring ASCII case.
`member(family, style)` gives the file, collection index and coordinates of
a style's real member; a missing member is not synthesized.
`requestDocumentFont(family)` queues the regular member and the bold,
italic and bold-italic files on the pool. `requestStyles(family)` queues the
style files alone. A file already prepared is reused.

`controls(family, loads)` reports each `FontControl` as `available`,
`unsupported` or `unknown`. Size, line height and letter spacing always
apply. A style is available when its own file was queued. Weight and optical
size are available when the family's regular face declares `wght` or
`opsz`. Ligatures are read from the regular file once it is prepared, and
are `unknown` until then. Show unsupported controls disabled rather than
hiding them.

`documentFontRequest(family, loads, font, request)` fills a
`SpecimenFontRequest` once every queued file is prepared: the regular file
at `font.size` rounded to pixels, `wght` and `opsz` from
`instanceCoordinates`, and the style files as family styles. Hand it to the
native host's `specimenFont`, which swaps the cell font without touching the
interface font; then `retain` the loads so their bytes outlive the
renderer. Line height, letter spacing and ligatures are not part of a
specimen request: the application applies them to its own layout. A
terminal host has no font to set, so a TUI keeps the settings and shows the
font controls as not applying there.

A style slot carries a file but no coordinates. A variable family's bold,
which is its regular face at `wght` 700, is therefore not queued, and its
bold is reported unsupported; a separate variable italic file draws at its
default instance.
