/** Display-independent command-palette behavior and effects. */
module sparkles.ui.command_palette;

import sparkles.base.unique : makeUnique, Unique;
import sparkles.base.text.utf8 : validateUtf8;
import sparkles.fuzzy : CandidateView, DefaultFuzzyCaps, FuzzyLimits, MatchConfig,
    MatcherWorkspace, match, parseQuery, RankedResult, RankContext, rank, TopK,
    FuzzyErrorCode, FuzzyExpected, fuzzyErr, positions, TextRange;
import sparkles.ui.components.picker : PickerState;

// Matcher and ranking scratch must not consume a small native thread's stack.
private struct PaletteWorkspace(size_t Capacity)
{
    MatcherWorkspace!DefaultFuzzyCaps matcher;
    TopK!Capacity ranking;
    RankedResult[Capacity] rows;
}

/// The originating surface and its focus identity, owned and validated by the host.
struct PaletteInvocation
{
    ulong target;
    size_t focus;
}

/// Identifies one opening. Delayed events from older openings are ignored.
struct PaletteTicket
{
    ulong value;
}

/// An observable transition; commands are effects, never called by the palette.
enum PaletteEffectKind : ubyte { none, opened, cancelled, execute, rejected }

/// Failure leaves the last usable palette state intact.
enum PaletteStatus : ubyte { ok, capacityExceeded, duplicateCommand, invalidCommand, exhausted,
    closed, stale, invalidQuery, searchFailed, unavailable }

/// Immutable display metadata for a command, including commands without a binding.
struct PaletteEntry(Cmd)
if (is(Cmd == enum))
{
    PaletteCommand!Cmd command;
    string label;
    string group;
}

/// A command identity includes its argument, independently of its shortcuts.
struct PaletteCommand(Cmd)
if (is(Cmd == enum))
{
    Cmd operation;
    ulong argument;
}

/// Returned effects own their identity values and borrow no palette storage.
struct PaletteEffect(Cmd)
if (is(Cmd == enum))
{
    PaletteEffectKind kind;
    PaletteTicket ticket;
    PaletteInvocation invocation;
    PaletteCommand!Cmd command;
    PaletteStatus status;
}

/// Value-only view state. Text remains available through the palette's query/row accessors.
struct PaletteSnapshot
{
    bool active;
    PaletteTicket ticket;
    PaletteInvocation invocation;
    ulong revision;
    size_t selection;
    size_t rowCount;
}

/// A row activation bound to the exact session and published results that produced it.
struct PaletteChoice(Cmd)
if (is(Cmd == enum))
{
    PaletteTicket ticket;
    ulong revision;
    PaletteCommand!Cmd command;
}

