/**
Example tests for the editor step, one or more per requirement of
`docs/specs/ui/editor.md`. Readline behaviour follows Readline 8.3's
`text.c` and `kill.c` at the pinned revision.
*/
module sparkles.ui.editor.step_test;

version (unittest):

import core.time : msecs;

import sparkles.text_buffer.summary : Affinity;
import sparkles.ui.editor.command : Boundary, EditCommand, EditKind;
import sparkles.ui.editor.effect : EffectKind, NoopReason;
import sparkles.ui.editor.selection : EditRange;
import sparkles.ui.editor.state : EditorOptions, ReadOnlySpan;
import sparkles.ui.editor.testing : Harness, parse, show;

alias C = EditCommand;
alias K = EditKind;

@("editor.marked.roundTrip")
@safe pure nothrow
unittest
{
    foreach (marked; ["ab|c", "a[bc]d", "a]bc[d", "|x|y", "[ab] |c"])
        assert(show(parse(marked)) == marked, marked);
}

/// EDC1 and EDT5: typing replaces every range; one change set.
@("editor.insert.everyRange")
@safe pure nothrow
unittest
{
    auto h = Harness("a|b[cd]e");
    h.type("X");
    assert(h.shown == "aX|bX|e");
    assert(h.effects.has(EffectKind.changed));
}

/// EDC2 and EDT3: motion and deletion step whole grapheme clusters.
@("editor.grapheme.wholeClusters")
@safe pure nothrow
unittest
{
    auto h = Harness("|é\U0001F1FA\U0001F1F8x");
    h.run(C.grapheme(1));
    assert(h.shown == "é|\U0001F1FA\U0001F1F8x");
    h.run(C.grapheme(1));
    assert(h.shown == "é\U0001F1FA\U0001F1F8|x");
    h.run(C.deleteGrapheme(-1));
    assert(h.shown == "é|x", "one flag, all eight bytes");
    // Moving a non-empty range collapses it.
    auto r = Harness("a[bc]d");
    r.run(C.grapheme(-1));
    assert(r.shown == "a|bcd");
    r = Harness("a[bc]d");
    r.run(C.grapheme(1));
    assert(r.shown == "abc|d");
    // Extending keeps the anchor.
    r = Harness("a|bcd");
    r.run(C.grapheme(1, true)).run(C.grapheme(1, true));
    assert(r.shown == "a[bc]d");
}

/// EDC3: Alt-F/Alt-B skip non-words then one word, as Readline's
/// `rl_forward_word`; Alt-Backspace and Alt-D kill the same span.
@("editor.word.motionAndKill")
@safe pure nothrow
unittest
{
    auto h = Harness("|foo/bar  baz");
    h.run(C.word(1));
    assert(h.shown == "foo|/bar  baz");
    h.run(C.word(1));
    assert(h.shown == "foo/bar|  baz");
    h.run(C.word(-1));
    assert(h.shown == "foo/|bar  baz");
    // UAX #29 keeps `foo.bar` one word: `.` is MidNumLet, as in "e.g.".
    auto dotted = Harness("|foo.bar x");
    dotted.run(C.word(1));
    assert(dotted.shown == "foo.bar| x");
    auto k = Harness("cd ~/src/sparkles|");
    k.run(C.killWord(-1));
    assert(k.shown == "cd ~/src/|", "Alt-Backspace removes one component");
    k.run(C.killWord(1));
    assert(k.effects.has(EffectKind.noop));
}

/// EDC3: Ctrl-W kills back over blanks, then one blank-delimited run, as
/// `rl_unix_word_rubout`.
@("editor.killBlankWord.wholePath")
@safe pure nothrow
unittest
{
    auto h = Harness("cd ~/src/sparkles  |");
    h(K.killBlankWord);
    assert(h.shown == "cd |");
    h(K.killBlankWord);
    assert(h.shown == "|");
}

/// EDY2 and EDY3: consecutive kills join one entry; yank reinserts it, and
/// yank-pop cycles older entries in place.
@("editor.killRing.joinYankAndPop")
@safe pure nothrow
unittest
{
    auto h = Harness("one two three|");
    h.run(C.killWord(-1)).run(C.killWord(-1));
    assert(h.shown == "one |");
    assert(h.ring.length == 1 && h.ring.at(0).part(0) == "two three");
    h.run(C.lineBoundary(Boundary.start)).run(C.killToLineBoundary(Boundary.end));
    assert(h.shown == "|");
    assert(h.ring.length == 2 && h.ring.at(0).part(0) == "one ");
    h(K.yank);
    assert(h.shown == "one |");
    h(K.yankPop);
    assert(h.shown == "two three|", "yank-pop replaces the yank with the older kill");
    h(K.yankPop);
    assert(h.shown == "one |", "and cycles");
    h.run(C.grapheme(-1));
    h(K.yankPop);
    assert(h.effects.has(EffectKind.noop), "yank-pop needs a yank just before");
}

