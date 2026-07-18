/**
Low-level text I/O primitives for CLI tooling.

This package groups the building blocks that read, write, and report
errors on text without committing to any higher-level format:

$(UL
    $(LI `sparkles.base.text.writers` — integer / float / escaped
        output-range writers.)
    $(LI `sparkles.base.text.html` — HTML/XML entity escaping.)
    $(LI `sparkles.base.text.readers` — slice-advance parsers.)
    $(LI `sparkles.base.text.enums` — enum text conversion helpers.)
    $(LI `sparkles.base.text.case_style` — identifier case conversion.)
    $(LI `sparkles.base.text.errors` — the `Expected`-based parse
        error vocabulary shared by the readers.)
)

Importing `sparkles.base.text` pulls in the whole package.
*/
module sparkles.base.text;

public import sparkles.base.text.writers;
public import sparkles.base.text.base_codecs;
public import sparkles.base.text.html;
public import sparkles.base.text.readers;
public import sparkles.base.text.enums;
public import sparkles.base.text.case_style;
public import sparkles.base.text.errors;
public import sparkles.base.text.ansi;
public import sparkles.base.text.width;
public import sparkles.base.text.grapheme;
public import sparkles.base.text.wrap;
