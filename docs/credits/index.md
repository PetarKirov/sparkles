# Credits

sparkles stands on other people's work. A licence list says what the project
is obliged to say; this page says what it owes — which library parses the
escape sequences, which shapes the text, which draws the emoji — and carries
each component's licence text, taken from the component's own source when
the documentation is built.

Each application has a page of its own with only the components it ships:
[sparkles:terminal](./terminal.md) and [hue](./hue.md). The same pages are
bundled with the applications.

`ci --check-credits` keeps this document honest: it reads the build inputs —
the dub lock, the application manifests, the Android builders and the font
bundle — and fails when something shipped has no section here, or a section
names something nothing ships.

## Native libraries

<!-- @include: ./parts/libghostty-vt.md -->

<!-- @include: ./parts/raylib.md -->

<!-- @include: ./parts/freetype.md -->

<!-- @include: ./parts/harfbuzz.md -->

<!-- @include: ./parts/libpng.md -->

<!-- @include: ./parts/zlib.md -->

<!-- @include: ./parts/libkqueue.md -->

<!-- @include: ./parts/tree-sitter.md -->

<!-- @include: ./parts/tree-sitter-grammars.md -->

<!-- @include: ./parts/curl.md -->

## Fonts

<!-- @include: ./parts/maple-mono.md -->

<!-- @include: ./parts/fira-code-nerd-font.md -->

<!-- @include: ./parts/dejavu-sans-mono.md -->

<!-- @include: ./parts/noto-sans.md -->

<!-- @include: ./parts/noto-color-emoji.md -->

<!-- @include: ./parts/uiua386.md -->

## D packages

<!-- @include: ./parts/expected.md -->

<!-- @include: ./parts/optional.md -->

<!-- @include: ./parts/bolts.md -->

<!-- @include: ./parts/raylib-d.md -->

<!-- @include: ./parts/during.md -->

<!-- @include: ./parts/dmd.md -->

<!-- @include: ./parts/silly.md -->
