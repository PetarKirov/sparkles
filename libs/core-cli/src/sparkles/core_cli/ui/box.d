module sparkles.core_cli.ui.box;

import std.algorithm.comparison : max;
import std.algorithm.iteration : map;
import std.algorithm.searching : maxElement, canFind;
import std.range : walkLength, repeat;
import std.range.primitives : ElementType, empty, front, isInputRange, popFront;
import std.format : format;

import sparkles.base.text.grapheme : visibleWidth;

/// How a title too wide for `maxWidth` is handled. Only takes effect when
/// `maxWidth > 0`; with no cap the box always expands to fit the title.
enum TitleOverflow
{
    expand, /// Widen the box to fit the title (current behavior, default).
    wrap, /// Wrap a long title into a nested title box (┤ ├ handles on the frame).
    ellipsis, /// Truncate the title to one line with a trailing '…'.
}

struct BoxProps
{
    bool omitLeftBorder = false;
    string footer = null;

    /// Lower/upper bounds on the box's total visible width (frame included), in the
    /// same units as `HeaderProps.width` — set both equal for a fixed-width box.
    ///
    /// `maxWidth`, if non-zero, wraps each content line so the box stays within this
    /// many columns (0 = no wrapping, the box expands to fit the longest line). By
    /// default a title wider than `maxWidth` still wins (the box is never truncated
    /// below what it must show); set `titleOverflow` to make a long title wrap or
    /// truncate so the box honours `maxWidth` too. Styled content keeps its
    /// colours/links across wrapped rows and is reset before the border so style
    /// never bleeds onto the padding or frame.
    ///
    /// `minWidth`, if non-zero, pads the box out to at least this many columns so
    /// short content still produces a full-width frame.
    size_t maxWidth = 0;
    size_t minWidth = 0; /// ditto

    /// What to do with a title wider than `maxWidth`. With the default `expand`
    /// the box grows to fit the title (so `maxWidth` only bounds the content). With
    /// `wrap` a long title wraps into a nested title box joined to the frame by
    /// `┤`/`├` handles; with `ellipsis` it is truncated to one line with a trailing
    /// `…`. Either way the whole box stays within `maxWidth`. Ignored when
    /// `maxWidth == 0` (no cap to honour). `wrap` falls back to `ellipsis` when
    /// `omitLeftBorder` is set (there is no left frame to grow the handles from).
    TitleOverflow titleOverflow = TitleOverflow.expand;

    dchar topLeft = '╭';
    dchar topRight = '╮';
    dchar bottomLeft = '╰';
    dchar bottomRight = '╯';

    dchar horizontalLine = '─';
    dchar verticalLine = '│';

    dchar titlePrefix = '╼';
    dchar titleSuffix = '╾';

    dchar titleConnectLeft = '┤'; /// Nested title box's left border where the frame's top joins it.
    dchar titleConnectRight = '├'; /// Nested title box's right border where the frame's top joins it.
}

string drawBox(string[] content, string title, BoxProps props = BoxProps.init)
{
    import std.array : join;

    return drawBoxLines(content, title, props).join("\n");
}

/// Overload that accepts a single string and splits it into lines internally.
string drawBox(string content, string title, BoxProps props = BoxProps.init)
{
    import std.array : join;
    import std.string : lineSplitter;

    return drawBoxLines(content.lineSplitter, title, props).join("\n");
}

/// The rendered box as a lazy range of its lines (range-out): the top border (with
/// title), then one row per content line, then the bottom border. `drawBox` is just
/// this joined with newlines.
///
/// `content` is any input range of lines (`string[]`, a lazy line range, …). When
/// the box is **fixed width** (a title/footer/`minWidth` floor already covers
/// `maxWidth`'s content area) the content range is pulled **lazily** — one source
/// `popFront` per emitted line group — so a delayed source animates the box. When
/// the width depends on the content, the content is wrapped once up front to size
/// the frame. The lazy path is `@nogc`-friendly per row only insofar as the wrap
/// engine is; `drawBoxLines` itself builds owned `string` rows.
auto drawBoxLines(Content)(Content content, string title, BoxProps props = BoxProps.init)
if (isInputRange!Content && is(ElementType!Content : const(char)[]))
{
    auto lay = computeBoxLayout(content, title, props);
    return BoxLineRange!Content(
        lay.prefix, lay.outputWidth, props, lay.top, lay.bottom,
        lay.contentMax, lay.canStream, lay.preparedRows, content);
}

/// How a streamable frame row is closed once its text has been emitted: `open` bytes,
/// then `fill` repeated up to the `target` visible column, then `tail` (incl. the row's
/// trailing newline). `renderClose(spec, w)` reproduces the original line's right side
/// from the accumulated visible width `w`, so the title can stream and only have its
/// right border drawn once complete. A zero-`target` spec (`CloseSpec.init`) renders to
/// nothing — used by decoration-only rows whose whole line lives in `TopItem.lead`.
private struct CloseSpec
{
    string open;
    dchar fill = ' ';
    size_t target;
    string tail;
}

/// Render a $(LREF CloseSpec) for an accumulated visible width `w`.
private string renderClose(in CloseSpec c, size_t w)
{
    import std.conv : to;
    import std.range : repeat;

    const n = c.target >= w ? c.target - w : 0;
    return c.open ~ c.fill.repeat(n).to!string ~ c.tail;
}

/// One row of a box's top region, for the chunk renderer. A row is either a streamable
/// title row (`lead` left border/decoration, `text` the title text streamed via
/// `byWrappedChunk`, `close` the right border) or a decoration-only line (`text == ""`,
/// the whole line incl. its newline in `lead`). Concatenating `lead ~ text ~
/// renderClose(close, text.visibleWidth)` over every item reproduces the top region
/// byte-for-byte — `BoxLayout.top` is derived from these so the two cannot drift.
private struct TopItem
{
    string lead;
    string text;
    CloseSpec close;
}

/// The content-independent layout of a box: frame geometry, the pre-rendered top
/// region and bottom border, and either a fixed `outputWidth` (when the box can
/// stream its content) or the already-wrapped `preparedRows` (when the content
/// determines the width). Shared by $(LREF drawBoxLines) and $(LREF drawBoxChunks).
private struct BoxLayout
{
    dstring prefix;
    size_t outputWidth;
    string[] top;
    string bottom;
    size_t contentMax;
    bool canStream;
    string[] preparedRows;
    TopItem[] topItems; // structured top region for drawBoxChunks; `top` is derived from it
}

