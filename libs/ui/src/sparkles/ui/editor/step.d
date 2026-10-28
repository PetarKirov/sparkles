/**
The editor's one transition (`EDT2`):
`step(state, ring, texts, command, context) → (state, ring, effects)`.

The step is weakly pure and deterministic: it reads no clock, clipboard or
layout, only its arguments. `texts` resolves the `TextId`s a command
carries (any type with `withText(id, fn)`, such as a `TextPool`), and
`context` answers the time and the visual-line queries (`isEditContext`).

Specification: `docs/specs/ui/editor.md` §2–5.
*/
module sparkles.ui.editor.step;

import core.time : MonoTime;

import sparkles.base.buffer : SharedBuffer, UniqueBuffer;
import sparkles.base.text.seek : WordSegmentKind, isGraphemeBoundary, nextGraphemeBoundary,
    nextWordSegment, previousBlankDelimited, previousGraphemeBoundary, previousWordSegment;
import sparkles.base.text.unicode_tables : UnicodeProperty, unicodeProperty;
import sparkles.input.events : TextId;
import sparkles.text_buffer.change_set : ChangeSet, ChangeSetStatus, Edit;
import sparkles.text_buffer.history : HistoryStatus, HistoryStep;
import sparkles.text_buffer.summary : Affinity, tokenAt;
import sparkles.text_buffer.text : Text;
import sparkles.ui.editor.command : Boundary, EditCommand, EditKind;
import sparkles.ui.editor.context : VisualLine, isEditContext;
import sparkles.ui.editor.effect : EditEffect, EditEffects, EffectKind, NoopReason;
import sparkles.ui.editor.kill_ring : KillEntry, KillRing;
import sparkles.ui.editor.selection : EditRange, SelectionSet;
import sparkles.ui.editor.state : EditorState, ReadOnlySpan;

/// What one step returns.
struct StepResult
{
    EditorState state;
    KillRing ring;
    EditEffects effects;
    /// The command being run, for the motion lambdas.
    EditCommand cmd;
}

/// Whether `T` resolves input text ids: `texts.withText(id, (scope const(char)[] s) {})`.
enum bool isTextSource(T) = is(typeof((ref T texts, TextId id) {
    texts.withText(id, (scope const(char)[] s) {});
}));

/// Apply `command` to `state` (`EDT2`).
StepResult step(Texts, Context)(EditorState state, KillRing ring, ref scope Texts texts,
    in EditCommand command, ref Context context)
if (isTextSource!Texts && isEditContext!Context)
{
    import core.lifetime : move;

    // The stepper keeps the two addresses only while this call runs; dip1000
    // cannot see that it does not escape, so the borrow is vouched for here.
    auto textsAt = () @trusted { return &texts; }();
    auto contextAt = () @trusted { return &context; }();
    auto s = Stepper!(Texts, Context)(move(state), move(ring), textsAt, contextAt);
    s.run(command);
    return StepResult(move(s.state), move(s.ring), move(s.effects));
}

/**
`step` applied in place: `state` and `ring` are moved in and the results
moved back, so nothing is copied. A host that keeps one state should use
this, or pass `move(state)` to `step`: a copy shares the history, and the
step's first commit then clones it.
*/
EditEffects stepInPlace(Texts, Context)(ref EditorState state, ref KillRing ring,
    ref scope Texts texts, in EditCommand command, ref Context context)
if (isTextSource!Texts && isEditContext!Context)
{
    import core.lifetime : move;

    auto result = step(move(state), move(ring), texts, command, context);
    state = move(result.state);
    ring = move(result.ring);
    return move(result.effects);
}

private:

enum Coalesce : ubyte
{
    none,
    typing,
    deleteBack,
    deleteForward,
}

/// One range's edit: replace `[from, to)` with `inserted`.
struct RangeEdit
{
    size_t from;
    size_t to;
    Text inserted;
}

enum Motion : ubyte
{
    grapheme,
    word,
    lineBoundary,
    document,
}

enum Mapping : ubyte
{
    word,
    line,
    wordOfCaret,
}

enum KillSpan : ubyte
{
    word,
    blankWord,
    line,
}

/// Where a range goes after its edit.
enum Placement : ubyte
{
    /// A caret after the inserted text.
    afterInserted,
    /// A caret where the deleted text was.
    atStart,
    /// The inserted text selected (a yank: so `yankPop` can replace it).
    selectInserted,
}

bool isKill(EditKind kind) @safe pure nothrow @nogc
    => kind == EditKind.killWord || kind == EditKind.killBlankWord
        || kind == EditKind.killToLineBoundary;

bool whiteSpaceAt(in Text text, size_t at) @safe pure nothrow @nogc
{
    if (at >= text.length)
        return false;
    char[4] bytes;
    const n = text.length - at < 4 ? text.length - at : 4;
    text.copyTo(at, at + n, bytes[0 .. n]);
    return unicodeProperty(tokenAt(bytes[0 .. n]).scalar, UnicodeProperty.WSpace);
}

struct Stepper(Texts, Context)
{
    EditorState state;
    KillRing ring;
    Texts* texts;
    Context* context;
    EditEffects effects;
    /// The command being run, for the motion lambdas.
    EditCommand cmd;