/// EDC4: line start, then the first non-blank; line kills take the line
/// break when already at the boundary.
@("editor.lineBoundary.toggleAndKillBreak")
@safe pure nothrow
unittest
{
    auto h = Harness("ab\n  cd|ef\ngh");
    h.run(C.lineBoundary(Boundary.start));
    assert(h.shown == "ab\n|  cdef\ngh");
    h.run(C.lineBoundary(Boundary.start));
    assert(h.shown == "ab\n  |cdef\ngh");
    h.run(C.lineBoundary(Boundary.end));
    assert(h.shown == "ab\n  cdef|\ngh");
    h.run(C.killToLineBoundary(Boundary.end));
    assert(h.shown == "ab\n  cdef|gh", "at the end, Ctrl-K kills the break");
    h.run(C.killToLineBoundary(Boundary.start));
    assert(h.shown == "ab\n|gh");
    h.run(C.killToLineBoundary(Boundary.start));
    assert(h.shown == "ab|gh");
}

/// EDC5 and EDT7: vertical motion keeps the goal column over short lines.
@("editor.vertical.goalColumn")
@safe pure nothrow
unittest
{
    auto h = Harness("abcd|ef\nx\nabcdef");
    h.run(C.line(1));
    assert(h.shown == "abcdef\nx|\nabcdef");
    h.run(C.line(1));
    assert(h.shown == "abcdef\nx\nabcd|ef", "the goal column survives the short line");
    h.run(C.line(1));
    assert(h.shown == "abcdef\nx\nabcdef|", "past the last line: the end");
    h.run(C.document(Boundary.start));
    assert(h.shown == "|abcdef\nx\nabcdef");
}

/// EDC6: select all, word and line; collapse to the primary.
@("editor.selection.commands")
@safe pure nothrow
unittest
{
    auto h = Harness("ab cd|ef gh");
    h(K.selectWord);
    assert(h.shown == "ab [cdef] gh");
    h(K.selectAll);
    assert(h.shown == "[ab cdef gh]");
    auto l = Harness("one\ntw|o\nthree");
    l(K.selectLine);
    assert(l.shown == "one\n[two\n]three");
    auto m = Harness("a|b|c|");
    m(K.collapseToPrimary);
    assert(m.shown == "abc|");
}

/// EDC7: add next occurrence selects the word, then the next match,
/// whole words only when the primary is one.
@("editor.multi.addNextOccurrence")
@safe pure nothrow
unittest
{
    auto h = Harness("fo|o food foo foo");
    h(K.addNextOccurrence);
    assert(h.shown == "[foo] food foo foo");
    h(K.addNextOccurrence);
    assert(h.shown == "[foo] food [foo] foo", "`food` is skipped: whole words");
    h(K.addNextOccurrence)(K.addNextOccurrence);
    assert(h.effects.has(EffectKind.noop) && h.state.selection.length == 3);
    h.type("bar");
    assert(h.shown == "bar| food bar| bar|");
    auto all = Harness("x[ab]x ab abab");
    all(K.selectAllOccurrences);
    assert(all.shown == "x[ab]x [ab] [ab][ab]", "a non-word primary matches inside words");
}

/// EDC7: cursors above and below, split into lines, column select.
@("editor.multi.verticalSplitAndColumns")
@safe pure nothrow
unittest
{
    auto h = Harness("abc|d\nx\nabcd");
    h.run(C.cursorVertical(1));
    assert(h.shown == "abc|d\nx\nabc|d", "the short line is skipped");
    auto s = Harness("a[b\ncd\ne]f");
    s(K.splitIntoLines);
    assert(s.shown == "a[b]\n[cd]\n[e]f");
    auto c = Harness("abcd\nab\nabcd");
    c.run(C.columnSelect(1, 11));
    assert(c.shown == "a[bc]d\na[b]\na[bc]d", "a short line clips to its end");
    c.run(C.addRangeAt(0));
    assert(c.state.selection.length == 4);
    c.run(C.removeRangeAt(0));
    assert(c.state.selection.length == 3);
}

/// EDT6 and EDC8: quick typing coalesces into one undo step, slow typing
/// does not; undo restores ranges; an edit after undo branches.
@("editor.history.coalescingAndBranches")
@safe pure nothrow
unittest
{
    auto h = Harness("|");
    h.type("a", 10).type("b", 10).type("c", 2000).type("d", 10);
    assert(h.shown == "abcd|");
    h(K.undo);
    assert(h.shown == "abc|", "`d` came 2 s after `c`");
    h(K.undo);
    assert(h.shown == "|", "`a`, `b`, `c` were one step");
    h(K.undo);
    assert(h.effects.has(EffectKind.noop)
        && h.effects.first(EffectKind.noop).reason == NoopReason.nothingToUndo);
    h(K.redo);
    assert(h.shown == "abc|");
    h.type("X");
    assert(h.shown == "abcX|");
    h.run(C.earlier(1));
    assert(h.shown == "abcd|", "earlier reaches the abandoned branch");
    // A paste is never coalesced.
    auto p = Harness("|");
    p.type("a", 10).pasted("bc");
    p(K.undo);
    assert(p.shown == "a|");
}