/// A host-independent palette. The host performs effects and validates focus.
struct CommandPalette(Cmd, size_t Capacity = 512, size_t QueryBytes = 256)
if (is(Cmd == enum) && Capacity > 0 && QueryBytes > 0)
{
    static assert(Capacity <= long.max);
    private bool active_;
    private PaletteTicket ticket_;
    private PaletteInvocation invocation_;
    private PaletteEntry!Cmd[Capacity] entries_;
    private size_t count_;
    private PickerState!(Capacity, QueryBytes) picker_;
    private Unique!(PaletteWorkspace!Capacity) workspace_;
    private char[QueryBytes][2] queries_;
    private size_t queryLength_, queryBuffer_;
    private ulong queryGeneration_;
    private PaletteCommand!Cmd restoreSelection_;
    private bool hasRestoreSelection_;

    bool active() const @safe pure nothrow @nogc => active_;

    /// Capture identities for rendering and generation-safe row activation.
    PaletteSnapshot snapshot() const @safe pure nothrow @nogc
        => PaletteSnapshot(active_, ticket_, invocation_, queryGeneration_, picker_.selection, rowCount);

    /// Capture a row's identity instead of retaining its mutable list index.
    PaletteChoice!Cmd choice(size_t index) const @safe pure nothrow @nogc
        => active_ && index < rowCount
            ? PaletteChoice!Cmd(ticket_, queryGeneration_, row(index).command)
            : PaletteChoice!Cmd.init;

    /// Activate only a choice from the current published results.
    PaletteEffect!Cmd activate(Context)(in PaletteChoice!Cmd choice, in Context context)
    {
        if (!active_ || choice.ticket != ticket_ || choice.revision != queryGeneration_)
            return PaletteEffect!Cmd(status: PaletteStatus.stale);
        foreach (i; 0 .. rowCount)
            if (row(i).command == choice.command)
            {
                picker_.moveSelection(cast(long) i - cast(long) picker_.selection);
                return accept(ticket_, context);
            }
        return PaletteEffect!Cmd.init;
    }

    /// Replace the catalog atomically; identities must be nonzero and unique.
    PaletteStatus catalog(scope const(PaletteEntry!Cmd)[] entries) @safe pure nothrow @nogc
    {
        if (entries.length > Capacity) return PaletteStatus.capacityExceeded;
        if (queryGeneration_ == ulong.max) return PaletteStatus.exhausted;
        foreach (i, entry; entries)
        {
            if (entry.label.length > DefaultFuzzyCaps.maxCandidateBytes)
                return PaletteStatus.capacityExceeded;
            if (entry.command.operation == Cmd.init || !entry.label.length)
                return PaletteStatus.invalidCommand;
            foreach (previous; entries[0 .. i])
                if (previous.command == entry.command) return PaletteStatus.duplicateCommand;
        }
        if (entries.length)
        {
            if (workspace_.empty) workspace_ = makeUnique!(PaletteWorkspace!Capacity)();
            if (workspace_.empty) return PaletteStatus.searchFailed;
            // The default query policy selects simple folding or case-sensitive
            // analysis. Probe both before installing any labels or invalidating rows.
            foreach (probe; ["", "X"])
            {
                const parsed = parseQuery(probe, workspace_.get.matcher.textWorkspace);
                if (parsed.hasError) return PaletteStatus.searchFailed;
                foreach (entry; entries)
                {
                    CandidateView candidate;
                    candidate.id.high = cast(ulong) entry.command.operation;
                    candidate.id.low = entry.command.argument;
                    candidate.path = entry.label;
                    const checked = match(parsed.value, candidate, workspace_.get.matcher);
                    if (checked.hasError) return PaletteStatus.capacityExceeded;
                }
            }
        }
        if (rowCount)
        {
            restoreSelection_ = row(picker_.selection).command;
            hasRestoreSelection_ = true;
        }
        entries_[0 .. entries.length] = entries;
        entries_[entries.length .. count_ > entries.length ? count_ : entries.length] = PaletteEntry!Cmd.init;
        count_ = entries.length;
        picker_.publish(null, ++queryGeneration_, false);
        return PaletteStatus.ok;
    }

    /// The palette's retained catalog, borrowed until replacement.
    const(PaletteEntry!Cmd)[] entries() const return scope @safe pure nothrow @nogc
    {
        // The caller keeps this palette at a stable address while borrowing its view.
        return () @trusted { return entries_[0 .. count_]; }();
    }

    /// Search the captured target's available commands; errors preserve the last results.
    PaletteStatus search(Context)(PaletteTicket ticket, scope const(char)[] query, in Context context)
    {
        if (!active_) return PaletteStatus.closed;
        if (ticket != ticket_) return PaletteStatus.stale;
        if (query.length > QueryBytes) return PaletteStatus.capacityExceeded;
        if (validateUtf8(query).hasError) return PaletteStatus.invalidQuery;
        if (queryGeneration_ == ulong.max) return PaletteStatus.exhausted;
        if (workspace_.empty) workspace_ = makeUnique!(PaletteWorkspace!Capacity)();
        if (workspace_.empty) return PaletteStatus.searchFailed;
        const next = 1 - queryBuffer_;
        queries_[next][0 .. query.length] = query;
        const parsed = parseQuery(queries_[next][0 .. query.length], workspace_.get.matcher.textWorkspace);
        if (parsed.hasError) return PaletteStatus.invalidQuery;
        if (workspace_.get.ranking.reset(0, Capacity).hasError) return PaletteStatus.searchFailed;
        foreach (i, entry; entries_[0 .. count_])
        {
            if (!context.available(entry.command, invocation_.target)) continue;
            CandidateView candidate;
            candidate.id.high = cast(ulong) entry.command.operation;
            candidate.id.low = entry.command.argument;
            candidate.path = entry.label;
            const matched = match(parsed.value, candidate, workspace_.get.matcher);
            if (matched.hasError) return PaletteStatus.searchFailed;
            if (!matched.value.admitted) continue;
            const ranked = rank(candidate, matched.value, RankContext.init, i);
            if (ranked.hasError || workspace_.get.ranking.offer(ranked.value).hasError)
                return PaletteStatus.searchFailed;
        }
        const page = workspace_.get.ranking.page(workspace_.get.rows);
        if (page.hasError) return PaletteStatus.searchFailed;
        picker_.publish(workspace_.get.rows[0 .. page.value], ++queryGeneration_, false);
        if (hasRestoreSelection_)
        {
            foreach (i; 0 .. rowCount)
                if (row(i).command == restoreSelection_)
                {
                    picker_.moveSelection(cast(long) i - cast(long) picker_.selection);
                    break;
                }
            hasRestoreSelection_ = false;
        }
        queryBuffer_ = next;
        queryLength_ = query.length;
        return PaletteStatus.ok;
    }

    /// Number of ranked rows, independent of viewport height.
    size_t rowCount() const @safe pure nothrow @nogc => picker_.rowCount;

    /// The accepted query, borrowed until the next palette mutation.
    const(char)[] query() const return scope @safe pure nothrow @nogc
    {
        return () @trusted { return queries_[queryBuffer_][0 .. queryLength_]; }();
    }

    /// Authoritative UTF-8 label ranges for witness highlighting.
    FuzzyExpected!size_t highlights(size_t N)(size_t index, ref TextRange[N] output)
    {
        if (index >= rowCount || workspace_.empty)
            return fuzzyErr!size_t(FuzzyErrorCode.invalidCandidate);
        const parsed = parseQuery(query(), workspace_.get.matcher.textWorkspace);
        if (parsed.hasError) return fuzzyErr!size_t(parsed.error.code);
        const entry = row(index);
        CandidateView candidate;
        candidate.id.high = cast(ulong) entry.command.operation;
        candidate.id.low = entry.command.argument;
        candidate.path = entry.label;
        return positions(parsed.value, candidate, MatchConfig.init, FuzzyLimits.init,
            workspace_.get.matcher, output);
    }

    /// Metadata of one ranked row, or an empty descriptor outside the list.
    PaletteEntry!Cmd row(size_t index) const @safe pure nothrow @nogc
        => index < rowCount ? entries_[picker_.rows[index].corpusIndex] : PaletteEntry!Cmd.init;

    /// Move through ranked results without wrapping beyond either end.
    PaletteStatus move(PaletteTicket ticket, long delta) @safe pure nothrow @nogc
    {
        if (!active_) return PaletteStatus.closed;
        if (ticket != ticket_) return PaletteStatus.stale;
        const bounded = delta > cast(long) Capacity ? cast(long) Capacity
            : delta < -cast(long) Capacity ? -cast(long) Capacity : delta;
        picker_.moveSelection(bounded);
        return PaletteStatus.ok;
    }

    /// Revalidate and emit the selected command exactly once, then close.
    PaletteEffect!Cmd accept(Context)(PaletteTicket ticket, in Context context)
    {
        if (!active_ || ticket != ticket_ || !rowCount) return PaletteEffect!Cmd.init;
        const command = row(picker_.selection).command;
        if (!context.available(command, invocation_.target))
        {
            cast(void) search(ticket, queries_[queryBuffer_][0 .. queryLength_], context);
            return PaletteEffect!Cmd(status: PaletteStatus.unavailable);
        }
        active_ = false;
        picker_.close();
        return PaletteEffect!Cmd(PaletteEffectKind.execute, ticket_, invocation_, command);
    }

    /// Start a fresh opening, replacing any earlier query/selection session.
    PaletteEffect!Cmd open(PaletteInvocation invocation) @safe pure nothrow @nogc
    {
        if (ticket_.value == ulong.max)
            return PaletteEffect!Cmd(PaletteEffectKind.rejected, ticket_, invocation_,
                PaletteCommand!Cmd.init, PaletteStatus.exhausted);
        ++ticket_.value;
        invocation_ = invocation;
        active_ = true;
        picker_.open();
        queryLength_ = 0;
        hasRestoreSelection_ = false;
        return PaletteEffect!Cmd(PaletteEffectKind.opened, ticket_, invocation_);
    }

    /// Cancel only the named opening; the host restores its recorded focus.
    PaletteEffect!Cmd cancel(PaletteTicket ticket) @safe pure nothrow @nogc
    {
        if (!active_ || ticket != ticket_) return PaletteEffect!Cmd.init;
        active_ = false;
        picker_.close();
        return PaletteEffect!Cmd(PaletteEffectKind.cancelled, ticket_, invocation_);
    }
}