    this(EditorState state, KillRing ring, Texts* texts, Context* context)
    {
        import core.lifetime : move;

        this.state = move(state);
        this.ring = move(ring);
        this.texts = texts;
        this.context = context;
    }

    ref const(Text) text() const return => state.text;

    void run(in EditCommand c)
    {
        cmd = c;
        const textBefore = state.text;
        const selectionBefore = state.selection;
        const last = state.record.last;
        const lastDirection = state.record.lastDirection;
        bool keepKillRun;
        bool keepYank;

        final switch (c.kind)
        {
        case EditKind.none:
            break;
        case EditKind.insertText:
            insertText(resolve(c.text), c.paste,
                c.paste ? Coalesce.none : Coalesce.typing, last);
            break;
        case EditKind.insertNewline:
            if (state.options.singleLine)
                effects.put(EditEffect(EffectKind.submit));
            else
                insertText(Text("\n"), false, Coalesce.none, last);
            break;
        case EditKind.insertTab:
            if (state.options.tabInserts)
                insertText(Text("\t"), false, Coalesce.none, last);
            break;
        case EditKind.moveGrapheme:
            moveEach(Motion.grapheme, c.extend);
            break;
        case EditKind.deleteGrapheme:
            deleteGrapheme(c.direction, last, lastDirection);
            break;
        case EditKind.moveWord:
            moveEach(Motion.word, c.extend);
            break;
        case EditKind.killWord:
            kill(KillSpan.word, cmd.direction < 0, last);
            keepKillRun = true;
            break;
        case EditKind.killBlankWord:
            kill(KillSpan.blankWord, true, last);
            keepKillRun = true;
            break;
        case EditKind.moveLineBoundary:
            moveEach(Motion.lineBoundary, c.extend);
            break;
        case EditKind.killToLineBoundary:
            kill(KillSpan.line, c.boundary == Boundary.start, last);
            keepKillRun = true;
            break;
        case EditKind.moveLine:
        case EditKind.movePage:
            if (state.options.singleLine)
            {
                effects.put(noop(NoopReason.singleLine));
                break;
            }
            const steps = c.kind == EditKind.moveLine ? 1 : context.viewportLines;
            moveVertical(c.direction, steps, c.extend);
            break;
        case EditKind.moveDocument:
            moveEach(Motion.document, c.extend);
            break;
        case EditKind.selectAll:
            setSelection(SelectionSet.single(EditRange(0, text.length)));
            break;
        case EditKind.selectWord:
            mapEach(Mapping.word);
            break;
        case EditKind.selectLine:
            mapEach(Mapping.line);
            break;
        case EditKind.collapseToPrimary:
            collapseToPrimary();
            break;
        case EditKind.setRange:
            setSelection(SelectionSet.single(EditRange(clampSnap(c.a, Affinity.before),
                clampSnap(c.b, Affinity.before))));
            break;
        case EditKind.addNextOccurrence:
            addNextOccurrence(false);
            break;
        case EditKind.skipOccurrence:
            addNextOccurrence(true);
            break;
        case EditKind.selectAllOccurrences:
            selectAllOccurrences();
            break;
        case EditKind.addCursorVertical:
            addCursorVertical(c.direction);
            break;
        case EditKind.splitIntoLines:
            splitIntoLines();
            break;
        case EditKind.addRangeAt:
            addRangeAt(c.a);
            break;
        case EditKind.removeRangeAt:
            removeRangeAt(c.a);
            break;
        case EditKind.columnSelect:
            columnSelect(c.a, c.b);
            break;
        case EditKind.undo:
            travel(state.history.undo(), NoopReason.nothingToUndo);
            break;
        case EditKind.redo:
            travel(state.history.redo(), NoopReason.nothingToRedo);
            break;
        case EditKind.earlier:
            travel(state.history.earlier(c.a), NoopReason.nothingToUndo);
            break;
        case EditKind.later:
            travel(state.history.later(c.a), NoopReason.nothingToRedo);
            break;
        case EditKind.yank:
            yank();
            keepYank = true;
            break;
        case EditKind.yankPop:
            keepYank = yankPop(last);
            break;
        case EditKind.copy:
            copy();
            break;
        case EditKind.cut:
            if (copy())
                deleteRanges(Coalesce.none, last);
            break;
        case EditKind.paste:
            paste();
            break;
        case EditKind.pasteAnswer:
            pasteAnswer(c.request, c.text, last);
            break;
        case EditKind.compose:
        case EditKind.commitComposition:
            // Composition arrives with E2; until then a target declares it
            // absent (`EDI5`).
            effects.put(noop(NoopReason.capabilityAbsent));
            break;
        case EditKind.submit:
            effects.put(EditEffect(EffectKind.submit));
            break;
        case EditKind.escape:
            if (state.selection.length > 1 || !state.selection.primary.empty)
                collapseToPrimary();
            else
                effects.put(EditEffect(EffectKind.cancel));
            break;
        case EditKind.cancel:
            effects.put(EditEffect(EffectKind.cancel));
            break;
        case EditKind.blur:
            state.record.pendingRequest = 0;
            break;
        }

        // EDT5: a command that changed nothing says why.
        if (effects.length == 0 && state.text == textBefore && state.selection == selectionBefore
            && c.kind != EditKind.blur && c.kind != EditKind.none)
            effects.put(noop(NoopReason.nothingToDo));

        state.record.last = c.kind;
        state.record.lastDirection = c.direction;
        if (!keepKillRun)
            state.record.killRun = 0;
        if (!keepYank)
        {
            state.record.yanked = typeof(state.record.yanked).init;
            state.record.yankAge = 0;
        }
        // EDT6: anything but an edit ends a run of coalescing edits.
        if (state.text == textBefore)
            state.record.coalescible = false;
    }