/// EDY5: paste is a request; only the answer to the pending request,
/// before focus is lost, is inserted.
@("editor.clipboard.requestAndAnswer")
@safe pure nothrow
unittest
{
    auto h = Harness("a[bc]d");
    h.context.clipboardRead = true; // this host answers reads
    h(K.copy);
    assert(h.effects.has(EffectKind.writeClipboard)
        && h.effects.first(EffectKind.writeClipboard).text == "bc");
    h(K.cut);
    assert(h.shown == "a|d");
    h(K.paste);
    const request = h.effects.first(EffectKind.readClipboard).request;
    h.run(C.pasteAnswer(request + 1, h.intern("no")));
    assert(h.effects.first(EffectKind.noop).reason == NoopReason.staleAnswer);
    h.run(C.pasteAnswer(request, h.intern("XY")));
    assert(h.shown == "aXY|d");
    h(K.paste);
    const second = h.effects.first(EffectKind.readClipboard).request;
    h(K.blur);
    h.run(C.pasteAnswer(second, h.intern("late")));
    assert(h.shown == "aXY|d", "focus was lost before the answer");
}

/// EDY4: a paste with as many lines as ranges gives one line to each.
@("editor.paste.distribution")
@safe pure nothrow
unittest
{
    auto h = Harness("a|\nb|\nc|");
    h.pasted("1\n2\n3\n");
    assert(h.shown == "a1|\nb2|\nc3|");
    auto w = Harness("a|\nb|");
    w.pasted("x\ny\nz");
    assert(w.shown == "ax\ny\nz|\nbx\ny\nz|", "three lines, two ranges: the whole text each");
}

/// EDT8: single-line mode never holds a line break.
@("editor.singleLine")
@safe pure nothrow
unittest
{
    EditorOptions options;
    options.singleLine = true;
    auto h = Harness("ab|", options);
    h(K.insertNewline);
    assert(h.effects.has(EffectKind.submit) && h.shown == "ab|");
    h.pasted("c\r\nd\ne");
    assert(h.shown == "abc d e|");
    h.run(C.line(1));
    assert(h.effects.first(EffectKind.noop).reason == NoopReason.singleLine);
}

/// EDU4: a field can accept only some scalars.
@("editor.accepts.digitsOnly")
@safe pure nothrow
unittest
{
    EditorOptions options;
    options.singleLine = true;
    options.accepts = (dchar c) => c >= '0' && c <= '9';
    auto h = Harness("|", options);
    h.type("12").type("x").type("3");
    assert(h.shown == "123|");
}

/// EDT10: edits inside a read-only span are dropped for that range only;
/// its edges stay editable.
@("editor.readOnly.spans")
@safe pure nothrow
unittest
{
    auto h = Harness("ab|cd|ef|");
    h.state.readOnly.put(ReadOnlySpan(2, 4));
    h.run(C.deleteGrapheme(-1));
    assert(h.shown == "a|cd|e|", "deleting `d` would change the span; the others apply");
    assert(h.effects.has(EffectKind.rejectedReadOnly));
    h = Harness("ab|cd|ef");
    h.state.readOnly.put(ReadOnlySpan(2, 4));
    h.type("X");
    assert(h.shown == "abX|cdX|ef", "both edges of the span take insertions");
    assert(!h.effects.has(EffectKind.rejectedReadOnly));
    h = Harness("abc|def");
    h.state.readOnly.put(ReadOnlySpan(1, 5));
    h.type("X");
    assert(h.shown == "abc|def" && h.effects.has(EffectKind.rejectedReadOnly));
}

/// EDT4: ranges that meet after an edit merge.
@("editor.normalize.afterEdit")
@safe pure nothrow
unittest
{
    auto h = Harness("a|b|c");
    h.run(C.deleteGrapheme(-1)).run(C.deleteGrapheme(-1));
    assert(h.shown == "|c" && h.state.selection.length == 1);
}

/// EDC11: submit and cancel only report.
@("editor.fieldControl")
@safe pure nothrow
unittest
{
    auto h = Harness("ab|");
    h(K.submit);
    assert(h.effects.has(EffectKind.submit) && h.shown == "ab|");
    h(K.cancel);
    assert(h.effects.has(EffectKind.cancel));
}

/// An insertion that would pass `maxLength` is refused whole.
@("editor.maxLength")
@safe pure nothrow
unittest
{
    EditorOptions options;
    options.maxLength = 5;
    auto h = Harness("ab|", options);
    h.type("cd");
    assert(h.shown == "abcd|");
    h.type("ef");
    assert(h.shown == "abcd|" && h.effects.has(EffectKind.noop), "refused whole, not cut");
    h.type("e");
    assert(h.shown == "abcde|");
    h.run(C.grapheme(-1, true)).type("XY");
    assert(h.shown == "abcd]e[", "a replacement that would grow past the limit is refused too");
}

/// EDI5: without a host that answers reads, paste says so instead of waiting.
@("editor.clipboard.absentIsExplicit")
@safe pure nothrow
unittest
{
    auto h = Harness("ab|");
    h(K.paste);
    assert(h.effects.has(EffectKind.noop)
        && h.effects.first(EffectKind.noop).reason == NoopReason.capabilityAbsent);
    assert(!h.effects.has(EffectKind.readClipboard));
}