/// A click from old results cannot activate a replacement row in the same opening.
@("ui.command_palette.generationSafeActivation")
@safe pure nothrow @nogc unittest
{
    enum Command { none, save, open }
    alias Id = PaletteCommand!Command;
    alias Entry = PaletteEntry!Command;
    struct Context
    {
        bool available(Id command, ulong target) const @safe pure nothrow @nogc => target == 42;
    }
    CommandPalette!(Command, 4) palette;
    Entry[2] entries = [Entry(Id(Command.save), "Save"), Entry(Id(Command.open), "Open")];
    assert(palette.catalog(entries[]) == PaletteStatus.ok);
    const opening = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opening.ticket, "save", Context.init) == PaletteStatus.ok);
    const oldChoice = palette.choice(0);
    assert(palette.search(opening.ticket, "open", Context.init) == PaletteStatus.ok);
    assert(palette.activate(oldChoice, Context.init).kind == PaletteEffectKind.none && palette.active);
    const current = palette.choice(0);
    assert(palette.activate(current, Context.init).command == Id(Command.open));
    assert(!palette.active);
}

/// Witness ranges explain the same fuzzy query whose results survive rejected edits.
@("ui.command_palette.witnessAndRejectedQueries")
@safe pure nothrow @nogc unittest
{
    enum Command { none, save }
    alias Id = PaletteCommand!Command;
    alias Entry = PaletteEntry!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    CommandPalette!(Command, 2, 4) palette;
    Entry[1] commands = [Entry(Id(Command.save), "Save")];
    assert(palette.catalog(commands[]) == PaletteStatus.ok);
    const opened = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opened.ticket, "sv", Context.init) == PaletteStatus.ok);
    TextRange[4] ranges;
    const highlighted = palette.highlights(0, ranges);
    assert(highlighted.hasValue && highlighted.value == 2);
    assert(ranges[0] == TextRange(0, 1) && ranges[1] == TextRange(2, 3));
    assert(palette.search(opened.ticket, "12345", Context.init) == PaletteStatus.capacityExceeded);
    assert(palette.search(opened.ticket, "\xFF", Context.init) == PaletteStatus.invalidQuery);
    assert(palette.query == "sv" && palette.rowCount == 1 && palette.row(0).command == Id(Command.save));
}