/// Compute the $(LREF BoxLayout) for `content`/`title`/`props`. When the box is a
/// fixed width (`canStream`) the content is left untouched for the caller to stream;
/// otherwise it is wrapped once here into `preparedRows` to size the frame.
private BoxLayout computeBoxLayout(Content)(Content content, string title, BoxProps props)
if (isInputRange!Content && is(ElementType!Content : const(char)[]))
{
    import std.array : appender;
    import std.string : splitLines;
    import sparkles.base.text.wrap : byWrappedLine, WhitespaceMode, WrapOptions;

    const prefix = props.omitLeftBorder ? ""d : props.verticalLine ~ " "d;
    const prefixLen = prefix.length;

    // The frame eats `prefixLen` columns on the left plus " │" (2) on the right, so
    // a box of total width W has a content area of `W - frameOverhead` columns. The
    // public min/maxWidth are total-box widths; convert them to content widths here.
    const frameOverhead = prefixLen + 2;
    const contentMax = props.maxWidth > frameOverhead ? props.maxWidth - frameOverhead : 0;
    const contentMin = props.minWidth > frameOverhead ? props.minWidth - frameOverhead : 0;

    const footerWidth = props.footer !is null ? props.footer.visibleWidth : 0;
    const minFooterWidth = footerWidth > 0 ? footerWidth + 9 : 10;  // ╰──╼ {footer} ╾──╯ or ╰──────────╯

    // Lay out the title. By default it is one line and the box grows to fit it; with
    // a `maxWidth` cap, `ellipsis`/`wrap` keep the box within it. A single-line
    // title-bound box is `titleWidth + 11` wide and a nested title box `+ 8`, so
    // `singleCap` is the widest a title line may be on a plain top, `nestedCap` the
    // widest inside the nested box.
    const capped = props.maxWidth > 0;
    const singleCap = props.maxWidth >= 12 ? props.maxWidth - 11 : 1;
    const nestedCap = props.maxWidth >= 9 ? props.maxWidth - 8 : 1;
    const titleWidth = title.visibleWidth;

    string[] titleLines = [title];
    bool nested = false;
    if (capped) final switch (props.titleOverflow)
    {
        case TitleOverflow.expand:
            break; // box grows to fit the title
        case TitleOverflow.ellipsis:
            if (titleWidth > singleCap)
                titleLines = [ellipsizeTitle(title, singleCap)];
            break;
        case TitleOverflow.wrap:
            // No left frame to grow the ┤/├ handles from -> fall back to ellipsis.
            if (prefixLen == 0)
            {
                if (titleWidth > singleCap)
                    titleLines = [ellipsizeTitle(title, singleCap)];
            }
            else
            {
                // Stream the title at the single-line cap; nest it (in a title box
                // wrapped at the wider nested cap) only if it spills past one row.
                auto probe = title.byWrappedLine(
                    WrapOptions(width: singleCap, whitespace: WhitespaceMode.preserve));
                auto more = probe.save;
                more.popFront;
                if (!more.empty)
                {
                    // `front` is borrowed from the range's buffer; trim + retain.
                    auto tla = appender!(string[]);
                    foreach (l; title.byWrappedLine(
                            WrapOptions(width: nestedCap, whitespace: WhitespaceMode.preserve)))
                        tla ~= stripTrailingSpaces(l).idup;
                    titleLines = tla[];
                    nested = true;
                }
            }
            break;
    }

    // Width floors that do not depend on the content (title, footer, minWidth).
    const effTitleWidth = titleLines.map!(x => x.visibleWidth).maxElement;
    const titleFloor = nested ? effTitleWidth + 4 : (effTitleWidth + 9) - prefixLen;
    const footerFloor = minFooterWidth - prefixLen;
    const baseWidth = max(titleFloor, footerFloor, contentMin);

    // If a floor already covers the wrapped-content width (`contentMax`), the box is
    // a fixed width independent of the content, so we can stream the content lazily.
    // Otherwise the content can widen the box, so wrap it once now to size the frame.
    const canStream = contentMax > 0 && baseWidth >= contentMax;
    size_t outputWidth;
    string[] preparedRows;
    if (canStream)
        outputWidth = baseWidth;
    else
    {
        auto rows = appender!(string[]);
        if (contentMax > 0)
            foreach (cline; content)
            {
                bool any = false;
                foreach (w; cline.byWrappedLine(
                        WrapOptions(width: contentMax, whitespace: WhitespaceMode.preserve)))
                {
                    any = true;
                    const t = stripTrailingSpaces(w);
                    rows ~= (t.canFind('\x1b') ? t ~ "\x1b[0m" : t).idup;
                }
                if (!any)
                    rows ~= ""; // an empty source line wraps to nothing -> keep it blank
            }
        else
            foreach (cline; content)
                rows ~= cline.idup;
        preparedRows = rows[];
        const contentWidth = preparedRows.length ? preparedRows.map!(x => x.visibleWidth).maxElement : 0;
        outputWidth = max(baseWidth, contentWidth);
    }

    // Build the top region as structured items (the single source of truth for both
    // renderers); the string form (`top`) is derived from them just below, so the two
    // can never drift.
    TopItem[] topItems;
    if (nested)
        topItems = nestedTitleItems(titleLines, outputWidth, prefix, props);
    else
        // Single-line title: `╭──╼ {t0} ╾{rule}─╮`. The right side (` ╾…─╮`) is held in
        // the close so it streams only once the title text is complete. An empty title
        // (`t0 == ""`) yields zero streamed chunks, so the whole line becomes pending —
        // exactly the old atomic behavior.
        topItems = [TopItem(
            "╭──╼ ",
            titleLines[0],
            CloseSpec(" ╾", props.horizontalLine, outputWidth + prefixLen - 7, "─╮\n"))];

    // Derive the pre-rendered top region string from the items (render each at its
    // natural width). `drawBoxLines` / `string drawBox` keep consuming this unchanged.
    auto topApp = appender!string;
    foreach (it; topItems)
        topApp ~= it.lead ~ it.text ~ renderClose(it.close, it.text.visibleWidth);

    string bottomLine;
    if (props.footer !is null)
    {
        auto rule = props.horizontalLine.repeat(outputWidth + prefixLen - footerWidth - 7);
        bottomLine = "╰──╼ %s ╾%s─╯".format(props.footer, rule);
    }
    else
    {
        auto rule = props.horizontalLine.repeat(outputWidth + prefixLen - 10);
        bottomLine = "╰────────%s──╯".format(rule);
    }

    return BoxLayout(
        prefix.idup, outputWidth, topApp[].splitLines.idupArray, bottomLine,
        contentMax, canStream, preparedRows, topItems);
}

