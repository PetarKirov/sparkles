# API index

The public symbols of `sparkles:base`, by module.

## `sparkles.base`

Package module re-exporting `lifetime`, `logger`, `prettyprint`,
`smallbuffer`, `source_uri`, `styled_template`, `term_style`, and `text`.

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

| Module                       | Description                                                  |
| ---------------------------- | ------------------------------------------------------------ |
| `sparkles.base.text.writers` | Integer, float, duration, byte, escape, and value writers.   |
| `sparkles.base.text.readers` | Slice-advance parsers such as `readInteger` and `readUntil`. |
| `sparkles.base.text.enums`   | Enum text helpers such as `StringRepresentation`.            |
| `sparkles.base.text.errors`  | `ParseErrorCode`, `ParseError`, and `ParseExpected!T`.       |

## `sparkles.base.term_style`

| Symbol                      | Description                                      |
| --------------------------- | ------------------------------------------------ |
| `Style`                     | ANSI foreground, background, and attribute enum. |
| `stylize`                   | Wrap text in one ANSI style.                     |
| `stylizedTextBuilder`       | CTFE-friendly chained styling builder.           |
| `styleName` / `styleSample` | Style names and sample strings.                  |

## `sparkles.base.styled_template`

| Symbol          | Description                                        |
| --------------- | -------------------------------------------------- |
| `writeStyled`   | Writes styled IES to an output range.              |
| `styledText`    | Allocating styled string conversion.               |
| `plainText`     | Allocating conversion with style markup stripped.  |
| `styledWrite*`  | stdout/stderr helpers for styled IES.              |
| `styleFromName` | Runtime lookup for style names used by the parser. |

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
