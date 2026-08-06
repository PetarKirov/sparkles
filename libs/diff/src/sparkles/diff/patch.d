/// The unified-patch parser and emitter (`DVM3`): `git diff` / `diff -u`
/// output parses into the same model a computed diff produces, so both
/// render identically; the emitter closes the round-trip (and is the copy
/// serializer behind `--diff-copy=patch`, `DVL8`).
///
/// `@nogc` (`DVM8`): the parser borrows the patch text (row `src` spans
/// reference it; both `DiffDoc` backing sides are the patch), path bytes are
/// copied into the document's owned arena, and the emitter writes to a
/// caller-supplied output range instead of returning a GC string. Errors use
/// the repository's `ParseExpected` vocabulary (`sparkles.base.text.errors`).
module sparkles.diff.patch;

import std.range.primitives : put;

import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text.errors : ParseErrorCode, ParseExpected, parseErr, parseOk;
import sparkles.base.text.writers : writeInteger;

import sparkles.diff.model : DiffDoc, DiffOptions, FileEntry, Hunk, Row, RowKind, Span;
import sparkles.diff.pairing : pairChangeBlocks;
import sparkles.diff.refine : refineRows;

/// Parse a unified diff (git or POSIX flavor) into a `DiffDoc` that borrows
/// `patch` (row texts span it — keep the text alive). Lenient outside hunks
/// (commit-message preambles and unknown metadata lines are skipped); strict
/// inside a hunk. Pairing/refinement run per the options.
ParseExpected!DiffDoc parsePatch(const(char)[] patch,
    in DiffOptions opt = DiffOptions()) @safe pure nothrow @nogc
{
    DiffDoc doc;
    doc.oldText = patch;
    doc.newText = patch;

    FileEntry current;
    bool haveFile = false;
    Hunk hunk;
    bool inHunk = false;
    size_t remainingOld = 0, remainingNew = 0;
    uint oldLine = 0, newLine = 0;

    void finishHunk() @safe
    {
        if (!inHunk)
            return;
        hunk.rowsCount = cast(uint)(doc.rows.length - hunk.rowsStart);
        pairAndRefine(doc, hunk, opt);
        doc.hunks ~= hunk;
        current.hunksCount++;
        hunk = Hunk.init;
        inHunk = false;
    }

    void finishFile() @safe
    {
        finishHunk();
        if (haveFile)
            doc.files ~= current;
        current = FileEntry.init;
        haveFile = false;
    }

    void openFile() @safe
    {
        if (haveFile)
            return;
        haveFile = true;
        current.hunksStart = cast(uint) doc.hunks.length;
        current.hunksCount = 0;
    }

    size_t pos = 0;
    while (pos < patch.length)
    {
        immutable lineStart = pos;
        size_t eol = pos;
        while (eol < patch.length && patch[eol] != '\n')
            eol++;
        auto line = patch[pos .. eol];
        pos = eol < patch.length ? eol + 1 : eol;

        if (inHunk && (remainingOld > 0 || remainingNew > 0))
        {
            if (line.length == 0)
            {
                // A bare empty line inside a hunk is a context line whose
                // leading space was trimmed in transit; tolerate it.
                doc.rows ~= Row(RowKind.context, oldLine, newLine, Span(lineStart, 0));
                oldLine++;
                newLine++;
                remainingOld--;
                remainingNew--;
                continue;
            }
            const content = Span(lineStart + 1, line.length - 1);
            switch (line[0])
            {
            case ' ':
                if (remainingOld == 0 || remainingNew == 0)
                    return parseErr!DiffDoc(ParseErrorCode.unexpectedCharacter, lineStart,
                        "context row past hunk counts");
                doc.rows ~= Row(RowKind.context, oldLine, newLine, content);
                oldLine++;
                newLine++;
                remainingOld--;
                remainingNew--;
                continue;
            case '-':
                if (remainingOld == 0)
                    return parseErr!DiffDoc(ParseErrorCode.unexpectedCharacter, lineStart,
                        "removed row past hunk counts");
                doc.rows ~= Row(RowKind.removed, oldLine, 0, content);
                oldLine++;
                remainingOld--;
                continue;
            case '+':
                if (remainingNew == 0)
                    return parseErr!DiffDoc(ParseErrorCode.unexpectedCharacter, lineStart,
                        "added row past hunk counts");
                doc.rows ~= Row(RowKind.added, 0, newLine, content);
                newLine++;
                remainingNew--;
                continue;
            case '\\':
                applyNoNewline(doc, current, hunk);
                continue;
            default:
                return parseErr!DiffDoc(ParseErrorCode.unexpectedCharacter, lineStart,
                    "unknown row prefix inside hunk");
            }
        }

        if (inHunk && line.length != 0 && line[0] == '\\')
        {
            applyNoNewline(doc, current, hunk);
            continue;
        }

        if (startsWith(line, "@@ "))
        {
            if (!haveFile)
                return parseErr!DiffDoc(ParseErrorCode.unexpectedCharacter, lineStart,
                    "hunk header before any file header");
            finishHunk();
            auto header = parseHunkHeader(line, lineStart);
            if (header.hasError)
                return parseErr!DiffDoc(header.error.code, header.error.offset,
                    header.error.context);
            hunk = header.value;
            hunk.rowsStart = cast(uint) doc.rows.length;
            inHunk = true;
            remainingOld = hunk.oldCount;
            remainingNew = hunk.newCount;
            oldLine = hunk.oldStart;
            newLine = hunk.newStart;
            continue;
        }

        if (startsWith(line, "diff --git "))
        {
            finishFile();
            openFile();
            // Best-effort paths from `a/X b/Y`; ---/+++ lines refine them.
            continue;
        }
        if (startsWith(line, "--- "))
        {
            // A `---` arriving while the open file already carries content
            // starts the NEXT file. Plain `diff -u`/`diff -ru` output has no
            // `diff --git` separator (`DVM3` covers it), so without this the
            // second file's header only overwrites the first's paths and every
            // hunk piles onto one entry. After a `diff --git` line the file is
            // open but empty, which is exactly the case that must not split.
            // `inHunk` counts as content too: the hunk in progress has not
            // been folded into `hunksCount` yet when this line arrives.
            if (haveFile && (inHunk || current.hunksCount != 0 || current.binary))
                finishFile();
            finishHunk();
            openFile();
            current.oldPath = doc.internPath(stripPathPrefix(line[4 .. $]));
            continue;
        }
        if (startsWith(line, "+++ "))
        {
            openFile();
            current.newPath = doc.internPath(stripPathPrefix(line[4 .. $]));
            continue;
        }
        if (startsWith(line, "Binary files ") || startsWith(line, "GIT binary patch"))
        {
            openFile();
            current.binary = true;
            continue;
        }
        if (startsWith(line, "rename from "))
        {
            current.oldPath = doc.internPath(line["rename from ".length .. $]);
            continue;
        }
        if (startsWith(line, "copy from "))
        {
            current.oldPath = doc.internPath(line["copy from ".length .. $]);
            continue;
        }
        if (startsWith(line, "rename to "))
        {
            current.newPath = doc.internPath(line["rename to ".length .. $]);
            continue;
        }
        if (startsWith(line, "copy to "))
        {
            current.newPath = doc.internPath(line["copy to ".length .. $]);
            continue;
        }
        // index …, mode lines, similarity index, commit preambles: skipped.
    }
    finishFile();
    return parseOk(doc);
}