    static EditEffect noop(NoopReason reason) => EditEffect(EffectKind.noop, reason);

    Text resolve(TextId id)
    {
        Text result;
        texts.withText(id, (scope const(char)[] bytes) { result = Text(bytes); });
        return result;
    }

    // ------------------------------------------------------------ positions

    /// `p` moved to a grapheme boundary of the current text (`EDT3`).
    size_t snap(size_t p, Affinity affinity) const
    {
        if (p >= text.length)
            return text.length;
        if (isGraphemeBoundary(text, p))
            return p;
        return affinity == Affinity.before ? previousGraphemeBoundary(text, p)
            : nextGraphemeBoundary(text, p);
    }

    size_t clampSnap(size_t p, Affinity affinity) const
        => snap(p > text.length ? text.length : p, affinity);

    /// A selection with every endpoint snapped, then normalized.
    SelectionSet normalized(scope const(EditRange)[] ranges, size_t primary) const
    {
        SharedBuffer!(EditRange, 4) snapped;
        foreach (r; ranges)
        {
            EditRange s = r;
            s.anchor = snap(r.anchor, r.forward ? Affinity.before : Affinity.after);
            s.head = snap(r.head, r.affinity);
            snapped.put(s);
        }
        return SelectionSet.of(snapped[], primary);
    }

    void setSelection(SelectionSet selection)
    {
        state.selection = normalized(selection.ranges, selection.primaryIndex);
    }

    // --------------------------------------------------------------- motion

    /// Every range's head moved by `motion`; the anchor follows unless
    /// `extend`. A goal column is kept only by vertical motion.
    void moveEach(Motion motion, bool extend)
    {
        SharedBuffer!(EditRange, 4) moved;
        foreach (r; state.selection.ranges)
        {
            const head = target(motion, r);
            moved.put(EditRange(extend ? r.anchor : head, head));
        }
        state.selection = normalized(moved[], state.selection.primaryIndex);
    }

    size_t target(Motion motion, in EditRange r)
    {
        final switch (motion)
        {
        case Motion.grapheme:
            return graphemeTarget(r, cmd.direction, cmd.extend);
        case Motion.word:
            return wordTarget(r.head, cmd.direction);
        case Motion.lineBoundary:
            return lineBoundaryTarget(r.head, cmd.boundary);
        case Motion.document:
            return cmd.boundary == Boundary.start ? 0 : text.length;
        }
    }

    /// Every range replaced by its `mapping`.
    void mapEach(Mapping mapping)
    {
        SharedBuffer!(EditRange, 4) mapped;
        foreach (r; state.selection.ranges)
        {
            final switch (mapping)
            {
            case Mapping.word:
                mapped.put(wordAround(r.head));
                break;
            case Mapping.line:
                mapped.put(lineAround(r.head));
                break;
            case Mapping.wordOfCaret:
                mapped.put(r.empty ? wordAround(r.head) : r);
                break;
            }
        }
        state.selection = normalized(mapped[], state.selection.primaryIndex);
    }

    size_t graphemeTarget(in EditRange r, int direction, bool extend) const
    {
        // EDC2: moving a non-empty range collapses it instead.
        if (!extend && !r.empty)
            return direction < 0 ? r.start : r.end;
        return direction < 0 ? previousGraphemeBoundary(text, r.head)
            : nextGraphemeBoundary(text, r.head);
    }

    /// EDC3: skip segments that are not words, then one word.
    size_t wordTarget(size_t p, int direction) const
    {
        if (direction > 0)
        {
            while (p < text.length)
            {
                const segment = nextWordSegment(text, p);
                p = segment.end;
                if (segment.kind == WordSegmentKind.word)
                    break;
            }
            return p;
        }
        while (p > 0)
        {
            const segment = previousWordSegment(text, p);
            p = segment.start;
            if (segment.kind == WordSegmentKind.word)
                break;
        }
        return p;
    }

    VisualLine lineAt(size_t p) => context.lineAt(text, p, Affinity.before);

    size_t firstNonBlank(VisualLine line)
    {
        size_t p = line.start;
        while (p < line.end && whiteSpaceAt(text, p))
            p = nextGraphemeBoundary(text, p);
        return p;
    }

    /// EDC4: line start, toggling to the first non-blank when already there.
    size_t lineBoundaryTarget(size_t p, Boundary boundary)
    {
        const line = lineAt(p);
        if (boundary == Boundary.end)
            return line.end;
        return p == line.start ? firstNonBlank(line) : line.start;
    }