/// `splitLines.array` as `string[]` (the appender output is immutable, so its line
/// slices are already `string`).
private string[] idupArray(R)(R lines)
{
    import std.array : appender;

    auto a = appender!(string[]);
    foreach (l; lines)
        a ~= l.idup;
    return a[];
}

/// The lazy line range returned by $(LREF drawBoxLines). Emits the top region, then
/// content rows (streamed from the source for a fixed-width box, else from rows
/// wrapped up front), then the bottom border.
private struct BoxLineRange(Content)
{
    import sparkles.base.text.wrap : byWrappedLine, WhitespaceMode, WrapOptions, WrappedLines;

    private
    {
        dstring _prefix;
        size_t _outputWidth;
        BoxProps _props;
        string[] _top;
        string _bottom;
        size_t _contentMax;
        bool _stream;

        // Non-streaming: top + bordered rows + bottom, all precomputed.
        string[] _eager;
        size_t _ei;

        // Streaming: pull `_content` lazily, wrapping each source line into `_sub`.
        Content _content;
        WrappedLines!256 _sub;
        bool _subActive;
        bool _subEmittedRow; // did the current source line yield any wrapped row?
        size_t _ti;
        bool _bottomDone;

        string _front;
        bool _empty;
    }

    this(dstring prefix, size_t outputWidth, BoxProps props, string[] top, string bottom,
        size_t contentMax, bool stream, string[] preparedRows, Content content)
    {
        _prefix = prefix;
        _outputWidth = outputWidth;
        _props = props;
        _top = top;
        _bottom = bottom;
        _contentMax = contentMax;
        _stream = stream;
        _content = content;

        if (!stream)
        {
            import std.array : appender;

            auto all = appender!(string[]);
            foreach (l; top)
                all ~= l;
            foreach (r; preparedRows)
                all ~= borderRow(r);
            all ~= bottom;
            _eager = all[];
        }
        popFront(); // prime `_front`
    }

    /// Range primitives (input range).
    bool empty() const => _empty;

    /// ditto
    string front() const => _front;

    /// ditto
    void popFront()
    {
        if (!_stream)
        {
            if (_ei < _eager.length)
                _front = _eager[_ei++];
            else
                _empty = true;
            return;
        }
        if (_ti < _top.length)
        {
            _front = _top[_ti++];
            return;
        }
        if (loadNextContentRow())
            return;
        if (!_bottomDone)
        {
            _bottomDone = true;
            _front = _bottom;
            return;
        }
        _empty = true;
    }

    // Pull the next streamed content row into `_front`; false when content is done.
    private bool loadNextContentRow()
    {
        for (;;)
        {
            if (!_subActive)
            {
                if (_content.empty)
                    return false;
                _sub = _content.front.byWrappedLine(
                    WrapOptions(width: _contentMax, whitespace: WhitespaceMode.preserve));
                _content.popFront; // drives a delayed source -> animation
                _subActive = true;
                _subEmittedRow = false;
            }
            if (_sub.empty)
            {
                _subActive = false;
                if (!_subEmittedRow)
                {
                    // An empty source line wraps to nothing: keep it as a blank row.
                    _subEmittedRow = true;
                    _front = borderRow("");
                    return true;
                }
                continue;
            }
            const w = _sub.front;
            _sub.popFront;
            const t = stripTrailingSpaces(w);
            _front = borderRow(t.canFind('\x1b') ? t ~ "\x1b[0m" : t);
            _subEmittedRow = true;
            return true;
        }
    }

    // `prefix + line + right-pad + " │"` — `line` already trimmed/reset, ≤ outputWidth.
    private string borderRow(const(char)[] line)
    {
        const rightPad = _outputWidth >= line.visibleWidth ? _outputWidth - line.visibleWidth : 0;
        return "%s%s%s %s".format(_prefix, line, ' '.repeat(rightPad), _props.verticalLine);
    }
}

/// The rendered box as a lazy range of *chunks* (cell-granular streaming) — the
/// sibling of $(LREF drawBoxLines). With `lineBuffered: true` each chunk is a whole
/// bordered row (the same bytes as `drawBoxLines`); with `lineBuffered: false` each
/// content run (a word / break-segment) is its own chunk, so pacing the output range
/// reveals the box cell by cell, like text typed into the frame. Concatenating every
/// chunk reproduces `drawBox` (chunks already carry their own newlines).
///
/// Frame pieces (top rule, per-row borders, bottom rule) never form a standalone
/// chunk: each is merged onto an adjacent content chunk, so every emitted chunk
/// carries a visible advance ("content-only ticks"). The bottom border is still drawn
/// — appended to the final content chunk once the content stream ends — so no TUI
/// repainting is needed. `content` is pulled lazily for a fixed-width box (one source
/// line at a time), so a delayed source animates the reveal.
auto drawBoxChunks(bool lineBuffered = true, Content)(
    Content content, string title, BoxProps props = BoxProps.init)
if (isInputRange!Content && is(ElementType!Content : const(char)[]))
{
    auto lay = computeBoxLayout(content, title, props);
    return BoxChunkRange!(lineBuffered, Content)(
        lay.prefix, lay.outputWidth, props, lay.top, lay.bottom,
        lay.contentMax, lay.canStream, lay.preparedRows, content, lay.topItems);
}

/// The lazy chunk range returned by $(LREF drawBoxChunks). See that function for the
/// streaming / frame-merging semantics. `front` is owned (a freshly built string), so
/// it is safe to retain across `popFront`.
private struct BoxChunkRange(bool lineBuffered, Content)
{
    import std.conv : to;
    import sparkles.base.text.wrap : byWrappedChunk, byWrappedLine,
        WhitespaceMode, WrapOptions, WrappedChunks, WrappedLines;