private bool startsWith(scope const(char)[] s, scope const(char)[] prefix)
    @safe pure nothrow @nogc
    => s.length >= prefix.length && s[0 .. prefix.length] == prefix;

private const(char)[] stripPathPrefix(return scope const(char)[] p) @safe pure nothrow @nogc
{
    if (p == "/dev/null")
        return p;
    if (p.length > 2 && (p[0] == 'a' || p[0] == 'b') && p[1] == '/')
        p = p[2 .. $];
    // Strip a trailing tab-date (POSIX diff -u style).
    foreach (i, c; p)
        if (c == '\t')
            return p[0 .. i];
    return p;
}

private void applyNoNewline(in DiffDoc doc, ref FileEntry file, in Hunk hunk)
    @safe pure nothrow @nogc
{
    if (doc.rows.length <= hunk.rowsStart)
        return;
    final switch (doc.rows[doc.rows.length - 1].kind)
    {
    case RowKind.removed:
        file.oldMissingNewline = true;
        break;
    case RowKind.added:
        file.newMissingNewline = true;
        break;
    case RowKind.context:
        file.oldMissingNewline = true;
        file.newMissingNewline = true;
        break;
    }
}

private ParseExpected!Hunk parseHunkHeader(scope const(char)[] line, size_t offset)
    @safe pure nothrow @nogc
{
    // "@@ -l[,c] +l[,c] @@[ section]"
    Hunk h;
    size_t i = 3; // past "@@ "
    if (i >= line.length || line[i] != '-')
        return parseErr!Hunk(ParseErrorCode.unexpectedCharacter, offset + i, "expected '-'");
    i++;
    if (!readNum(line, i, h.oldStart))
        return parseErr!Hunk(ParseErrorCode.unexpectedCharacter, offset + i, "old start");
    h.oldCount = 1;
    if (i < line.length && line[i] == ',')
    {
        i++;
        if (!readNum(line, i, h.oldCount))
            return parseErr!Hunk(ParseErrorCode.unexpectedCharacter, offset + i, "old count");
    }
    if (i >= line.length || line[i] != ' ')
        return parseErr!Hunk(ParseErrorCode.unexpectedCharacter, offset + i, "expected ' '");
    i++;
    if (i >= line.length || line[i] != '+')
        return parseErr!Hunk(ParseErrorCode.unexpectedCharacter, offset + i, "expected '+'");
    i++;
    if (!readNum(line, i, h.newStart))
        return parseErr!Hunk(ParseErrorCode.unexpectedCharacter, offset + i, "new start");
    h.newCount = 1;
    if (i < line.length && line[i] == ',')
    {
        i++;
        if (!readNum(line, i, h.newCount))
            return parseErr!Hunk(ParseErrorCode.unexpectedCharacter, offset + i, "new count");
    }
    if (!startsWith(line[i .. $], " @@"))
        return parseErr!Hunk(ParseErrorCode.unexpectedCharacter, offset + i, "expected ' @@'");
    return parseOk(h);
}