    /// EDC4: where a line kill from `p` ends; the line break itself when `p`
    /// is already at the boundary.
    size_t killLineTarget(size_t p, Boundary boundary)
    {
        const line = lineAt(p);
        if (boundary == Boundary.end)
        {
            if (p < line.end)
                return line.end;
            VisualLine below;
            return context.lineBelow(text, line, below) ? below.start : p;
        }
        if (p > line.start)
            return line.start;
        VisualLine above;
        return context.lineAbove(text, line, above) ? above.end : p;
    }

    void moveVertical(int direction, size_t steps, bool extend)
    {
        SharedBuffer!(EditRange, 4) moved;
        foreach (r; state.selection.ranges)
        {
            auto line = lineAt(r.head);
            const goal = r.goal != EditRange.noGoal ? r.goal : context.columnOf(text, line, r.head);
            size_t head = r.head;
            foreach (_; 0 .. steps)
            {
                VisualLine next;
                const found = direction < 0 ? context.lineAbove(text, line, next)
                    : context.lineBelow(text, line, next);
                if (!found)
                {
                    head = direction < 0 ? 0 : text.length;
                    break;
                }
                line = next;
                head = context.positionAt(text, line, goal);
            }
            auto range = EditRange(extend ? r.anchor : head, head);
            range.goal = goal;
            moved.put(range);
        }
        state.selection = normalized(moved[], state.selection.primaryIndex);
    }

    // ------------------------------------------------------------ selection

    EditRange wordAround(size_t p) const
    {
        const forward = nextWordSegment(text, p);
        if (forward.kind == WordSegmentKind.word && forward.start < forward.end)
            return EditRange(forward.start, forward.end);
        const backward = previousWordSegment(text, p);
        if (backward.kind == WordSegmentKind.word && backward.start < backward.end)
            return EditRange(backward.start, backward.end);
        return forward.start < forward.end ? EditRange(forward.start, forward.end)
            : EditRange(backward.start, backward.end);
    }

    EditRange lineAround(size_t p) const
    {
        const line = text.lineOf(p);
        const end = line + 1 < text.lineCount ? text.lineStart(line + 1) : text.length;
        return EditRange(text.lineStart(line), end);
    }

    void collapseToPrimary()
    {
        const primary = state.selection.primary;
        if (state.selection.length > 1)
            state.selection = SelectionSet.single(primary);
        else if (!primary.empty)
            state.selection = SelectionSet.caret(primary.head);
    }

    // ------------------------------------------------------ multiple cursors

    bool wholeWord(in EditRange r) const
    {
        if (r.empty)
            return false;
        const segment = nextWordSegment(text, r.start);
        return segment.kind == WordSegmentKind.word && segment.start == r.start
            && segment.end == r.end;
    }

    /// The first occurrence of the primary range's text starting at or
    /// after `from`, wrapping, not already selected; `false` with no match.
    bool findOccurrence(size_t from, out EditRange found)
    {
        const primary = state.selection.primary;
        const needle = text.slice(primary.start, primary.end);
        const whole = wholeWord(primary);
        size_t[2] starts = [from, 0];
        size_t[2] limits = [text.length, from];
        foreach (pass; 0 .. 2)
        {
            size_t at = starts[pass];
            while (true)
            {
                const match = find(needle, at, limits[pass]);
                if (match == size_t.max)
                    break;
                const candidate = EditRange(match, match + needle.length);
                if (!selected(candidate) && (!whole || wholeWord(candidate)))
                {
                    found = candidate;
                    return true;
                }
                at = match + 1;
            }
        }
        return false;
    }

    bool selected(in EditRange candidate) const
    {
        foreach (r; state.selection.ranges)
            if (r.start == candidate.start && r.end == candidate.end)
                return true;
        return false;
    }

    /// Start of the first occurrence of `needle` starting in `[from, limit)`.
    size_t find(in Text needle, size_t from, size_t limit) const
    {
        const n = needle.length;
        if (n == 0 || n > text.length)
            return size_t.max;
        // Knuth–Morris–Pratt over the text's chunks.
        SharedBuffer!(char, 32) pattern;
        foreach (chunk; needle.chunks)
            pattern.put(chunk.bytes);
        const p = pattern[];
        SharedBuffer!(size_t, 32) failure;
        foreach (_; 0 .. n)
            failure.put(0);
        auto fail = failure[];
        for (size_t i = 1, k = 0; i < n; ++i)
        {
            while (k && p[i] != p[k])
                k = fail[k - 1];
            if (p[i] == p[k])
                ++k;
            fail[i] = k;
        }
        if (from >= text.length || from >= limit)
            return size_t.max;
        size_t matched;
        foreach (chunk; text.chunks(from))
        {
            foreach (j, ch; chunk.bytes)
            {
                const at = chunk.start + j;
                if (at < from)
                    continue;
                if (at + 1 >= limit + n)
                    return size_t.max; // any match ending here starts past the limit
                while (matched && ch != p[matched])
                    matched = fail[matched - 1];
                if (ch == p[matched])
                    ++matched;
                if (matched == n)
                {
                    const start = at + 1 - n;
                    // A match must not split a cluster at either end.
                    if (isGraphemeBoundary(text, start) && isGraphemeBoundary(text, at + 1))
                        return start;
                    matched = fail[matched - 1];
                }
            }
        }
        return size_t.max;
    }

