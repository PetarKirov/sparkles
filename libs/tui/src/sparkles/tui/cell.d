/++
The neutral target picture: a 2-D grid of styled cells.

This is the representation a widget tree paints into each frame and the ground
truth the renderer ($(MREF sparkles,tui,render)) diffs to a minimal byte stream.
A grid is exactly what a terminal displays, so the model is architecture-neutral:
draw into a $(LREF Grid), hand it to the renderer, and only the cells that changed
since the last frame are emitted.

The rendering core (2-D cell-grid with a compact packed cell) was chosen by the
[render-cost benchmark](../../../../../docs/specs/tui/render-bench-baseline.md);
this module is that benchmark's winning `cell.d` PoC, promoted into the library.

Style is the shaped `TermStyle` (truecolor `Color` fg/bg, `TextAttr`, an
`UnderlineStyle` shape, and an independent SGR-58 underline color — 12 bytes), so
a cell can carry a colored undercurl (the twoslash error squiggle). SGR emission
reuses the absolute reset-then-set encoder
$(REF writeStyle, sparkles,base,term_style) so a style-run is self-establishing
and trivial for a VT to reconstruct; the renderer coalesces it per run so the
byte cost stays realistic.
+/
module sparkles.tui.cell;

public import sparkles.base.term_color : Color, ColorDepth;
public import sparkles.base.term_style : CompactTermStyle, TextAttr, TermStyle,
    UnderlineStyle, writeStyle;

import core.lifetime : emplace, move, moveEmplace;
import core.memory : pureMalloc, pureFree;
import sparkles.base.buffer : SharedBuffer;
import sparkles.base.text.grapheme : byGraphemeCluster;
import sparkles.base.text.utf : encodeScalar, decodeToken, encodeToken,
    utfStorageOverlaps, UtfMode, UtfStatus;
import sparkles.base.text.utf16 : measureConversion;

/// The cell's style: the shaped `TermStyle` (3 packed words, 12 bytes) so a cell
/// can hold an SGR-58 underline color — the twoslash error undercurl and other
/// rich underlines. (The compact `TermStyle!false`, 2 words, drops the underline
/// color; the frozen render-bench PoC copy stays on it.) The base `writeStyle`
/// emits the undercurl color for the shaped form; this alias is the single seam a
/// size-sensitive consumer flips back.
alias CellStyle = TermStyle;

/// One display cell: a complete UTF-8 grapheme, its display width and its style.
/// Short clusters stay inline; long clusters use owned, copy-on-write storage.
/// The inline capacity is not a Unicode boundary or rendering limit.
struct CellT(uint MaxBytes = 16)
{
    static assert(MaxBytes >= 4 && MaxBytes < ubyte.max);
    private enum ubyte overflowLength = cast(ubyte)(MaxBytes + 1);
    ubyte len = 1;
    ubyte width = 1;
    /// The OSC 8 hyperlink this cell belongs to: an index into the URI table
    /// the renderer is given, `0` for none.
    ///
    /// Here rather than in `style` on purpose. `CellStyle` is `TermStyle`, an
    /// `align(1) uint[3]` that every builtin theme bakes into static data, and
    /// a hyperlink is not a style: two cells can share every colour and
    /// attribute while pointing at different URLs. It participates in
    /// `opEquals` so the retained diff repaints a cell whose link changed.
    ///
    /// A `ushort` keeps this metadata compact alongside the owned payload.
    /// No frame has 65535 distinct hyperlinks.
    ushort linkId;
    CellStyle style;
    private SharedBuffer!(char, MaxBytes) _glyph;

    /// The grapheme cluster's bytes.
    const(char)[] grapheme() scope return const @safe pure nothrow @nogc
    {
        if (len == 0)
            return null;
        if (_glyph.empty)
            return " ";
        // The buffer's inline and heap views both borrow this owning cell.
        // DIP1000 cannot express both return-ref-this and return-scope-this.
        return (() @trusted { return _glyph[]; })();
    }

