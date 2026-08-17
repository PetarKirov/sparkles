# Why the parsers look the way they do

Each of these formats is simple enough to parse in an afternoon, and each has
one detail that makes the obvious parser quietly wrong. They are collected
here because every one of them cost a defect before it was understood, and
because the shape of the code only makes sense against them.

## A numeric field must be entirely digits

`geninfo --checksum` appends an MD5 to each line record:

```
DA:1,3,f1ab29d0
```

A reader that walks the field accumulating digits and skipping everything
else — the obvious way to be lenient about whitespace — reads that execution
count as **31290**. It is not a parse failure that gets noticed; it is a
number that looks plausible.

This is why `wholeNumber` rejects a field with anything but digits in it, and
why all three textual parsers go through it rather than each being lenient in
its own way.

## Record order is not fixed

LCOV groups records into per-file blocks, but nothing fixes the order of the
groups inside one. `geninfo` writes branch records before the line records;
Istanbul writes them after. A parser that attaches a `BRDA` to "the line
record it follows" finds nothing in the first case and the wrong line in the
second — and either way the file-level branch totals still look right, so the
damage is invisible unless you check per-line data.

The parser buffers a block's records and joins them by line number at
`end_of_record`. It also flushes at end of input: a truncated tracefile still
describes a file, and discarding it loses every record already read.

## `taken 0` and `taken 0%` are the same statement

gcov spells branch outcomes two ways depending on its flags:

```
branch  0 taken 50%      # gcov -b
branch  0 taken 0        # gcov -b -c
branch  1 never executed
```

Matching the string `taken 0%` catches only the first. Under `-c` — the flag
you use precisely when you want real counts — every untaken branch scores as
covered, and branch coverage reads 100%.

Read the token after `taken` and test it numerically.

## Not every llvm-cov segment states a count

An `llvm-cov export` segment is
`[line, column, count, hasCount, isRegionEntry, isGapRegion]`. Two of those
flags matter:

- `hasCount == false` marks a region _ending_. Its count field is
  meaningless.
- `isGapRegion == true` covers text between regions — a brace on its own
  line — with no counter of its own.

Recording either as a real count renders closing braces red. Several segments
can also share a line, and the line ran if _any_ of them did, so they
aggregate by maximum rather than first-wins.

## V8 coverage is nested, not flat

A function's first range spans the whole function and carries its count;
inner ranges carve out sub-expressions that ran a different number of times.
A count of 0 on an inner range means the enclosing code ran and that piece did
not.

Two things follow. Ranges must be applied outermost-first, or the last one
processed wins and the same coverage reads differently depending on the order
the producer happened to emit it. And a zero-count range that only _overlaps_
a line does not make the line unexecuted — `if (c) { miss(); }` evaluates its
condition every time. That line is `partial`; the byte-exact truth stays in
`spans`.

## The listing names the file, the artifact does not

A DMD `.lst` ends with a trailer:

```
libs/x/src/math.d is 50% covered
```

That is the only place the source path appears. Overriding it with the
artifact's own path — `build/cov/math.lst` — is tempting because the caller
has it in hand, and it makes every subsequent lookup by source path fail.

## Detection is a guess, and should act like one

Content heuristics are how you support a `.json` that could be either V8 or
llvm-cov. They are also how a D source that mentions `"ranges"` in a comment,
or a markdown page documenting gcov, gets classified as a coverage report.

So every marker is anchored to the position its format actually puts it in —
`SF:` at the start of a line _and_ an `end_of_record` to close it, a
`<count>:<line>:` prefix with both columns well-formed — and the JSON forms
must parse and carry the expected root shape. `formatFromExtension` exists
separately for callers deciding whether to act on a file rather than parse
one they were handed.