    void addNextOccurrence(bool skip)
    {
        // A caret first selects its word.
        bool anyCaret;
        foreach (r; state.selection.ranges)
            anyCaret = anyCaret || r.empty;
        if (anyCaret)
        {
            mapEach(Mapping.wordOfCaret);
            return;
        }
        size_t after;
        foreach (r; state.selection.ranges)
            if (r.end > after)
                after = r.end;
        EditRange found;
        if (!findOccurrence(after, found))
        {
            effects.put(noop(NoopReason.noMatch));
            return;
        }
        SharedBuffer!(EditRange, 4) next;
        foreach (i, r; state.selection.ranges)
            if (!skip || i != state.selection.primaryIndex)
                next.put(r);
        next.put(found);
        state.selection = normalized(next[], next.length - 1);
    }

    void selectAllOccurrences()
    {
        const primary = state.selection.primary;
        if (primary.empty)
        {
            mapEach(Mapping.wordOfCaret);
            if (state.selection.primary.empty)
                return;
        }
        const p = state.selection.primary;
        const needle = text.slice(p.start, p.end);
        const whole = wholeWord(p);
        SharedBuffer!(EditRange, 4) all;
        size_t primaryAt;
        for (size_t at = 0;;)
        {
            const match = find(needle, at, text.length);
            if (match == size_t.max)
                break;
            const candidate = EditRange(match, match + needle.length);
            if (!whole || wholeWord(candidate))
            {
                if (match == p.start)
                    primaryAt = all.length;
                all.put(candidate);
            }
            at = match + 1;
        }
        state.selection = normalized(all[], primaryAt);
    }

    void addCursorVertical(int direction)
    {
        const ranges = state.selection.ranges;
        const from = direction < 0 ? ranges[0] : ranges[$ - 1];
        auto line = lineAt(from.head);
        const goal = from.goal != EditRange.noGoal ? from.goal : context.columnOf(text, line, from.head);
        while (true)
        {
            VisualLine next;
            const found = direction < 0 ? context.lineAbove(text, line, next)
                : context.lineBelow(text, line, next);
            if (!found)
            {
                effects.put(noop(NoopReason.nothingToDo));
                return;
            }
            line = next;
            // Skip lines too short to reach the goal column.
            if (context.columnOf(text, line, line.end) < goal)
                continue;
            auto caret = EditRange.caret(context.positionAt(text, line, goal));
            caret.goal = goal;
            SharedBuffer!(EditRange, 4) next2;
            foreach (r; ranges)
                next2.put(r);
            next2.put(caret);
            state.selection = normalized(next2[], next2.length - 1);
            return;
        }
    }

    void splitIntoLines()
    {
        SharedBuffer!(EditRange, 4) split;
        size_t primary;
        foreach (i, r; state.selection.ranges)
        {
            if (i == state.selection.primaryIndex)
                primary = split.length;
            if (r.empty)
            {
                split.put(r);
                continue;
            }
            const first = text.lineOf(r.start);
            const last = text.lineOf(r.end);
            foreach (line; first .. last + 1)
            {
                const start = line == first ? r.start : text.lineStart(line);
                const end = line == last ? r.end : text.lineEnd(line);
                if (line == last && end == start && line != first)
                    continue; // a range ending at a line start covers no more of it
                split.put(EditRange(start, end));
            }
        }
        state.selection = normalized(split[], primary);
    }

    void addRangeAt(size_t position)
    {
        SharedBuffer!(EditRange, 4) next;
        foreach (r; state.selection.ranges)
            next.put(r);
        next.put(EditRange.caret(clampSnap(position, Affinity.before)));
        state.selection = normalized(next[], next.length - 1);
    }

    void removeRangeAt(size_t position)
    {
        const ranges = state.selection.ranges;
        if (ranges.length < 2)
            return;
        SharedBuffer!(EditRange, 4) next;
        size_t primary = state.selection.primaryIndex;
        bool removed;
        foreach (i, r; ranges)
        {
            if (!removed && position >= r.start && position <= r.end)
            {
                removed = true;
                if (i < primary)
                    --primary;
                else if (i == primary)
                    primary = 0;
                continue;
            }
            next.put(r);
        }
        if (removed)
            state.selection = normalized(next[], primary < next.length ? primary : next.length - 1);
    }

    void columnSelect(size_t from, size_t to)
    {
        from = clampSnap(from, Affinity.before);
        to = clampSnap(to, Affinity.before);
        auto line = lineAt(from);
        const target = lineAt(to);
        const fromColumn = context.columnOf(text, line, from);
        const toColumn = context.columnOf(text, target, to);
        const down = to >= from;
        SharedBuffer!(EditRange, 4) ranges;
        while (true)
        {
            ranges.put(EditRange(context.positionAt(text, line, fromColumn),
                context.positionAt(text, line, toColumn)));
            if (line == target)
                break;
            VisualLine next;
            if (!(down ? context.lineBelow(text, line, next) : context.lineAbove(text, line, next)))
                break;
            line = next;
        }
        state.selection = normalized(ranges[], ranges.length - 1);
    }

    // -------------------------------------------------------------- editing