    /// Set this cell to a single code point (encoded to UTF-8) with `width`.
    /// `link` defaults to "no hyperlink", so a cell repainted by a writer that
    /// knows nothing about links correctly loses the one it used to carry.
    void setCodepoint(dchar cp, ubyte w, in CellStyle st, ushort link = 0)
        @safe pure nothrow @nogc
    {
        char[4] buf = void;
        const n = encodeScalar(cp, buf[], UtfMode.replacement).written;
        setBytes(buf[0 .. n], w, st, link);
    }

    /// Store a complete already-encoded cluster. `malformed` explicitly requests
    /// owned maximal-subpart replacement before publishing rendered UTF-8.
    void setBytes(scope const(char)[] cluster, ubyte w, in CellStyle st,
        ushort link = 0, bool malformed = false) @safe pure nothrow @nogc
    {
        size_t required = cluster.length;
        if (malformed)
        {
            const measured = measureConversion!char(cluster, UtfMode.replacement);
            assert(measured.hasValue, "Rendered cluster length overflow");
            required = measured.value.required;
        }
        const samePayload = !malformed && cluster.length == _glyph.length
            && (cluster.ptr is _glyph[].ptr || (required > MaxBytes && cluster == _glyph[]));
        if (!samePayload)
        {
            if (utfStorageOverlaps(cluster, _glyph[]))
            {
                // A subview of our own payload must survive replacement of its owner.
                SharedBuffer!(char, MaxBytes) staged;
                staged.reserve(required);
                appendCluster(staged, cluster, malformed);
                _glyph = move(staged);
            }
            else
            {
                // Short writes use inline storage instead of cloning an old shared
                // heap block. Long writes reuse capacity whenever uniquely owned.
                _glyph.clear(releaseStorage: required <= MaxBytes);
                _glyph.reserve(required);
                appendCluster(_glyph, cluster, malformed);
            }
        }
        len = required <= MaxBytes ? cast(ubyte) required : overflowLength;
        width = w;
        style = st;
        linkId = link;
    }

    private static void appendCluster(scope ref SharedBuffer!(char, MaxBytes) target,
        scope const(char)[] source, bool malformed) @safe pure nothrow @nogc
    {
        if (!malformed)
        {
            target.put(source);
            return;
        }
        size_t offset;
        while (offset < source.length)
        {
            const decoded = decodeToken(source[offset .. $], UtfMode.replacement);
            char[4] encoded;
            const result = encodeToken(decoded.token, encoded[]);
            assert(result.status == UtfStatus.ok);
            target.put(encoded[0 .. result.written]);
            offset += decoded.result.consumed;
        }
    }

    /// The first code point of this cell's grapheme (0x20 for a blank cell).
    uint codepoint() const scope @safe pure nothrow @nogc
        => len == 0 ? 0x20 : decodeToken(grapheme, UtfMode.replacement).token.scalar;

    bool opEquals(in CellT o) const @safe pure nothrow @nogc
        => len == o.len && width == o.width && style == o.style
            && linkId == o.linkId
            && grapheme == o.grapheme;
}

/// The default cell has 16 inline bytes plus owned storage for longer clusters.
alias Cell = CellT!16;

/// A rectangular grid of cells, indexed `[x, y]` with `[0, 0]` top-left.
///
/// Owns initialized cells, including their nontrivial cluster owners. Copy
/// construction/assignment retain shared long payloads; mutations copy on write.
struct GridT(uint MaxBytes = 16)
{
    private
    {
        alias C = CellT!MaxBytes;
        C[] _cells;
        ushort _cols;
        ushort _rows;
    }

    ~this() @safe pure nothrow @nogc
    {
        foreach (ref cell; _cells)
            destroy(cell);
        (() @trusted { pureFree(_cells.ptr); })();
    }

    /// Deep-copy constructor (the storage is otherwise move-only).
    this(ref const GridT other) @safe nothrow
    {
        assignFrom(other);
    }

    /// Deep-copy assignment, reusing this grid's capacity — the render loop's
    /// `_prev = target`, zero-allocation once capacity is established.
    void opAssign(ref const GridT other) @safe nothrow
    {
        assignFrom(other);
    }