private bool readNum(scope const(char)[] s, ref size_t i, ref uint value)
    @safe pure nothrow @nogc
{
    if (i >= s.length || s[i] < '0' || s[i] > '9')
        return false;
    uint v = 0;
    while (i < s.length && s[i] >= '0' && s[i] <= '9')
    {
        v = v * 10 + (s[i] - '0');
        i++;
    }
    value = v;
    return true;
}

private void pairAndRefine(ref DiffDoc doc, in Hunk hunk, in DiffOptions opt)
    @safe pure nothrow @nogc
{
    scope rows = doc.rows[][hunk.rowsStart .. hunk.rowsStart + hunk.rowsCount];
    if (opt.pairRows)
        pairChangeBlocks(rows, doc.oldText, doc.newText, opt);
    if (opt.refineWords)
        refineRows(rows, doc.oldText, doc.newText, doc.emph, opt);
}

/**
Emit a `DiffDoc` as a canonical git-style unified patch into any `char`
output range (`SmallBuffer!char`, a file writer, …). `emit(parse(p))`
preserves the model exactly (byte-exactness is only guaranteed for emitter
output, not arbitrary input formats). Attributes infer from the writer.
*/
void emitPatch(Writer)(in DiffDoc doc, ref Writer w)
{
    foreach (fi; 0 .. doc.files.length)
    {
        const file = doc.files[fi];
        const oldPath = doc.pathText(file.oldPath);
        const newPath = doc.pathText(file.newPath);
        put(w, "diff --git a/");
        put(w, oldPath);
        put(w, " b/");
        put(w, newPath);
        put(w, "\n");
        if (file.binary)
        {
            put(w, "Binary files a/");
            put(w, oldPath);
            put(w, " and b/");
            put(w, newPath);
            put(w, " differ\n");
            continue;
        }
        put(w, "--- ");
        if (oldPath != "/dev/null")
            put(w, "a/");
        put(w, oldPath);
        put(w, "\n+++ ");
        if (newPath != "/dev/null")
            put(w, "b/");
        put(w, newPath);
        put(w, "\n");
        const hunks = doc.fileHunks(file);
        foreach (hi, ref hunk; hunks)
        {
            put(w, "@@ -");
            writeInteger(w, hunk.oldStart);
            if (hunk.oldCount != 1)
            {
                put(w, ",");
                writeInteger(w, hunk.oldCount);
            }
            put(w, " +");
            writeInteger(w, hunk.newStart);
            if (hunk.newCount != 1)
            {
                put(w, ",");
                writeInteger(w, hunk.newCount);
            }
            put(w, " @@\n");
            const rows = doc.hunkRows(hunk);
            foreach (ri, ref row; rows)
            {
                final switch (row.kind)
                {
                case RowKind.context:
                    put(w, " ");
                    break;
                case RowKind.removed:
                    put(w, "-");
                    break;
                case RowKind.added:
                    put(w, "+");
                    break;
                }
                put(w, doc.rowText(row));
                put(w, "\n");
                immutable lastRow = hi + 1 == hunks.length && ri + 1 == rows.length;
                if (lastRow && noNewlineMarkerAfter(file, row.kind))
                    put(w, "\\ No newline at end of file\n");
            }
        }
    }
}

