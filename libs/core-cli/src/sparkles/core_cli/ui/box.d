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
                foreach (w; cline.byWrappedLine(
                        WrapOptions(width: contentMax, whitespace: WhitespaceMode.preserve)))
                {
                    const t = stripTrailingSpaces(w);
                    rows ~= (t.canFind('\x1b') ? t ~ "\x1b[0m" : t).idup;
                }
        else
            foreach (cline; content)
                rows ~= cline.idup;
        preparedRows = rows[];
        const contentWidth = preparedRows.length ? preparedRows.map!(x => x.visibleWidth).maxElement : 0;
        outputWidth = max(baseWidth, contentWidth);
    }

    // Pre-render the (content-independent) top region and bottom border as strings.
    auto topApp = appender!string;
    if (nested)
        topApp.renderNestedTitle(titleLines, outputWidth, prefix, props);
    else
    {
        const t0 = titleLines[0];
        auto topRule = props.horizontalLine.repeat(outputWidth + prefixLen - t0.visibleWidth - 7);
        topApp ~= "╭──╼ %s ╾%s─╮\n".format(t0, topRule);
    }

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

    return BoxLineRange!Content(
        prefix.idup, outputWidth, props, topApp[].splitLines.idupArray, bottomLine,
        contentMax, canStream, preparedRows, content);
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
            }
            if (_sub.empty)
            {
                _subActive = false;
                continue;
            }
            const w = _sub.front;
            _sub.popFront;
            const t = stripTrailingSpaces(w);
            _front = borderRow(t.canFind('\x1b') ? t ~ "\x1b[0m" : t);
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
/// Returns `title` unchanged when it already fits.
private string ellipsizeTitle(string title, size_t width)
{
    import std.string : lineSplitter;

    import sparkles.base.text.wrap : wrapText, WrapOptions, WhitespaceMode;

    if (title.visibleWidth <= width)
        return title;
    if (width == 0)
        return "…";

    // wrapText (breakLongWords on) guarantees the first line is <= width - 1, so the
    // first line plus the 1-cell ellipsis is <= width.
    foreach (line; title.wrapText(
            WrapOptions(width: width - 1, whitespace: WhitespaceMode.collapse)).lineSplitter)
    {
        auto s = line.idup;
        return (s.canFind('\x1b') ? s ~ "\x1b[0m" : s) ~ "…";
    }
    return "…";
}

/// Render a wrapped title inside a nested box joined to the frame's top by `┤`/`├`
/// handles (see `TitleOverflow.wrap`). `outputWidth` is the frame's content-area
/// width, which the nested box fills exactly. Assumes a standard left frame
/// (`prefixLen == 2`); callers fall back to `ellipsis` when `omitLeftBorder`.
private void renderNestedTitle(Sink)(
    ref Sink sink, string[] titleLines, size_t outputWidth, const(dchar)[] prefix, in BoxProps props)
{
    import std.conv : to;

    const inner = outputWidth; // nested box total width == frame content area
    const field = inner - 4; // title text field inside the nested box (│ … │)
    const hl1 = props.horizontalLine.repeat(prefix.length - 1).to!string;
    const hlInner = props.horizontalLine.repeat(inner - 2).to!string;
    const pfx = prefix.to!string;
    const lead = ' '.repeat(prefix.length).to!string;

    string pad(string s) => s ~ ' '.repeat(field - s.visibleWidth).to!string;
    string reset(string s) => s.canFind('\x1b') ? s ~ "\x1b[0m" : s;

    // Nested box top, protruding above the frame into the left content margin.
    sink ~= "%s%s%s%s  \n".format(lead, props.topLeft, hlInner, props.topRight);

    // Frame top joins the nested box's first title row via the ┤/├ handles.
    sink ~= "%s%s%s %s %s%s%s\n".format(
        props.topLeft, hl1, props.titleConnectLeft,
        pad(reset(titleLines[0])),
        props.titleConnectRight, hl1, props.topRight);

    // Remaining title rows: frame border + nested box content rows.
    foreach (line; titleLines[1 .. $])
        sink ~= "%s%s %s %s %s\n".format(
            pfx, props.verticalLine, pad(reset(line)), props.verticalLine, props.verticalLine);

    // Nested box bottom, inside the frame.
    sink ~= "%s%s%s%s %s\n".format(pfx, props.bottomLeft, hlInner, props.bottomRight, props.verticalLine);
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