    /// Column count.
    ushort cols() const scope @safe pure nothrow @nogc => _cols;
    /// Row count.
    ushort rows() const scope @safe pure nothrow @nogc => _rows;

    /// Resize (reusing capacity) and clear to blank cells.
    void resize(ushort cols, ushort rows) @safe nothrow
    {
        _cols = cols;
        _rows = rows;
        grow(count);
        clear();
    }

    /// Reset every live cell to a blank styled space.
    void clear() @safe nothrow
    {
        _cells[] = C.init;
    }

    /// Fill every live cell with a blank cell in `st` (e.g. a page background).
    void clearTo(in CellStyle st) @safe nothrow
    {
        C blank;
        blank.style = st;
        _cells[] = blank;
    }

    /// The cell at `[x, y]` (bounds-checked in `-debug`/unittest via the contract).
    ref C opIndex(ushort x, ushort y) return scope @safe pure nothrow @nogc
    in (x < _cols && y < _rows)
        => _cells[cast(size_t) y * _cols + x];

    /// ditto
    ref const(C) opIndex(ushort x, ushort y) const return scope @safe pure nothrow @nogc
    in (x < _cols && y < _rows)
        => _cells[cast(size_t) y * _cols + x];

    /// Row `y` as a mutable cell slice.
    C[] row(ushort y) return scope @safe pure nothrow @nogc
    in (y < _rows)
        => _cells[cast(size_t) y * _cols .. cast(size_t)(y + 1) * _cols];

    /// ditto (read-only)
    const(C)[] row(ushort y) const return scope @safe pure nothrow @nogc
    in (y < _rows)
        => _cells[cast(size_t) y * _cols .. cast(size_t)(y + 1) * _cols];

    /// Write whole owned graphemes, stopping before a cluster that does not fit
    /// the right edge. Zero-advance controls/escapes have no grid occupancy.
    ushort putText(ushort x, ushort y, scope const(char)[] text, in CellStyle st)
        @safe pure nothrow @nogc
    {
        foreach (cluster; byGraphemeCluster(text))
        {
            if (cluster.isEscape || cluster.width == 0)
                continue;
            if (x >= _cols || cluster.width > _cols - x)
                break;
            const w = cast(ubyte) cluster.width;
            this[x, y].setBytes(cluster.slice, w, st, 0, cluster.hasMalformed);
            if (w == 2)
                this[cast(ushort)(x + 1), y].setCodepoint(' ', 0, st);
            x = cast(ushort)(x + w);
        }
        return x;
    }

    /// Fill a horizontal run `[x, x+n)` on row `y` with a styled space.
    void fill(ushort x, ushort y, ushort n, in CellStyle st) @safe pure nothrow @nogc
    {
        foreach (i; 0 .. n)
        {
            if (x + i >= _cols)
                break;
            this[cast(ushort)(x + i), y].setCodepoint(' ', 1, st);
        }
    }

    /// Fill a rectangle `[x, x+w) × [y, y+h)` with a styled space — a bulk clear
    /// (e.g. a widget's background panel).
    void fillRect(ushort x, ushort y, ushort w, ushort h, in CellStyle st) @safe pure nothrow @nogc
    {
        foreach (yy; y .. y + h)
        {
            if (yy >= _rows)
                break;
            fill(x, cast(ushort) yy, w, st);
        }
    }

    /// Translate a rectangle's content vertically by `dy` rows (positive = down,
    /// negative = up): rows scrolled out of the rect are dropped and the `|dy|`
    /// vacated rows filled with a styled space. A **full-width** rect (`x == 0`,
    /// `w >= cols`) is what $(REF Screen, sparkles,tui,render) recognizes and
    /// turns into a terminal hardware scroll — a bulk update instead of a per-cell
    /// diff; a sub-width rect is a plain content move (no hardware scroll).
    void scrollRect(ushort x, ushort y, ushort w, ushort h, int dy, in CellStyle st)
        @safe pure nothrow @nogc
    {
        if (dy == 0 || h == 0 || w == 0)
            return;
        const ad = dy > 0 ? dy : -dy;
        if (ad >= h)
        {
            fillRect(x, y, w, h, st); // everything scrolled out
            return;
        }
        if (dy > 0) // content moves down: copy high → low, blank the top band
        {
            for (int i = h - 1; i >= ad; --i)
                copySeg(cast(ushort)(y + i), cast(ushort)(y + i - dy), x, w);
            fillRect(x, y, w, cast(ushort) ad, st);
        }
        else // content moves up: copy low → high, blank the bottom band
        {
            for (int i = 0; i + ad < h; ++i)
                copySeg(cast(ushort)(y + i), cast(ushort)(y + i + ad), x, w);
            fillRect(x, cast(ushort)(y + h - ad), w, cast(ushort) ad, st);
        }
    }