    /// Text as the options allow it: line breaks become spaces in
    /// single-line mode (`EDT8`); `null` when a scalar is not accepted.
    bool admit(ref Text inserted)
    {
        if (state.options.accepts !is null)
        {
            foreach (chunk; inserted.chunks)
                for (size_t i; i < chunk.bytes.length;)
                {
                    const token = tokenAt(chunk.bytes[i .. $]);
                    if (!state.options.accepts(token.scalar))
                        return false;
                    i += token.length;
                }
        }
        if (!state.options.singleLine)
            return true;
        bool hasBreak;
        foreach (chunk; inserted.chunks)
            foreach (ch; chunk.bytes)
                hasBreak = hasBreak || ch == '\n' || ch == '\r';
        if (!hasBreak)
            return true;
        SharedBuffer!(char, 64) flat;
        bool afterCr;
        foreach (chunk; inserted.chunks)
            foreach (ch; chunk.bytes)
            {
                if (ch == '\n' && afterCr)
                {
                    afterCr = false;
                    continue; // CR LF is one break
                }
                afterCr = ch == '\r';
                flat.put(ch == '\n' || ch == '\r' ? ' ' : ch);
            }
        inserted = Text(flat[]);
        return true;
    }

    /// The parts `text` gives each range (`EDY4`): one line per range when the
    /// counts match, else the whole text to every range.
    void distribute(in Text whole, ref UniqueBuffer!(Text, 4) parts)
    {
        const n = state.selection.length;
        if (n > 1)
        {
            // Split on line breaks, dropping one trailing break.
            SharedBuffer!(size_t, 8) cuts; // start of each line, then the end
            size_t end = whole.length;
            if (end && whole.byteAt(end - 1) == '\n')
                end -= end >= 2 && whole.byteAt(end - 2) == '\r' ? 2 : 1;
            else if (end && whole.byteAt(end - 1) == '\r')
                end -= 1;
            cuts.put(0);
            for (size_t i; i < end; ++i)
            {
                const ch = whole.byteAt(i);
                if (ch == '\n' || (ch == '\r' && !(i + 1 < end && whole.byteAt(i + 1) == '\n')))
                    cuts.put(i + 1);
            }
            if (cuts.length == n)
            {
                foreach (i; 0 .. n)
                {
                    size_t stop = i + 1 < n ? cuts[i + 1] - 1 : end;
                    if (i + 1 < n && stop > cuts[i] && whole.byteAt(stop - 1) == '\r')
                        --stop;
                    parts.put(whole.slice(cuts[i], stop));
                }
                return;
            }
        }
        foreach (i; 0 .. n)
            parts.put(whole.slice(0, whole.length));
    }

    /// Whether `edits` leave the text within `maxLength`; when not, the
    /// insertion is refused whole with a no-op.
    bool fits(scope const(RangeEdit)[] edits)
    {
        if (state.options.maxLength == 0)
            return true;
        size_t length = text.length;
        foreach (ref e; edits)
            length = length - (e.to - e.from) + e.inserted.length;
        if (length <= state.options.maxLength)
            return true;
        effects.put(noop(NoopReason.nothingToDo));
        return false;
    }

    void insertText(Text inserted, bool paste, Coalesce coalesce, EditKind last)
    {
        if (!admit(inserted))
        {
            effects.put(noop(NoopReason.nothingToDo));
            return;
        }
        if (inserted.length == 0 && allEmpty)
            return;
        UniqueBuffer!(RangeEdit, 4) edits;
        const ranges = state.selection.ranges;
        if (paste)
        {
            UniqueBuffer!(Text, 4) parts;
            distribute(inserted, parts);
            foreach (i, r; ranges)
                edits.put(RangeEdit(r.start, r.end, parts[i]));
        }
        else
            foreach (r; ranges)
                edits.put(RangeEdit(r.start, r.end, inserted));
        if (fits(edits[]))
            applyEdits(edits[], Placement.afterInserted, coalesce, last);
    }

    bool allEmpty() const
    {
        foreach (r; state.selection.ranges)
            if (!r.empty)
                return false;
        return true;
    }

    void deleteGrapheme(int direction, EditKind last, byte lastDirection)
    {
        UniqueBuffer!(RangeEdit, 4) edits;
        const single = allEmpty;
        foreach (r; state.selection.ranges)
        {
            if (!r.empty)
                edits.put(RangeEdit(r.start, r.end));
            else if (direction < 0)
                edits.put(RangeEdit(previousGraphemeBoundary(text, r.head), r.head));
            else
                edits.put(RangeEdit(r.head, nextGraphemeBoundary(text, r.head)));
        }
        const coalesce = !single ? Coalesce.none
            : direction < 0 ? Coalesce.deleteBack : Coalesce.deleteForward;
        applyEdits(edits[], Placement.atStart, coalesce, last);
    }

    void deleteRanges(Coalesce coalesce, EditKind last)
    {
        UniqueBuffer!(RangeEdit, 4) edits;
        foreach (r; state.selection.ranges)
            edits.put(r.empty ? RangeEdit(r.head, r.head) : RangeEdit(r.start, r.end));
        applyEdits(edits[], Placement.atStart, coalesce, last);
    }