    private
    {
        string _prefix;
        size_t _outputWidth;
        BoxProps _props;
        string[] _top;
        string _bottom;
        size_t _contentMax;
        bool _stream;

        // Row source.
        string[] _eagerRows; // non-stream: finished pre-border rows
        size_t _eri;
        Content _content;     // stream: pulled one source line at a time
        WrappedLines!256 _sub;
        bool _subActive;
        bool _subEmittedRow;  // did the current source line yield any wrapped row?

        // Top region: title rows (streamable) + decoration lines, consumed before body.
        TopItem[] _topItems;
        size_t _tii;

        // Sub-chunking of the current row + frame-merge state.
        WrappedChunks!(lineBuffered, 256) _rowChunks;
        bool _rowOpen;
        size_t _rowWidth;     // visible width accumulated in the current row
        CloseSpec _rowClose;  // how the current row's right border is drawn
        CloseSpec _bodyClose; // close spec shared by all body content rows
        string _pending;      // frame bytes awaiting a content chunk to attach to

        // One-content-chunk lookahead, so the bottom border attaches to the last one.
        string _laText, _laPre;
        bool _laValid;

        string _topFrame;     // top region + its trailing newline (no-content fallback)
        string _front;
        bool _empty, _finished;
    }

    this(dstring prefix, size_t outputWidth, BoxProps props, string[] top, string bottom,
        size_t contentMax, bool stream, string[] preparedRows, Content content,
        TopItem[] topItems)
    {
        import std.array : join;

        _prefix = prefix.to!string;
        _outputWidth = outputWidth;
        _props = props;
        _top = top;
        _bottom = bottom;
        _contentMax = contentMax;
        _stream = stream;
        _eagerRows = stream ? null : preparedRows;
        _content = content;
        _topItems = topItems;
        // Body rows: right-pad the text to `outputWidth`, then ` │` and the row joiner.
        _bodyClose = CloseSpec("", ' ', outputWidth, " " ~ props.verticalLine.to!string ~ "\n");
        _topFrame = top.join("\n") ~ "\n"; // only used when there are no chunks at all
        popFront(); // prime `_front`
    }

    /// Range primitives (input range).
    bool empty() const => _empty;

    /// ditto
    const(char)[] front() const => _front;

    /// ditto
    void popFront()
    {
        if (_finished)
        {
            _empty = true;
            return;
        }
        if (!_laValid)
        {
            // First call: pull the first content chunk. No content at all -> the box
            // is just its top region and bottom border.
            if (!nextTextChunk(_laText, _laPre))
            {
                _front = _topFrame ~ _bottom;
                _finished = true;
                return;
            }
            _laValid = true;
        }
        string t2, p2;
        if (nextTextChunk(t2, p2))
        {
            _front = _laPre ~ _laText;
            _laText = t2;
            _laPre = p2;
        }
        else
        {
            // `_laText` was the last content chunk: append the trailing frame (the
            // last row's close, then the bottom border).
            _front = _laPre ~ _laText ~ _pending ~ _bottom;
            _finished = true;
        }
    }

    // Pull the next content chunk and the frame bytes that must precede it. Frame
    // pieces accumulate in `_pending` across rows (including empty/decoration rows) and
    // are handed to the first content chunk that follows. Returns false when all title
    // and content rows are done; `_pending` then holds the final row's close (the bottom
    // border is added by `popFront`).
    private bool nextTextChunk(out string text, out string pre)
    {
        for (;;)
        {
            if (_rowOpen)
            {
                if (!_rowChunks.empty)
                {
                    const c = _rowChunks.front;
                    _rowChunks.popFront;
                    text = c.idup; // own it: the buffer is freed when the row advances
                    _rowWidth += c.visibleWidth;
                    pre = _pending;
                    _pending = null;
                    return true;
                }
                // Row exhausted: draw its right border (pad + border) and the joiner.
                _pending ~= renderClose(_rowClose, _rowWidth);
                _rowOpen = false;
                continue;
            }
            if (!openNextRow())
                return false;
        }
    }

    // Open the next streamable row, appending its left border/decoration to `_pending`.
    // Title rows (from `_topItems`) come first, then body content rows; decoration-only
    // top items (`text == ""`) render their whole line into `_pending` and are skipped.
    // Returns false when no rows remain.
    private bool openNextRow()
    {
        while (_tii < _topItems.length)
        {
            const it = _topItems[_tii++];
            if (it.text.length == 0)
            {
                // Decoration-only line (nested top/bottom, or an empty single-line
                // title): the whole line is in `lead`; nothing to stream.
                _pending ~= it.lead ~ renderClose(it.close, 0);
                continue;
            }
            _pending ~= it.lead;
            _rowChunks = byWrappedChunk!(lineBuffered)(it.text, WrapOptions(width: 0));
            _rowWidth = 0;
            _rowClose = it.close;
            _rowOpen = true;
            return true;
        }
        string row;
        if (!nextRow(row))
            return false;
        _pending ~= _prefix; // this body row's left border
        _rowChunks = byWrappedChunk!(lineBuffered)(row, WrapOptions(width: 0));
        _rowWidth = 0;
        _rowClose = _bodyClose;
        _rowOpen = true;
        return true;
    }

    // The next finished pre-border row content (trimmed, style-reset), or false.
    private bool nextRow(out string row)
    {
        if (!_stream)
        {
            if (_eri < _eagerRows.length)
            {
                row = _eagerRows[_eri++];
                return true;
            }
            return false;
        }
        for (;;)
        {
            if (!_subActive)
            {
                if (_content.empty)
                    return false;
                _sub = _content.front.byWrappedLine(
                    WrapOptions(width: _contentMax, whitespace: WhitespaceMode.preserve));
                _content.popFront; // drives a delayed source -> animation
                _subActive = true;
                _subEmittedRow = false;
            }
            if (_sub.empty)
            {
                _subActive = false;
                if (!_subEmittedRow)
                {
                    // An empty source line wraps to nothing: keep it as a blank row.
                    _subEmittedRow = true;
                    row = "";
                    return true;
                }
                continue;
            }
            const w = _sub.front;
            _sub.popFront;
            const t = stripTrailingSpaces(w);
            row = (t.canFind('\x1b') ? t ~ "\x1b[0m" : t).idup;
            _subEmittedRow = true;
            return true;
        }
    }
}

/// Trim trailing spaces from a wrapped row, keeping internal whitespace intact.
/// `preserve` wrapping can leave a space at a wrap point (and the engine may append
/// a style reset after it); this returns the row up to the last non-space, non-escape
/// cluster, so the row's visible width never exceeds the wrap width. Any opening
/// style is re-closed by the caller's reset-before-border step.
private const(char)[] stripTrailingSpaces(const(char)[] s)
{
    import sparkles.base.text.grapheme : byGraphemeCluster;

    size_t off = 0, lastVisibleEnd = 0;
    foreach (c; s.byGraphemeCluster)
    {
        if (!c.isEscape && !(c.slice.length == 1 && c.slice[0] == ' '))
            lastVisibleEnd = off + c.slice.length;
        off += c.slice.length;
    }
    return s[0 .. lastVisibleEnd];
}