/// Replacing descriptors invalidates old row indices and restores selection by identity.
@("ui.command_palette.catalogReplacementInvalidatesOldRows")
@safe pure nothrow @nogc unittest
{
    enum Command { none, tab }
    alias Id = PaletteCommand!Command;
    alias Entry = PaletteEntry!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    CommandPalette!(Command, 2) palette;
    Entry[2] commands = [Entry(Id(Command.tab, 1), "Tab one"), Entry(Id(Command.tab, 2), "Tab two")];
    assert(palette.catalog(commands[]) == PaletteStatus.ok);
    const opened = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opened.ticket, "", Context.init) == PaletteStatus.ok);
    assert(palette.move(opened.ticket, 1) == PaletteStatus.ok);
    Entry[2] reordered = [commands[1], commands[0]];
    assert(palette.catalog(reordered[]) == PaletteStatus.ok);
    assert(palette.accept(opened.ticket, Context.init).kind == PaletteEffectKind.none);
    assert(palette.search(opened.ticket, "", Context.init) == PaletteStatus.ok);
    assert(palette.accept(opened.ticket, Context.init).command == Id(Command.tab, 2));
}

/// A target removed after ranking cannot execute, and the results refresh without closing.
@("ui.command_palette.invalidatedCommandRefreshesResults")
@safe pure nothrow @nogc unittest
{
    enum Command { none, save }
    alias Id = PaletteCommand!Command;
    alias Entry = PaletteEntry!Command;
    struct Context
    {
        bool targetExists = true;
        bool available(Id id, ulong target) const @safe pure nothrow @nogc
            => targetExists && target == 42;
    }
    Context context;
    CommandPalette!(Command, 2) palette;
    Entry[1] commands = [Entry(Id(Command.save), "Save document")];
    assert(palette.catalog(commands[]) == PaletteStatus.ok);
    const first = palette.open(PaletteInvocation(42, 17));
    const second = palette.open(PaletteInvocation(42, 17));
    assert(palette.cancel(first.ticket).kind == PaletteEffectKind.none && palette.active);
    assert(palette.search(second.ticket, "save", context) == PaletteStatus.ok);
    context.targetExists = false;
    const result = palette.accept(second.ticket, context);
    assert(result.kind == PaletteEffectKind.none && result.status == PaletteStatus.unavailable);
    assert(palette.active && palette.rowCount == 0);
}