    /// `true` when an edit at `[from, to)` would change protected bytes.
    bool protectedEdit(in RangeEdit e) const
    {
        foreach (span; state.readOnly[])
        {
            if (e.from < span.end && e.to > span.start)
                return true; // deletes protected bytes
            if (e.from == e.to && e.from > span.start && e.from < span.end)
                return true; // inserts strictly inside
        }
        return false;
    }

    /**
    EDT5: one change set from every range's edit, every range mapped
    through it, one history revision (or an amended one), and the effects.
    `edits` is in range order, one per range of the selection.
    */
    void applyEdits(scope RangeEdit[] edits, Placement placement, Coalesce coalesce, EditKind last)
    {
        UniqueBuffer!(Edit, 4) kept;
        SharedBuffer!(bool, 4) dropped;
        bool rejected;
        bool changes;
        foreach (e; edits)
        {
            const blocked = protectedEdit(e);
            rejected = rejected || blocked;
            dropped.put(blocked);
            if (!blocked)
            {
                kept.put(Edit(e.from, e.to, e.inserted));
                changes = changes || e.from != e.to || e.inserted.length;
            }
        }
        if (rejected)
            effects.put(EditEffect(EffectKind.rejectedReadOnly));
        if (!changes)
            return;
        ChangeSet set;
        const status = ChangeSet.of(text.length, kept[], set);
        assert(status == ChangeSetStatus.ok);
        SelectionSet before = state.selection;
        const inverse = set.invert(text);

        // Every range through the change: an edited range by its placement,
        // any other by its endpoints.
        SharedBuffer!(EditRange, 4) mapped;
        SharedBuffer!(EditRange, 2) inserted;
        foreach (i, r; before.ranges)
        {
            if (i < edits.length && !dropped[i])
            {
                const e = edits[i];
                const start = set.mapPos(e.from, Affinity.before);
                const end = set.mapPos(e.to, Affinity.after);
                final switch (placement)
                {
                case Placement.afterInserted:
                    mapped.put(EditRange.caret(end));
                    break;
                case Placement.atStart:
                    mapped.put(EditRange.caret(start));
                    break;
                case Placement.selectInserted:
                    mapped.put(EditRange.caret(end));
                    inserted.put(EditRange(start, end));
                    break;
                }
            }
            else
            {
                EditRange m = r;
                m.anchor = set.mapPos(r.anchor, r.forward ? Affinity.before : Affinity.after);
                m.head = set.mapPos(r.head, r.affinity);
                m.goal = EditRange.noGoal;
                mapped.put(m);
            }
        }
        state.text = set.apply(text);
        state.selection = normalized(mapped[], before.primaryIndex);
        // Read-only spans follow the text; their edges let edits in.
        if (state.readOnly.length)
            foreach (ref span; state.readOnly[])
                span = ReadOnlySpan(set.mapPos(span.start, Affinity.after),
                    set.mapPos(span.end, Affinity.before));
        if (placement == Placement.selectInserted)
            state.record.yanked = inserted;

        record(set, inverse, before, coalesce, last);
        effects.put(EditEffect(EffectKind.changed, changes: set));
        effects.put(EditEffect(EffectKind.scrollToPrimary));
    }

    /// Commit or amend the history (`EDT6`).
    void record(in ChangeSet set, in ChangeSet inverse, SelectionSet before,
        Coalesce coalesce, EditKind last)
    {
        const now = context.now;
        auto rec = &state.record;
        const joins = coalesce != Coalesce.none && rec.coalescible
            && lastCoalesce(last, rec.lastDirection) == coalesce
            && before == rec.afterEdit
            && now - rec.lastEditTime < state.options.coalesceInterval;
        if (!(joins && state.history.amend(set, inverse, state.selection, now) == HistoryStatus.ok))
            state.history.commit(set, inverse, before, state.selection, now);
        rec.coalescible = coalesce != Coalesce.none;
        rec.afterEdit = state.selection;
        rec.lastEditTime = now;
    }

    static Coalesce lastCoalesce(EditKind kind, byte direction)
    {
        if (kind == EditKind.insertText)
            return Coalesce.typing;
        if (kind == EditKind.deleteGrapheme)
            return direction < 0 ? Coalesce.deleteBack : Coalesce.deleteForward;
        return Coalesce.none;
    }

    // ------------------------------------------------------------ kill ring

    /// The span a kill of kind `which` takes from the caret `r`.
    EditRange killSpan(KillSpan which, in EditRange r)
    {
        final switch (which)
        {
        case KillSpan.word:
            return EditRange(r.head, wordTarget(r.head, cmd.direction));
        case KillSpan.blankWord:
            return EditRange(r.head, previousBlankDelimited(text, r.head).start);
        case KillSpan.line:
            return EditRange(r.head, killLineTarget(r.head, cmd.boundary));
        }
    }