/// Truncate `title` to `width` visible columns (the trailing `…` included), keeping
/// styles intact and reset before the ellipsis so colour cannot bleed past it.
/// Returns `title` unchanged when it already fits. Thin wrapper over the shared
/// `truncateField` (grapheme-accurate, uses the full width budget rather than the
/// old word-boundary cut); the `width == 0` case keeps the historical bare `…`.
private string ellipsizeTitle(string title, size_t width)
{
    import sparkles.base.text.width : truncateField;

    if (width == 0)
        return "…";
    return truncateField(title, width);
}

/// The top region for a wrapped title inside a nested box joined to the frame's top by
/// `┤`/`├` handles (see `TitleOverflow.wrap`), as streamable $(LREF TopItem)s. The
/// nested box top/bottom are decoration-only lines; each title row is a streamable item
/// whose `close` right-pads the text to the nested `field` column and draws that row's
/// right border. `outputWidth` is the frame's content-area width, which the nested box
/// fills exactly. Assumes a standard left frame (`prefixLen == 2`); callers fall back to
/// `ellipsis` when `omitLeftBorder`.
private TopItem[] nestedTitleItems(
    string[] titleLines, size_t outputWidth, const(dchar)[] prefix, in BoxProps props)
{
    import std.conv : to;

    const inner = outputWidth; // nested box total width == frame content area
    const field = inner - 4; // title text field inside the nested box (│ … │)
    const hl1 = props.horizontalLine.repeat(prefix.length - 1).to!string;
    const hlInner = props.horizontalLine.repeat(inner - 2).to!string;
    const pfx = prefix.to!string;
    const lead = ' '.repeat(prefix.length).to!string;

    string reset(string s) => s.canFind('\x1b') ? s ~ "\x1b[0m" : s;

    TopItem[] items;

    // Nested box top, protruding above the frame into the left content margin (deco).
    items ~= TopItem(
        "%s%s%s%s  \n".format(lead, props.topLeft, hlInner, props.topRight), "", CloseSpec.init);

    // Frame top joins the nested box's first title row via the ┤/├ handles.
    items ~= TopItem(
        "%s%s%s ".format(props.topLeft, hl1, props.titleConnectLeft),
        reset(titleLines[0]),
        CloseSpec("", ' ', field, " %s%s%s\n".format(props.titleConnectRight, hl1, props.topRight)));

    // Remaining title rows: frame border + nested box content rows.
    foreach (line; titleLines[1 .. $])
        items ~= TopItem(
            "%s%s ".format(pfx, props.verticalLine),
            reset(line),
            CloseSpec("", ' ', field, " %s %s\n".format(props.verticalLine, props.verticalLine)));

    // Nested box bottom, inside the frame (deco).
    items ~= TopItem(
        "%s%s%s%s %s\n".format(pfx, props.bottomLeft, hlInner, props.bottomRight, props.verticalLine),
        "", CloseSpec.init);

    return items;
}