/// Navigation clamps safely at both ends, including extreme signed deltas.
@("ui.command_palette.navigationBothDirections")
@safe pure nothrow @nogc unittest
{
    enum Command { none, tab }
    alias Id = PaletteCommand!Command;
    alias Entry = PaletteEntry!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    CommandPalette!(Command, 2) palette;
    Entry[2] commands = [Entry(Id(Command.tab, 1), "Tab one"), Entry(Id(Command.tab, 2), "Tab two")];
    assert(palette.catalog(commands[]) == PaletteStatus.ok);
    const opened = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opened.ticket, "", Context.init) == PaletteStatus.ok);
    assert(palette.move(opened.ticket, long.max) == PaletteStatus.ok);
    assert(palette.move(opened.ticket, -1) == PaletteStatus.ok);
    assert(palette.accept(opened.ticket, Context.init).command == Id(Command.tab, 1));
}

/// Accepting a selected argument emits its invocation once; duplicate acceptance is inert.
@("ui.command_palette.acceptSelectedArgumentOnce")
@safe pure nothrow @nogc unittest
{
    enum Command { none, tab }
    alias Id = PaletteCommand!Command;
    alias Entry = PaletteEntry!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => target == 42;
    }
    CommandPalette!(Command, 2) palette;
    Entry[2] commands = [Entry(Id(Command.tab, 1), "Tab one"), Entry(Id(Command.tab, 2), "Tab two")];
    assert(palette.catalog(commands[]) == PaletteStatus.ok);
    const opened = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opened.ticket, "", Context.init) == PaletteStatus.ok);
    assert(palette.move(opened.ticket, 1) == PaletteStatus.ok);
    const accepted = palette.accept(opened.ticket, Context.init);
    assert(accepted.kind == PaletteEffectKind.execute);
    assert(accepted.command == Id(Command.tab, 2));
    assert(accepted.invocation == PaletteInvocation(42, 17) && !palette.active);
    assert(palette.accept(opened.ticket, Context.init).kind == PaletteEffectKind.none);
}

/// Search uses the invocation target's policy and ranks commands through shared fuzzy matching.
@("ui.command_palette.searchAvailableCommands")
@safe pure nothrow @nogc unittest
{
    enum Command { none, save, open, saveCopy }
    alias Entry = PaletteEntry!Command;
    alias Id = PaletteCommand!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc
            => target == 42 && id.operation != Command.saveCopy;
    }
    CommandPalette!(Command, 4) palette;
    Entry[3] commands = [Entry(Id(Command.save), "Save document"),
        Entry(Id(Command.open), "Open file"), Entry(Id(Command.saveCopy), "Save a copy")];
    assert(palette.catalog(commands[]) == PaletteStatus.ok);
    const opened = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opened.ticket, "save", Context.init) == PaletteStatus.ok);
    assert(palette.rowCount && palette.row(0).command == Id(Command.save));
    foreach (i; 0 .. palette.rowCount)
        assert(palette.row(i).command.operation != Command.saveCopy);
}

/// Catalog replacement preserves command arguments, owns descriptor values and rejects overflow.
@("ui.command_palette.rejectsOvercomplexCatalog")
@safe pure nothrow @nogc unittest
{
    enum Command { none, save }
    alias Id = PaletteCommand!Command;
    alias Entry = PaletteEntry!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    enum oversizedSegment = () {
        string value = "a";
        foreach (i; 0 .. 64) value ~= "\u0301";
        return value;
    }();
    CommandPalette!(Command, 2) palette;
    Entry[1] initial = [Entry(Id(Command.save), "Save")];
    assert(palette.catalog(initial[]) == PaletteStatus.ok);
    const opening = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opening.ticket, "save", Context.init) == PaletteStatus.ok);
    Entry[1] rejected = [Entry(Id(Command.save), oversizedSegment)];
    assert(palette.catalog(rejected[]) == PaletteStatus.capacityExceeded);
    assert(palette.query == "save" && palette.rowCount == 1 && palette.row(0).label == "Save");
}