    private:

    // Live cells are distinct from initialized, reusable storage capacity.
    size_t count() const scope @safe pure nothrow @nogc => cast(size_t) _cols * _rows;

    // Buffer intentionally excludes nontrivial element lifetimes. Allocate an
    // initialized cell array here; move owners when its capacity must grow.
    void grow(size_t n) @safe nothrow
    {
        if (_cells.length >= n)
            return;
        const doubled = _cells.length <= size_t.max / 2 ? _cells.length * 2 : size_t.max;
        const capacity = n > doubled ? n : doubled;
        assert(capacity <= size_t.max / C.sizeof, "Cell storage size overflow");
        auto replacement = ((size_t size) @trusted {
            auto ptr = cast(C*) pureMalloc(size * C.sizeof);
            assert(ptr !is null, "Cell storage allocation failed");
            return ptr[0 .. size];
        })(capacity);
        foreach (i; 0 .. _cells.length)
            ((ref C from, ref C to) @trusted { moveEmplace(from, to); })(_cells[i], replacement[i]);
        foreach (i; _cells.length .. capacity)
            ((C* slot) @trusted { emplace!C(slot); })(&replacement[i]);
        (() @trusted { pureFree(_cells.ptr); })();
        _cells = replacement;
    }

    // Deep-copy `other`'s dimensions + live cells into this (reusing capacity).
    void assignFrom(ref const GridT other) @safe nothrow
    {
        _cols = other._cols;
        _rows = other._rows;
        const n = count;
        grow(n);
        _cells[][0 .. n] = other._cells[][0 .. n];
    }

    // Copy the cell segment `[x, x+w)` from row `srcY` to row `dstY`.
    void copySeg(ushort dstY, ushort srcY, ushort x, ushort w) @safe pure nothrow @nogc
    {
        if (dstY >= _rows || srcY >= _rows)
            return;
        if (x == 0 && w >= _cols)
        {
            row(dstY)[] = row(srcY)[]; // whole-row fast path
            return;
        }
        const x1 = x + w > _cols ? _cols : x + w;
        foreach (xx; x .. x1)
            this[cast(ushort) xx, dstY] = this[cast(ushort) xx, srcY];
    }
}

/// The grid type used across the library — cells with the default inline size.
alias Grid = GridT!16;

@("cell.grid.putTextAndWidth")
@safe nothrow
unittest
{
    Grid g;
    g.resize(10, 2);
    const st = CellStyle(fg: Color.fromRgb(255, 0, 0), attrs: TextAttr.bold);
    const nx = g.putText(0, 0, "hi", st);
    assert(nx == 2);
    assert(g[0, 0].grapheme == "h");
    assert(g[1, 0].style.attrs == TextAttr.bold);
    assert(g[2, 0].grapheme == " "); // untouched blank
    // Long cluster storage is owned independently of the inline capacity.
}

@("cell.grid.wideGlyphContinuation")
@safe nothrow
unittest
{
    Grid g;
    g.resize(6, 1);
    // A wide (CJK) code point occupies two columns: the glyph + a zero-width cont.
    g.putText(0, 0, "世", CellStyle.init); // 世
    assert(g[0, 0].width == 2);
    assert(g[1, 0].width == 0); // continuation carries no bytes
}