@("drawBox.basic.singleLine")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Hello"].drawBox("T") == `
        ╭──╼ T ╾───╮
        │ Hello    │
        ╰──────────╯`.outdent(2));
}

@("drawBox.basic.multiLine")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Line 1", "Line 2", "Line 3"].drawBox("Title") == `
        ╭──╼ Title ╾───╮
        │ Line 1       │
        │ Line 2       │
        │ Line 3       │
        ╰──────────────╯`.outdent(2));
}

@("drawBox.basic.varyingLineWidths")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Short", "A longer line", "Mid"].drawBox("Box") == `
        ╭──╼ Box ╾──────╮
        │ Short         │
        │ A longer line │
        │ Mid           │
        ╰───────────────╯`.outdent(2));
}

@("drawBox.width.contentWiderThanTitle")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["This is a very long content line"].drawBox("T") == `
        ╭──╼ T ╾───────────────────────────╮
        │ This is a very long content line │
        ╰──────────────────────────────────╯`.outdent(2));
}

@("drawBox.width.titleWiderThanContent")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // This tests the fix for the underflow bug
    assert(["Hi"].drawBox("Long Title Here") == `
        ╭──╼ Long Title Here ╾───╮
        │ Hi                     │
        ╰────────────────────────╯`.outdent(2));
}

@("drawBox.width.minimalContent")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // Single character content and title - tests minimum box size
    assert(["x"].drawBox("T") == `
        ╭──╼ T ╾───╮
        │ x        │
        ╰──────────╯`.outdent(2));
}

@("drawBox.width.emptyTitle")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Content"].drawBox("") == `
        ╭──╼  ╾────╮
        │ Content  │
        ╰──────────╯`.outdent(2));
}

@("drawBox.props.omitLeftBorder")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Line 1", "Line 2"].drawBox("Title", BoxProps(omitLeftBorder: true)) == `
        ╭──╼ Title ╾───╮
        Line 1         │
        Line 2         │
        ╰──────────────╯`.outdent(2));
}

@("drawBox.props.omitLeftBorderWithLongTitle")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // When omitLeftBorder is true, prefix is empty, affecting minWidth calculation
    assert(["Hi"].drawBox("Very Long Title", BoxProps(omitLeftBorder: true)) == `
        ╭──╼ Very Long Title ╾───╮
        Hi                       │
        ╰────────────────────────╯`.outdent(2));
}

@("drawBox.props.footer")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert(["Content"].drawBox("Title", BoxProps(footer: "Done")) == `
        ╭──╼ Title ╾───╮
        │ Content      │
        ╰──╼ Done ╾────╯`.outdent(2));
}

@("drawBox.props.footerWiderThanContent")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // Footer wider than content should expand the box
    assert(["Hi"].drawBox("T", BoxProps(footer: "Completed successfully")) == `
        ╭──╼ T ╾────────────────────────╮
        │ Hi                            │
        ╰──╼ Completed successfully ╾───╯`.outdent(2));
}

@("drawBox.props.footerWithAnsiCodes")
@system unittest
{
    import sparkles.base.term_style : Style, stylize;

    // Styled footer should not affect width calculation
    auto styledFooter = "✓ OK".stylize(Style.green);
    assert(["Content"].drawBox("Title", BoxProps(footer: styledFooter)) ==
        "╭──╼ Title ╾───╮\n" ~
        "│ Content      │\n" ~
        "╰──╼ \x1b[32m✓ OK\x1b[39m ╾────╯");
}

@("drawBox.styled.contentWithAnsiCodes")
@system unittest
{
    import sparkles.base.term_style : Style, stylize;

    // ANSI codes should not affect box width calculation
    auto styledContent = "Hello".stylize(Style.bold);
    assert([styledContent].drawBox("T") ==
        "╭──╼ T ╾───╮\n" ~
        "│ \x1b[1mHello\x1b[22m    │\n" ~
        "╰──────────╯");
}

@("drawBox.styled.titleWithAnsiCodes")
@system unittest
{
    import sparkles.base.term_style : Style, stylize;

    // Styled title should not affect width calculation
    auto styledTitle = "Title".stylize(Style.cyan);
    assert(["Content here"].drawBox(styledTitle) ==
        "╭──╼ \x1b[36mTitle\x1b[39m ╾───╮\n" ~
        "│ Content here │\n" ~
        "╰──────────────╯");
}

@("drawBox.overload.singleString")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    // Test the single-string overload that splits on newlines
    assert("Line 1\nLine 2".drawBox("T") == `
        ╭──╼ T ╾───╮
        │ Line 1   │
        │ Line 2   │
        ╰──────────╯`.outdent(2));
}

@("drawBox.overload.singleStringMultipleNewlines")
@system unittest
{
    import sparkles.test_utils.string : outdent;

    assert("A\nBB\nCCC".drawBox("X") == `
        ╭──╼ X ╾───╮
        │ A        │
        │ BB       │
        │ CCC      │
        ╰──────────╯`.outdent(2));
}

// Legacy test using test files
unittest
{
    import std.algorithm.iteration : each;
    import std.array : array;
    import std.string : lineSplitter;
    import std.stdio : writeln;
    import sparkles.core_cli.test_utils : readFromTestDir;

    void drawFileInBox(string path, bool omitLeftBorder = false)
    {
        path
            .readFromTestDir
            .lineSplitter.array
            .drawBox("Sample Title", BoxProps(omitLeftBorder))
            .writeln;
    }

    drawFileInBox("out0.txt");
    drawFileInBox("out1.txt", true);
}

// function draw_box {
//   local title="$1"
//   local draw_left_box_side="${2:-}"
//   local reset_esc_seq="${3:-}"
//   local title_len=${#title}
//   title="${bold}${title}${offbold}"

//   local output
//   output="$(cat)"

//   local output_width
//   output_width="$(echo "$output" | remove_ansi_escapes | wc -L)"

//   local prefix
//   if [[ "$draw_left_box_side" != false ]]; then
//     prefix='│ '
//   else
//     prefix=''
//   fi

//   prefix_len="${#prefix}"

//   local topline
//   topline="$(draw_line $((output_width + prefix_len - title_len - 7 )))"

//   local bottomline
//   bottomline="$(draw_line $((output_width + prefix_len - 10 )))"

//   echo "╭──╼ ${title} ╾${topline}─╮"

//   while IFS="" read -r line
//   do
//     local line_length
//     line_length="$(echo "$line" | remove_ansi_escapes | wc -L)"

//     local rightPadLen=$((output_width - line_length))
//     local rightPad
//     rightPad="$(repeatStr "$rightPadLen" ' ')"

//     printf '%s%s%s │\n' "$prefix" "$line" "$rightPad"
//   done <<< "$output"

//   echo "╰────────${bottomline}──╯${reset_esc_seq}"
// }

@("drawBox.wrap.disabledByDefault")
@system unittest
{
    import std.string : splitLines;

    // maxWidth defaults to 0 -> no wrapping, box expands to fit the long line.
    const box = drawBox(["aaaa bbbb cccc"], "T");
    assert(box.splitLines.length == 3); // top + one content row + bottom
}

@("drawBox.wrap.wrapsLongLine")
@system unittest
{
    import std.string : splitLines;
    import std.algorithm.searching : canFind;

    // maxWidth is the total box width; with the 4-column frame overhead this
    // leaves a 4-column content area, so "aaaa bbbb cccc" wraps to three rows.
    const box = drawBox(["aaaa bbbb cccc"], "T", BoxProps(maxWidth: 8));
    assert(box.splitLines.length == 5); // top + three content rows + bottom
    assert(box.canFind("aaaa") && box.canFind("bbbb") && box.canFind("cccc"));
}

@("drawBox.wrap.styledNoBleed")
@system unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.base.term_style : stylize, Style;

    // A styled line wrapped across rows is reset before the border, so colour
    // cannot bleed onto the padding or frame.
    const styled = "red red red".stylize(Style.red);
    const box = drawBox([styled], "T", BoxProps(maxWidth: 11));
    assert(box.canFind("\x1b[0m"));
}

@("drawBox.width.minWidthPads")
@system unittest
{
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // minWidth pads a short box out to a fixed total width so stacked boxes align.
    const box = drawBox(["x"], "T", BoxProps(minWidth: 40));
    foreach (line; box.splitLines)
        assert(line.visibleWidth == 40);
}

@("drawBox.width.minMaxEqualFixedWidth")
@system unittest
{
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // Setting minWidth == maxWidth yields a fixed-width box: long content wraps in,
    // short content pads out, every row lands on the requested total width.
    const box = drawBox(["aaaa bbbb cccc dddd eeee", "short"], "T",
        BoxProps(minWidth: 20, maxWidth: 20));
    foreach (line; box.splitLines)
        assert(line.visibleWidth == 20);
}

@("drawBox.titleOverflow.ellipsisFits")
@system unittest
{
    import std.string : splitLines;
    import std.algorithm.searching : canFind;

    // ellipsis keeps the title on one line, truncating it with '…' so the box
    // stays within maxWidth.
    const title = "Verifying 3 example(s) from docs/libs/base/how-to/foo.md";
    const box = drawBox(["body"], title, BoxProps(maxWidth: 30, titleOverflow: TitleOverflow.ellipsis));
    const lines = box.splitLines;
    foreach (line; lines)
        assert(line.visibleWidth <= 30);
    assert(lines[0].canFind("…"));
}

@("drawBox.titleOverflow.wrapNestsTitleBox")
@system unittest
{
    import std.string : splitLines;
    import std.algorithm.searching : canFind;

    // wrap renders a long title inside a nested box joined to the frame by ┤/├
    // handles: the box never exceeds maxWidth, the handles appear on the frame-top
    // row, a nested-box top rule sits above it, and every title word survives.
    const title = "This is a very long multi-line drawBox title. It ends here.";
    const box = drawBox(["Body content line one"], title,
        BoxProps(maxWidth: 36, titleOverflow: TitleOverflow.wrap));
    const lines = box.splitLines;
    foreach (line; lines)
        assert(line.visibleWidth <= 36);
    assert(lines[0].canFind('╭') && lines[0].canFind('╮')); // nested box top, protruding
    assert(lines[1].canFind('┤') && lines[1].canFind('├')); // frame-top handles
    foreach (word; ["This", "multi-line", "drawBox", "ends", "here."])
        assert(box.canFind(word));
}

@("drawBox.titleOverflow.wrapShortTitleStaysSingleLine")
@system unittest
{
    import std.algorithm.searching : canFind;

    // A title that already fits keeps the plain ╭──╼ … ╾ top even in wrap mode.
    const box = drawBox(["body"], "Short", BoxProps(maxWidth: 40, titleOverflow: TitleOverflow.wrap));
    assert(box.canFind("╭──╼ Short ╾"));
    assert(!box.canFind('┤') && !box.canFind('├'));
}

@("drawBox.titleOverflow.expandIsDefault")
@system unittest
{
    import std.string : splitLines;
    import sparkles.base.text.grapheme : visibleWidth;

    // Default expand: a long title still widens the box past maxWidth (maxWidth
    // only bounds the content), so the title is never wrapped or truncated.
    const title = "This is a very long multi-line drawBox title. It ends here.";
    const box = drawBox(["body"], title, BoxProps(maxWidth: 20));
    assert(box.splitLines[0].canFind(title));
    assert(box.splitLines[0].visibleWidth > 20);
}

@("drawBox.titleOverflow.styledNoBleed")
@system unittest
{
    import std.algorithm.searching : canFind;
    import sparkles.base.term_style : stylize, Style;

    // A styled title wrapped into the nested box is reset before the border so its
    // colour cannot bleed onto the frame.
    const styled = "cyan cyan cyan cyan cyan cyan cyan cyan".stylize(Style.cyan);
    const box = drawBox(["body"], styled, BoxProps(maxWidth: 30, titleOverflow: TitleOverflow.wrap));
    assert(box.canFind("\x1b[0m"));
}

@("drawBox.lines.joinEqualsString")
@system unittest
{
    import std.algorithm.comparison : equal;
    import std.array : join;
    import std.string : splitLines;
    import std.typecons : tuple;

    // drawBoxLines is the lazy range view of drawBox: joined with newlines it
    // reproduces the string, across single-line, footer, and nested-title layouts.
    static foreach (args; [
        tuple(["Hello"], "T", BoxProps.init),
        tuple(["Content"], "Title", BoxProps(footer: "Done")),
        tuple(["Body content line one"], "This is a very long multi-line title here.",
            BoxProps(maxWidth: 36, titleOverflow: TitleOverflow.wrap)),
    ])
    {{
        const str = drawBox(args[0], args[1], args[2]);
        assert(drawBoxLines(args[0], args[1], args[2]).equal(str.splitLines));
        assert(drawBoxLines(args[0], args[1], args[2]).join("\n") == str);
    }}
}

@("drawBox.lines.acceptsLazyContentRange")
@system unittest
{
    import std.algorithm.comparison : equal;
    import std.algorithm.iteration : map;
    import std.array : join;

    // drawBoxLines takes any input range of lines, not just string[]; a lazy range
    // (here a fixed-width box, which pulls content lazily) yields the same bytes.
    auto lazyContent = ["one", "two", "three"].map!(x => x);
    const want = drawBox(["one", "two", "three"], "T", BoxProps(minWidth: 24, maxWidth: 24));
    assert(drawBoxLines(lazyContent, "T", BoxProps(minWidth: 24, maxWidth: 24)).join("\n") == want);
}

@("drawBox.wrap.preservesInternalWhitespace")
@system unittest
{
    import std.algorithm.searching : canFind;

    // `preserve` wrapping keeps internal space runs (aligned columns) intact even in
    // a width-capped box; `collapse` would have folded "Name    Role" to "Name Role".
    const box = drawBox(["Name    Role", "Bob     Dev"], "T", BoxProps(maxWidth: 30));
    assert(box.canFind("Name    Role"));
    assert(box.canFind("Bob     Dev"));
}

@("drawBox.wrap.fixedWidthTrimsTrailingSpaceAtWrap")
@system unittest
{
    import std.string : splitLines;

    // The first 16 columns exactly fill the content area, so `preserve` would keep
    // the following space ("…wwww ") at width 17 and push the fixed-width box to 21;
    // trimming the trailing space keeps every line at the requested 20.
    const box = drawBox(["wwwwwwwwwwwwwwww x"], "T",
        BoxProps(minWidth: 20, maxWidth: 20));
    foreach (line; box.splitLines)
        assert(line.visibleWidth == 20);
}

@("drawBox.chunks.lineBufferedJoinEqualsString")
@system unittest
{
    import std.array : join;
    import std.typecons : tuple;

    // Both chunk views of drawBox concatenate (chunks carry their own newlines) to the
    // string byte-for-byte — across single-line, multi-line, footer, nested-title,
    // empty-title, omitLeftBorder-wrap, and wrapped-content layouts. The title now
    // streams through the same chunk path, so this also guards the title decomposition.
    static foreach (args; [
        tuple(["Hello"], "T", BoxProps.init),
        tuple(["Line 1", "Line 2", "Line 3"], "Title", BoxProps.init),
        tuple(["Content"], "Title", BoxProps(footer: "Done")),
        tuple(["Content"], "", BoxProps.init),
        tuple(["Body content line one"], "This is a very long multi-line title here.",
            BoxProps(maxWidth: 36, titleOverflow: TitleOverflow.wrap)),
        tuple(["Hi"], "A fairly long title to ellipsize",
            BoxProps(maxWidth: 24, omitLeftBorder: true, titleOverflow: TitleOverflow.wrap)),
        tuple(["aaaa bbbb cccc dddd", "short"], "T", BoxProps(minWidth: 20, maxWidth: 20)),
    ])
    {{
        const str = drawBox(args[0], args[1], args[2]);
        assert(drawBoxChunks!true(args[0], args[1], args[2]).join("") == str);
        assert(drawBoxChunks!false(args[0], args[1], args[2]).join("") == str);
    }}
}

@("drawBox.chunks.cellGranularMatchesLineBuffered")
@system unittest
{
    import std.array : join;
    import std.string : splitLines;

    // Finer (sub-line) chunks split each row into word-runs but concatenate to the
    // same final frame, and every row still lands on the fixed width.
    const props = BoxProps(minWidth: 24, maxWidth: 24);
    const coarse = drawBoxChunks!true(["aaaa bbbb cccc dddd", "short"], "T", props).join("");
    const fine = drawBoxChunks!false(["aaaa bbbb cccc dddd", "short"], "T", props).join("");
    assert(coarse == fine);
    foreach (line; fine.splitLines)
        assert(line.visibleWidth == 24);
}

@("drawBox.chunks.cellGranularSplitsRows")
@system unittest
{
    import std.algorithm.searching : count;

    // With sub-line chunking a multi-word row yields more than one chunk per row, so
    // pacing the output reveals the box word by word rather than row by row.
    auto r = drawBoxChunks!false(["alpha beta gamma"], "T", BoxProps(minWidth: 24, maxWidth: 24));
    size_t n;
    foreach (_; r)
        ++n;
    assert(n >= 3); // top+border+alpha, " beta", " gamma"+close+bottom (at least)
}

@("drawBox.chunks.acceptsLazyContent")
@system unittest
{
    import std.algorithm.iteration : map;
    import std.array : join;

    // Any input range of lines works; a lazy fixed-width box yields the same bytes.
    auto lazyContent = ["one", "two", "three"].map!(x => x);
    const want = drawBox(["one", "two", "three"], "T", BoxProps(minWidth: 24, maxWidth: 24));
    assert(drawBoxChunks!true(lazyContent, "T", BoxProps(minWidth: 24, maxWidth: 24)).join("") == want);
}

@("drawBox.chunks.styledCellGranularMatches")
@system unittest
{
    import std.array : join;
    import sparkles.base.term_style : stylize, Style;

    // Colours ride along with their word chunks, so the cell-granular stream still
    // reproduces drawBox's styled row exactly (reset before the border, no bleed).
    const styled = "red red red red".stylize(Style.red);
    const want = drawBox([styled], "T", BoxProps(minWidth: 24, maxWidth: 24));
    assert(drawBoxChunks!false([styled], "T", BoxProps(minWidth: 24, maxWidth: 24)).join("") == want);
}

@("drawBox.chunks.titleStreamsWordByWord")
@system unittest
{
    import std.algorithm.searching : canFind, countUntil;
    import std.array : array;

    // A single-line multi-word title streams word by word into the top border: each
    // title word lands in its own chunk, and the whole title precedes any body chunk.
    auto chunks = drawBoxChunks!false(["body"], "alpha beta gamma",
        BoxProps(minWidth: 40, maxWidth: 40)).array;
    const iAlpha = chunks.countUntil!(c => c.canFind("alpha"));
    const iGamma = chunks.countUntil!(c => c.canFind("gamma"));
    const iBody = chunks.countUntil!(c => c.canFind("body"));
    assert(iAlpha >= 0 && iGamma >= 0 && iBody >= 0);
    assert(iAlpha < iGamma && iGamma < iBody); // title types out, then the body
}

@("drawBox.chunks.nestedTitleStreamsBeforeBody")
@system unittest
{
    import std.algorithm.searching : canFind, countUntil;
    import std.array : array;

    // A wrapped (nested) title streams its words too: several title chunks appear, all
    // before any body chunk.
    auto chunks = drawBoxChunks!false(["Body content line one"],
        "This is a very long multi-line title here.",
        BoxProps(maxWidth: 36, titleOverflow: TitleOverflow.wrap)).array;
    const iBody = chunks.countUntil!(c => c.canFind("Body"));
    assert(iBody > 0);
    size_t titleChunks;
    foreach (i, c; chunks)
        if (i < iBody && (c.canFind("This") || c.canFind("very")
                || c.canFind("title") || c.canFind("here")))
            ++titleChunks;
    assert(titleChunks >= 3);
}

@("drawBox.chunks.styledNestedTitleConcatMatches")
@system unittest
{
    import std.array : join;
    import sparkles.base.term_style : stylize, Style;

    // A styled wrapped title still concatenates to drawBox byte-for-byte — guards the
    // reset asymmetry (nested title rows get a style reset, the close pad/border follow
    // it exactly, no bleed onto the frame).
    const styled = "alpha beta gamma delta epsilon".stylize(Style.red);
    const props = BoxProps(maxWidth: 24, titleOverflow: TitleOverflow.wrap);
    assert(drawBoxChunks!false(["body"], styled, props).join("") == drawBox(["body"], styled, props));
}

@("drawBox.chunks.titleOnlyNoBody")
@system unittest
{
    import std.array : join;

    // A nested title with no content: the title streams, the bottom border attaches to
    // the last title chunk, and the whole thing still equals drawBox.
    string[] noBody;
    const title = "This is a very long multi-line title here.";
    const props = BoxProps(maxWidth: 36, titleOverflow: TitleOverflow.wrap);
    assert(drawBoxChunks!false(noBody, title, props).join("") == drawBox(noBody, title, props));
}

@("drawBox.content.preservesBlankLines")
@system unittest
{
    import std.algorithm.searching : count;
    import std.array : join;
    import std.string : splitLines;

    // An empty source line wraps to nothing, but must still render as a blank bordered
    // row — across the eager (no-wrap), eager-wrapped, and fixed-width streaming paths,
    // and identically for drawBox / drawBoxChunks.
    string[] content = ["1", "", "", "2"];
    static foreach (props; [
        BoxProps.init, // eager, no wrapping
        BoxProps(maxWidth: 20), // eager, content wrapped per line
        BoxProps(minWidth: 20, maxWidth: 20), // fixed width, streamed
    ])
    {{
        const box = drawBox(content, "T", props);
        // Four content rows (two of them blank) between the borders.
        assert(box.splitLines.length == 6);
        assert(drawBoxChunks!true(content, "T", props).join("") == box);
        assert(drawBoxChunks!false(content, "T", props).join("") == box);
    }}
}