    /**
    Kill every range, a caret taking `killSpan(which)` (`EDY2`): the spans
    are first merged as a selection, each merged span's text becomes one
    part, and a kill straight after a kill with as many ranges joins the
    newest entry.
    */
    void kill(KillSpan which, bool backward, EditKind last)
    {
        const previousRun = state.record.killRun;
        SharedBuffer!(EditRange, 4) spans;
        foreach (r; state.selection.ranges)
            spans.put(r.empty ? killSpan(which, r) : EditRange(r.start, r.end));
        const merged = normalized(spans[], state.selection.primaryIndex);
        UniqueBuffer!(Text, 2) parts;
        UniqueBuffer!(RangeEdit, 4) edits;
        bool any;
        foreach (r; merged.ranges)
        {
            parts.put(text.slice(r.start, r.end));
            edits.put(RangeEdit(r.start, r.end));
            any = any || !r.empty;
        }
        // An empty kill still continues the run, as Readline's `rl_kill_text`
        // counts one with nothing to kill.
        state.record.killRun = merged.length;
        if (!any)
            return;
        auto entry = KillEntry.of(parts[]);
        const joins = isKill(last) && previousRun == merged.length && ring.length
            && ring.at(0).parts == entry.parts;
        if (joins)
            ring.replaceNewest(ring.at(0).extended(entry, backward));
        else if (ring.push(entry))
            effects.put(EditEffect(EffectKind.killRingFull));
        state.record.killRun = merged.length;
        state.selection = merged;
        applyEdits(edits[], Placement.atStart, Coalesce.none, last);
    }

    void yank()
    {
        if (ring.empty)
        {
            effects.put(noop(NoopReason.nothingToYank));
            return;
        }
        insertEntry(ring.at(0));
        state.record.yankAge = 0;
    }

    void insertEntry(in KillEntry entry)
    {
        UniqueBuffer!(RangeEdit, 4) edits;
        const ranges = state.selection.ranges;
        if (entry.parts == ranges.length)
            foreach (i, r; ranges)
                edits.put(RangeEdit(r.start, r.end, entry.part(i)));
        else
        {
            Text whole = entry.joinedByLine;
            foreach (r; ranges)
                edits.put(RangeEdit(r.start, r.end, whole));
        }
        if (fits(edits[]))
            applyEdits(edits[], Placement.selectInserted, Coalesce.none, EditKind.yank);
    }

    bool yankPop(EditKind last)
    {
        const yanked = state.record.yanked[];
        if ((last != EditKind.yank && last != EditKind.yankPop) || ring.empty || yanked.length == 0)
        {
            effects.put(noop(NoopReason.nothingToYank));
            return false;
        }
        const age = state.record.yankAge + 1;
        const entry = ring.at(age);
        // Replace each yanked span with the older entry, amending the yank.
        UniqueBuffer!(Edit, 4) edits;
        Text whole = entry.joinedByLine;
        foreach (i, span; yanked)
            edits.put(Edit(span.start, span.end,
                entry.parts == yanked.length ? entry.part(i) : whole));
        ChangeSet set;
        const status = ChangeSet.of(text.length, edits[], set);
        assert(status == ChangeSetStatus.ok);
        const inverse = set.invert(text);
        SharedBuffer!(EditRange, 4) carets;
        SharedBuffer!(EditRange, 2) spans;
        foreach (span; yanked)
        {
            const start = set.mapPos(span.start, Affinity.before);
            const end = set.mapPos(span.end, Affinity.after);
            carets.put(EditRange.caret(end));
            spans.put(EditRange(start, end));
        }
        state.text = set.apply(text);
        state.selection = normalized(carets[], state.selection.primaryIndex);
        if (state.history.amend(set, inverse, state.selection, context.now) != HistoryStatus.ok)
            state.history.commit(set, inverse, state.selection, state.selection, context.now);
        state.record.yanked = spans;
        state.record.yankAge = age;
        effects.put(EditEffect(EffectKind.changed, changes: set));
        effects.put(EditEffect(EffectKind.scrollToPrimary));
        return true;
    }

    /// Put the ranges' text on the clipboard; `false` when every range is empty.
    bool copy()
    {
        Text joined;
        bool any;
        foreach (i, r; state.selection.ranges)
        {
            if (i)
                joined = joined.append(Text("\n"));
            joined = joined.append(text.slice(r.start, r.end));
            any = any || !r.empty;
        }
        if (!any)
            return false;
        effects.put(EditEffect(EffectKind.writeClipboard, text: joined));
        return true;
    }

    void paste()
    {
        static if (__traits(hasMember, Context, "clipboardRead"))
            if (!context.clipboardRead)
            {
                effects.put(noop(NoopReason.capabilityAbsent));
                return;
            }
        const request = state.record.nextRequest++;
        state.record.pendingRequest = request;
        effects.put(EditEffect(EffectKind.readClipboard, request: request));
    }

    void pasteAnswer(uint request, TextId id, EditKind last)
    {
        if (request == 0 || request != state.record.pendingRequest)
        {
            effects.put(noop(NoopReason.staleAnswer));
            return;
        }
        state.record.pendingRequest = 0;
        insertText(resolve(id), true, Coalesce.none, last);
    }

    // -------------------------------------------------------------- history

    void travel(HistoryStep!SelectionSet step, NoopReason nothing)
    {
        if (!step.ok)
        {
            effects.put(noop(nothing));
            return;
        }
        state.text = step.changes.apply(text);
        state.selection = step.state;
        state.record.coalescible = false;
        effects.put(EditEffect(EffectKind.changed, changes: step.changes));
        effects.put(EditEffect(EffectKind.scrollToPrimary));
    }
}
