# API index

The public symbols of `sparkles:base`, by module.

## `sparkles.base`

Package module re-exporting `lifetime`, `logger`, `prettyprint`,
`smallbuffer`, `source_uri`, `styled_template`, `term_color`, `term_style`,
and `text`.

## `sparkles.base.smallbuffer`

| Symbol                          | Description                                                       |
| ------------------------------- | ----------------------------------------------------------------- |
| `SmallBuffer!(T, N)`            | Stack-first append buffer that grows with `pureMalloc` if needed. |
| `checkToString` / `checkWriter` | `@nogc` unit-test helpers for output-range rendering assertions.  |

## `sparkles.base.lifetime`

| Symbol                         | Description                                                             |
| ------------------------------ | ----------------------------------------------------------------------- |
| `recycledInstance!T(args)`     | Reinitialises one thread-local static instance of `T`.                  |
| `recycledErrorInstance!T(...)` | Builds an `Error` subclass in recycled storage for `@nogc` throw paths. |

## `sparkles.base.text`

The package re-exports `text.writers`, `text.readers`, `text.enums`, and
`text.errors`.

| Module                       | Description                                                                                        |
| ---------------------------- | -------------------------------------------------------------------------------------------------- |
| `sparkles.base.text.writers` | Integer, float, duration, byte, hex (`writeHexByte`), escape, and value writers.                   |
| `sparkles.base.text.readers` | Slice-advance parsers (`readInteger`, `readUntil`) plus hex predicates `isHexDigit` / `hexNibble`. |
| `sparkles.base.text.enums`   | Enum text helpers such as `StringRepresentation`.                                                  |
| `sparkles.base.text.errors`  | `ParseErrorCode`, `ParseError`, and `ParseExpected!T`.                                             |

## `sparkles.base.term_style`

| Symbol                      | Description                                                                                                   |
| --------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `Style`                     | ANSI foreground, background, and attribute `[open, close]` code table.                                        |
| `TermStyle`                 | Resolved style: `fg`/`bg`/`underlineColor`, `attrs`, `underline`.                                             |
| `TextAttr`                  | Attribute bitflag struct (bold/dim/italic/strikethrough/inverse/hidden) with typed `\|`/`&`/`~` and `.has()`. |
| `UnderlineStyle`            | Underline shape: none/single/double\_/curly/dotted/dashed.                                                    |
| `writeStyleTransition`      | Differential ANSI encoder: minimal merged `ESC[…m` diff between two `TermStyle`s at a `ColorDepth`.           |
| `stylize`                   | Wrap text in one ANSI style.                                                                                  |
| `stylizedTextBuilder`       | CTFE-friendly chained styling builder.                                                                        |
| `styleName` / `styleSample` | Style names and sample strings.                                                                               |

## `sparkles.base.term_color`

| Symbol                                | Description                                                                     |
| ------------------------------------- | ------------------------------------------------------------------------------- |
| `Color`                               | Four-case color: `unset` / `default_` / `palette` / `rgb`.                      |
| `RgbColor`                            | 24-bit RGB triple.                                                              |
| `ColorChannel`                        | SGR channel: `foreground` (38/39) / `background` (48/49) / `underline` (58/59). |
| `writeSgrColor`                       | Emit the SGR color parameters for a `Color` on a channel, depth-folded.         |
| `parseHexColor`                       | Parse `#RGB`/`#RRGGBB`/`#RRGGBBAA` (bat alpha convention) → `Color`.            |
| `ansi256FromRgb` / `ansi16FromRgb`    | Fold an RGB value to the nearest 256-/16-palette index.                         |
| `xterm256ToRgb`                       | The RGB behind an xterm-256 palette index.                                      |
| `ColorDepth`                          | Terminal color tiers: `none` / `ansi16` / `ansi256` / `trueColor`.              |
| `classifyColorDepth(colorterm, term)` | Pure, CTFE-able tier classifier over `$COLORTERM`/`$TERM` values.               |
| `detectColorDepth()`                  | Environment-reading wrapper over `classifyColorDepth`.                          |

## `sparkles.base.styled_template`

| Symbol          | Description                                                           |
| --------------- | --------------------------------------------------------------------- |
| `writeStyled`   | Writes styled IES to an output range (optional leading `ColorDepth`). |
| `styledText`    | Allocating styled string conversion (optional leading `ColorDepth`).  |
| `plainText`     | Allocating conversion with style markup stripped.                     |
| `styledWrite*`  | stdout/stderr helpers for styled IES (optional leading `ColorDepth`). |
| `styleFromName` | Runtime lookup for style names used by the parser.                    |

## `sparkles.base.logger`

| Symbol                                                          | Description                                                      |
| --------------------------------------------------------------- | ---------------------------------------------------------------- |
| `CoreLogger`                                                    | `std.logger.Logger` base class with a Sparkles `@nogc` log path. |
| `CoreLogEntry`                                                  | Metadata captured for Sparkles log calls.                        |
| `DeltaTimeLogger`                                               | stderr logger with wall-clock and monotonic delta prefixes.      |
| `sharedCoreLog`                                                 | Atomic process-wide Sparkles logger.                             |
| `coreGlobalLogLevel`                                            | Atomic process-wide Sparkles log-level filter.                   |
| `CoreFatalHandler` / `coreFatalHandler`                         | Fatal policy hook and global accessor.                           |
| `throwingFatalHandler`                                          | Throws recycled `FatalLogError`.                                 |
| `assertingFatalHandler`                                         | Fails with `assert(0, message)`.                                 |
| `abortingFatalHandler`                                          | Calls `abort()`.                                                 |
| `log`, `trace`, `info`, `warning`, `error`, `critical`, `fatal` | Styled IES logging wrappers.                                     |
| `initLogger`                                                    | Installs `DeltaTimeLogger` for Phobos and Sparkles globals.      |

## `sparkles.base.prettyprint`

| Symbol               | Description                                                       |
| -------------------- | ----------------------------------------------------------------- |
| `PrettyPrintOptions` | Configuration for structural indentation and syntax highlighting. |
| `prettyPrint`        | Pretty-prints any D value to a writer or returns a string.        |

## `sparkles.base.source_uri`

| Symbol              | Description                                                       |
| ------------------- | ----------------------------------------------------------------- |
| `resolveSourcePath` | Resolves relative source path to absolute path.                   |
| `FileUriHook`       | Default hook that formats source locations as `file://` URIs.     |
| `SchemeHook`        | Hook that formats source locations using custom editor schemes.   |
| `EditorDetectHook`  | Runtime detector using `$VISUAL`/`$EDITOR` environment variables. |
