# `sparkles.base.status_line` — Specification

_Audience: developers and coding agents writing a command-line program on
`sparkles:base`. This document is normative and self-contained: it states the
one line form a program's progress and log take on a console, and how a line
travels through the logger. How `ci` draws them is specified in
[ci task-DAG CIC19](../ci/task-dag/SPEC.md); for the library overview see
[`sparkles:base`](../../libs/base/index.md)._

## 1. Overview

A command that builds, tests or fetches reports two kinds of line: its
progress (what it compiled, what it tested) and its log (a warning, a note,
a detail for whoever debugs it). Written by different hands they look
different, and a console that mixes them reads as noise. A **status line** is
one form for both, the one cargo and dub use:

```text
    Compiled base [library]  1.2s
      Tested base 1078 passed, 4 skipped  55.7s
     Warning ui tested without coverage
```

A verb, right-aligned in a column of twelve and coloured by what happened,
then what it happened to and the details. The line is data, so one renderer
gives every program the same look, and a sink that keeps a copy (a ring, a
file) stores its plain text.

| Identifier      | Value                                               |
| --------------- | --------------------------------------------------- |
| Dub sub-package | `sparkles:base`                                     |
| Modules         | `sparkles.base.status_line`, `sparkles.base.logger` |

## 2. Requirements

**CON1: The line form.** `writeStatusLine` **must** write a line as its verb
right-aligned in `verbColumns` (twelve) display columns, a space, then its
spans: one space between two, two before a detail, an empty span left out. A
line whose verb is null is bare (its spans alone, no column: a child's output
quoted beneath the line that reports it); an empty verb leaves the column
blank (a line that continues the one above). With colour, the verb is bold in
its tone's colour and each span in its role's, each run followed by a reset;
the colours are the terminal's sixteen (green success, red failure, yellow
warning, blue information, bright black muted), so a line reads the same on a
light terminal and a dark one. Without colour the line is its text alone.
`writeSpan` and `writeVerb` **must** write one span or one verb styled the
same way, with no padding or spacing, for a caller that lays a line's parts
out in columns itself.

**CON2: Status through the logger.** `status(verb, tone, spans…)` **must**
report a line through the installed logger at a level, `info` by default: a
detail reported at `trace` shows only when the program's level admits it. The
log entry carries the line (`CoreLogEntry.status`), so a sink that draws
status lines draws it; every other sink receives the line's plain text as the
message. The default sink is unchanged: a program chooses to draw status lines
by installing a sink that does.

**CON3: One vocabulary.** Tones (`Tone`) and roles (`SpanRole`) are the whole
vocabulary: a program says what happened and what each part of the line is,
never a colour or an escape sequence.

## 3. Traceability

| ID   | Status | Evidence                                                                                                                |
| ---- | ------ | ----------------------------------------------------------------------------------------------------------------------- |
| CON1 | full   | `base.status_line.writeStatusLine.plain`, `base.status_line.writeStatusLine.colour`, `base.status_line.writeSpan.alone` |
| CON2 | full   | `log_sinks.status.plainTextElsewhere`; `ci`'s sink: `console.writeRecord.levelAsTheVerb`                                |
| CON3 | full   | `sparkles.base.status_line` exports no colour: `Tone`, `SpanRole`                                                       |