private bool noNewlineMarkerAfter(in FileEntry file, RowKind kind) @safe pure nothrow @nogc
{
    final switch (kind)
    {
    case RowKind.removed:
        return file.oldMissingNewline;
    case RowKind.added:
        return file.newMissingNewline;
    case RowKind.context:
        return file.oldMissingNewline || file.newMissingNewline;
    }
}

version (unittest)
{
    /// Structural model equality: content-wise, through the accessors (the
    /// arenas' raw indices may differ between equal documents).
    private bool sameDoc(in DiffDoc a, in DiffDoc b) @safe pure nothrow @nogc
    {
        if (a.files.length != b.files.length)
            return false;
        foreach (fi; 0 .. a.files.length)
        {
            const fa = a.files[fi], fb = b.files[fi];
            if (a.pathText(fa.oldPath) != b.pathText(fb.oldPath)
                || a.pathText(fa.newPath) != b.pathText(fb.newPath)
                || fa.binary != fb.binary
                || fa.oldMissingNewline != fb.oldMissingNewline
                || fa.newMissingNewline != fb.newMissingNewline
                || fa.hunksCount != fb.hunksCount)
                return false;
            const hsA = a.fileHunks(fa), hsB = b.fileHunks(fb);
            foreach (hi; 0 .. hsA.length)
            {
                const ha = hsA[hi], hb = hsB[hi];
                if (ha.oldStart != hb.oldStart || ha.oldCount != hb.oldCount
                    || ha.newStart != hb.newStart || ha.newCount != hb.newCount
                    || ha.rowsCount != hb.rowsCount)
                    return false;
                const rsA = a.hunkRows(ha), rsB = b.hunkRows(hb);
                foreach (ri; 0 .. rsA.length)
                {
                    const ra = rsA[ri], rb = rsB[ri];
                    if (ra.kind != rb.kind || ra.oldLine != rb.oldLine
                        || ra.newLine != rb.newLine
                        || a.rowText(ra) != b.rowText(rb)
                        || ra.pair != rb.pair || ra.emphCount != rb.emphCount)
                        return false;
                    const eA = a.rowEmph(ra), eB = b.rowEmph(rb);
                    foreach (si; 0 .. eA.length)
                        if (eA[si] != eB[si])
                            return false;
                }
            }
        }
        return true;
    }
}

@("patch.parsePatch.git-sample")
@safe pure nothrow @nogc
unittest
{
    enum sample = "diff --git a/foo.txt b/foo.txt\n"
        ~ "index 1234567..89abcde 100644\n"
        ~ "--- a/foo.txt\n"
        ~ "+++ b/foo.txt\n"
        ~ "@@ -1,3 +1,3 @@\n"
        ~ " one\n"
        ~ "-two\n"
        ~ "+2\n"
        ~ " three\n";
    auto res = parsePatch(sample);
    assert(res.hasValue);
    const doc = res.value;
    assert(doc.files.length == 1);
    const f = doc.files[0];
    assert(doc.pathText(f.oldPath) == "foo.txt");
    assert(doc.pathText(f.newPath) == "foo.txt");
    assert(f.hunksCount == 1);
    const rows = doc.hunkRows(doc.fileHunks(f)[0]);
    assert(rows.length == 4);
    assert(rows[1].kind == RowKind.removed && doc.rowText(rows[1]) == "two"
        && rows[1].oldLine == 2);
    assert(rows[2].kind == RowKind.added && doc.rowText(rows[2]) == "2"
        && rows[2].newLine == 2);
    // Pairing ran: "two" ↔ "2" are dissimilar (below floor) → unpaired.
    assert(rows[1].pair == -1);
}

