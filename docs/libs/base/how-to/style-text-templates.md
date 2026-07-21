# Style templates with IES

Use the style template syntax inside Interpolated Expression Sequences (IES) to write colorized and formatted text to stdout, stderr, or any output range.

## Template Syntax

Style blocks use the `{styleName content}` syntax, where `styleName` is one or more dot-separated terminal styles.

- **Single Style:** `{red error}` formats the text using a red foreground.
- **Chained Styles:** `{bold.red critical}` combines styles (bold and red foreground).
- **Nested Blocks:** `{bold outer {red inner}}` applies `bold` to the entire block, and `red` additionally to `inner`.
- **Style Negation:** Use `~` prefix to remove a style from the inherited set: `{bold.red styled {~red plain}}`.
- **True-color & palette:** `{#cba6f7 mauve}` (24-bit hex), `{@183 palette}` (256-color index); prefix with `bg` for the background (`{bg#1e1e2e …}`, `{bg@235 …}`).
- **Underline shapes & color:** `{underline x}` (single), plus `{doubleUnderline …}`, `{curlyUnderline …}`, `{dottedUnderline …}`, `{dashedUnderline …}`; set an independent underline color with `{ul#ff5555 …}` or `{ul@N …}`. Curly red underlines make good inline diagnostics: `{curlyUnderline.ul#ff5555 typo}`.
- **Escaped Braces:** Use `#{` and `#}` to write literal braces: `#{style#}` outputs `{style}`.

All standard ANSI colors and formats (`red`, `green`, `blue`, `cyan`, `yellow`, `magenta`, `white`, `black`, `bold`, `dim`, `italic`, `underline`, `inverse`, `strikethrough`, `hidden`, `bgRed`, `bgGreen`, etc.) are supported.

## Terminal color depth

Every entry point (`styledText`, `plainText`, `writeStyled`, `styledWrite*`, `styled`) accepts an optional **leading** `ColorDepth` argument. It folds 24-bit and 256-palette colors down to what the terminal can address — `trueColor` (the default) emits them verbatim, `ansi256` folds RGB to the nearest palette entry, and `ansi16` folds to the nearest classic color:

```d
import sparkles.base.term_color : ColorDepth, detectColorDepth;

styledText(i"{#cba6f7 x}");                       // \x1b[38;2;203;166;247m…
styledText(ColorDepth.ansi256, i"{#cba6f7 x}");   // \x1b[38;5;183m…
styledText(ColorDepth.ansi16, i"{#cba6f7 x}");    // \x1b[37m…
styledText(detectColorDepth(), i"{#cba6f7 x}");   // fold to the real terminal
```

## Write directly to stdout or stderr

Use the `styledWrite*` helpers to write styled IES content directly to standard output or error streams:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_style_text_templates"
    dependency "sparkles:base" version="*"
+/
import sparkles.base.styled_template : styledWriteln, styledWritelnErr;

void main()
{
    // Write styled text to stdout
    styledWriteln(i"Status: {green.bold OK} | Service: {cyan database}");

    // Write styled text to stderr
    styledWritelnErr(i"{red.bold Fatal Error: connection refused}");
}
```

```ansi
[1;31mFatal Error: connection refused[22;39m
Status: [1;32mOK[22;39m | Service: [36mdatabase[39m
```

## Convert to strings

Use `styledText` to evaluate an IES template and return a styled `string` containing ANSI escape codes. Use `plainText` to evaluate the IES but strip all style markup, returning a clean plain-text `string`:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_styled_text_conversion"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.styled_template : styledText, plainText;

void main()
{
    auto template_ = i"Progress: {yellow 45%}";

    string styled = styledText(template_);
    string plain = plainText(template_);

    writeln("Styled length: ", styled.length); // includes escape characters
    writeln("Plain length: ", plain.length);   // plain text only
}
```

```ansi
Styled length: 23
Plain length: 13
```

## Format into custom buffers

For memory-conscious or `@nogc` formatting, use `writeStyled` to write formatted, styled templates into any `Writer` (such as a `SmallBuffer`):

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_write_styled_buffer"
    dependency "sparkles:base" version="*"
+/
import std.stdio : writeln;
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.styled_template : writeStyled;

void main()
{
    SmallBuffer!(char, 128) buf;
    writeStyled(buf, i"Level: {magenta debug}");

    writeln(buf[]);
}
```

```ansi
Level: [35mdebug[39m
```