@("cell.grid.copyAndAssign")
@safe nothrow
unittest
{
    Grid a;
    a.resize(4, 2);
    a.putText(0, 0, "hi", CellStyle.init);

    // Copy-constructor: an independent deep copy.
    auto b = a;
    assert(b[0, 0].grapheme == "h" && b.cols == 4 && b.rows == 2);
    b.putText(0, 0, "XY", CellStyle.init);
    assert(a[0, 0].grapheme == "h"); // original unaffected

    // Capacity-reusing assignment (the render loop's `_prev = target`).
    Grid c;
    c = a;
    assert(c[0, 0].grapheme == "h" && c[1, 0].grapheme == "i");
}

@("cell.grid.scrollRectAndFillRect")
@safe nothrow
unittest
{
    static immutable string[5] labels = ["aa", "bb", "cc", "dd", "ee"];
    Grid g;
    g.resize(4, 5);
    foreach (ushort y; 0 .. 5)
        g.putText(0, y, labels[y], CellStyle.init);

    // Scroll the content up by 2: "aa"/"bb" drop off, "cc" is at the top, the
    // bottom two rows are blanked.
    g.scrollRect(0, 0, 4, 5, -2, CellStyle.init);
    assert(g[0, 0].grapheme == "c"); // "cc" now at row 0
    assert(g[0, 2].grapheme == "e"); // "ee" now at row 2
    assert(g[0, 3].grapheme == " "); // vacated
    assert(g[0, 4].grapheme == " ");

    // Scroll down by 1: everything moves down one, the top row blanks.
    g.scrollRect(0, 0, 4, 5, 1, CellStyle.init);
    assert(g[0, 0].grapheme == " ");
    assert(g[0, 1].grapheme == "c");

    // fillRect paints a styled blank rectangle.
    const st = CellStyle(fg: Color.fromRgb(1, 2, 3));
    g.fillRect(0, 0, 4, 5, st);
    assert(g[2, 2].grapheme == " " && g[2, 2].style.fg == Color.fromRgb(1, 2, 3));
}

@("cell.grid.longClustersAndOwnedCopies")
@safe nothrow
unittest
{
    char[1025] cluster;
    cluster[0] = 'A';
    foreach (i; 0 .. 512)
        cluster[1 + i * 2 .. 3 + i * 2] = "\u0301";
    Grid grid;
    grid.resize(4, 1);
    assert(grid.putText(0, 0, cluster[], CellStyle.init) == 1);
    assert(grid[0, 0].grapheme == cluster[]);
    auto previous = grid;
    grid.putText(0, 0, "B", CellStyle.init);
    assert(grid[0, 0].grapheme == "B");
    assert(previous[0, 0].grapheme == cluster[]);
    Cell detached;
    {
        Grid temporary;
        temporary.resize(2, 1);
        temporary.putText(0, 0, cluster[], CellStyle.init);
        detached = temporary[0, 0];
    }
    assert(detached.grapheme == cluster[]);
    previous.resize(64, 4);
    previous.putText(0, 0, cluster[], CellStyle.init);
    assert(previous[0, 0].grapheme == cluster[]);
}

@("cell.grid.wholeClusterFitAndMalformedRendering")
@safe nothrow
unittest
{
    Grid grid;
    grid.resize(3, 2);
    assert(grid.putText(0, 0, "👩‍👩‍👧‍👦x", CellStyle.init) == 3);
    assert(grid[0, 0].grapheme == "👩‍👩‍👧‍👦");
    assert(grid[0, 0].width == 2 && grid[1, 0].width == 0);
    assert(grid[2, 0].grapheme == "x");
    assert(grid.putText(2, 0, "界", CellStyle.init) == 2);
    assert(grid[2, 0].grapheme == "x");
    char[33] malformed;
    malformed[0] = '\xFF';
    foreach (i; 0 .. 16)
        malformed[1 + i * 2 .. 3 + i * 2] = "\u0301";
    assert(grid.putText(0, 1, malformed[], CellStyle.init) == 1);
    const rendered = grid[0, 1].grapheme;
    assert(rendered.length == 35 && rendered[0 .. 3] == "\uFFFD");
    assert(rendered[3 .. $] == malformed[1 .. $]);
}