/// The default capacity remains fully searchable under the worker stack budget.
@("ui.command_palette.defaultCapacitySearch")
@safe pure nothrow @nogc unittest
{
    enum Command { none, action }
    alias Id = PaletteCommand!Command;
    alias Entry = PaletteEntry!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    CommandPalette!Command palette;
    Entry[512] commands;
    foreach (i, ref entry; commands) entry = Entry(Id(Command.action, i + 1), "Command");
    assert(palette.catalog(commands[]) == PaletteStatus.ok);
    const opening = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opening.ticket, "", Context.init) == PaletteStatus.ok);
    assert(palette.rowCount == commands.length);
    assert(palette.move(opening.ticket, long.max) == PaletteStatus.ok);
    assert(palette.accept(opening.ticket, Context.init).command == Id(Command.action, 512));
}

/// Catalog replacement preserves command arguments, owns descriptor values and rejects overflow.
@("ui.command_palette.rejectsUnsearchableCatalog")
@safe pure nothrow @nogc unittest
{
    enum Command { none, save }
    alias Id = PaletteCommand!Command;
    alias Entry = PaletteEntry!Command;
    struct Context
    {
        bool available(Id id, ulong target) const @safe pure nothrow @nogc => true;
    }
    enum oversized = () {
        char[DefaultFuzzyCaps.maxCandidateBytes + 1] value;
        value[] = 'x';
        return value[].idup;
    }();
    CommandPalette!(Command, 2) palette;
    Entry[1] initial = [Entry(Id(Command.save), "Save")];
    assert(palette.catalog(initial[]) == PaletteStatus.ok);
    const opening = palette.open(PaletteInvocation(42, 17));
    assert(palette.search(opening.ticket, "save", Context.init) == PaletteStatus.ok);
    Entry[1] rejected = [Entry(Id(Command.save), oversized)];
    assert(palette.catalog(rejected[]) == PaletteStatus.capacityExceeded);
    assert(palette.query == "save" && palette.rowCount == 1 && palette.row(0).label == "Save");
}

/// Catalog replacement preserves command arguments, owns descriptor values and rejects overflow.
@("ui.command_palette.catalogCapacity")
@safe pure nothrow @nogc unittest
{
    enum Command { none, tab }
    alias Entry = PaletteEntry!Command;
    alias Id = PaletteCommand!Command;
    CommandPalette!(Command, 2) palette;
    Entry[2] commands = [Entry(Id(Command.tab, 1), "Tab one"), Entry(Id(Command.tab, 2), "Tab two")];
    assert(palette.catalog(commands[]) == PaletteStatus.ok);
    commands[0].label = "Changed caller storage";
    assert(palette.entries.length == 2 && palette.entries[0].label == "Tab one");
    assert(palette.entries[0].command != palette.entries[1].command);
    Entry[3] tooMany = [Entry(Id(Command.tab, 3), "Three"), Entry(Id(Command.tab, 4), "Four"),
        Entry(Id(Command.tab, 5), "Five")];
    assert(palette.catalog(tooMany[]) == PaletteStatus.capacityExceeded);
    assert(palette.entries.length == 2 && palette.entries[0].command == Id(Command.tab, 1));
}

/// Opening and cancelling emit focus identities without executing a command.
@("ui.command_palette.openCancel")
@safe pure nothrow @nogc unittest
{
    enum Command { none, save }
    CommandPalette!Command palette;
    assert(!palette.active);
    const opened = palette.open(PaletteInvocation(42, 17));
    assert(opened.kind == PaletteEffectKind.opened && palette.active);
    assert(opened.ticket.value != 0);
    const closed = palette.cancel(opened.ticket);
    assert(closed.kind == PaletteEffectKind.cancelled && !palette.active);
    assert(closed.invocation == PaletteInvocation(42, 17));
    assert(closed.command.operation == Command.none);
}