@("patch.parsePatch.no-newline-marker")
@safe pure nothrow @nogc
unittest
{
    enum sample = "--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n\\ No newline at end of file\n";
    auto res = parsePatch(sample);
    assert(res.hasValue);
    assert(res.value.files[0].newMissingNewline);
    assert(!res.value.files[0].oldMissingNewline);
}

@("patch.parsePatch.lenient-preamble-strict-hunks")
@safe pure nothrow @nogc
unittest
{
    // Preamble junk is skipped; a bad row prefix inside a hunk errors.
    auto ok1 = parsePatch("commit message line\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n");
    assert(ok1.hasValue && ok1.value.files.length == 1);

    auto bad = parsePatch("--- a/x\n+++ b/x\n@@ -1,2 +1 @@\n-a\n?bogus\n");
    assert(bad.hasError);
    assert(bad.error.code == ParseErrorCode.unexpectedCharacter);
}

@("patch.parsePatch.plain-diff-u-splits-files")
@safe pure nothrow @nogc
unittest
{
    // `diff -ru` output has no `diff --git` separator: the only boundary
    // between two files is the second `---` line (`DVM3`). Each file must land
    // as its own entry with its own hunks — this used to collapse into one
    // entry whose paths were the last file's.
    enum plain =
        "--- a/one.txt\n+++ b/one.txt\n@@ -1,2 +1,2 @@\n one\n-two\n+2\n" ~
        "--- a/two.txt\n+++ b/two.txt\n@@ -1 +1 @@\n-x\n+y\n";

    auto res = parsePatch(plain);
    assert(res.hasValue);
    const doc = res.value;
    assert(doc.files.length == 2);
    assert(doc.pathText(doc.files[0].oldPath) == "one.txt");
    assert(doc.pathText(doc.files[1].oldPath) == "two.txt");
    assert(doc.files[0].hunksCount == 1 && doc.files[1].hunksCount == 1);
    assert(doc.hunkRows(doc.fileHunks(doc.files[1])[0]).length == 2);

    // The `diff --git` form still opens exactly one file per header: there the
    // `---` follows an open-but-empty entry and must not split it.
    auto git = parsePatch(
        "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n");
    assert(git.hasValue && git.value.files.length == 1);
}

@("patch.emitPatch.round-trip-model")
@safe pure nothrow @nogc
unittest
{
    enum sample = "diff --git a/foo.txt b/foo.txt\n"
        ~ "--- a/foo.txt\n"
        ~ "+++ b/foo.txt\n"
        ~ "@@ -1,3 +1,3 @@\n"
        ~ " one\n"
        ~ "-two\n"
        ~ "+2\n"
        ~ " three\n";
    const doc1 = parsePatch(sample).value;
    SmallBuffer!char emitted;
    emitPatch(doc1, emitted);
    const doc2 = parsePatch(emitted[]).value;
    assert(sameDoc(doc1, doc2));
    // Emitter output is a fixed point.
    SmallBuffer!char emitted2;
    emitPatch(doc2, emitted2);
    assert(emitted2[] == emitted[]);
}

@("patch.parsePatch.binary-and-rename")
@safe pure nothrow @nogc
unittest
{
    enum sample = "diff --git a/img.png b/img.png\nBinary files a/img.png and b/img.png differ\n"
        ~ "diff --git a/old.d b/new.d\nsimilarity index 97%\nrename from old.d\nrename to new.d\n"
        ~ "--- a/old.d\n+++ b/new.d\n@@ -1 +1 @@\n-x\n+y\n";
    const doc = parsePatch(sample).value;
    assert(doc.files.length == 2);
    assert(doc.files[0].binary && doc.files[0].hunksCount == 0);
    assert(doc.pathText(doc.files[1].oldPath) == "old.d");
    assert(doc.pathText(doc.files[1].newPath) == "new.d");
}
