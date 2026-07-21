/++
The correctness gate: an independent VT reconstructs each renderer's picture.

line-diff and cell-diff legitimately emit different bytes for the same picture, so
we cannot fingerprint the bytes. Instead every renderer's output is replayed into a
real terminal — the vendored `libghostty-vt` (`sparkles:ghostty`) — and the grid it
reconstructs is fingerprinted (normalized grapheme + fg/bg/attrs per cell) and
compared, frame by frame, against the target grid. A renderer that drops, mangles,
or mis-positions an update produces a different grid and fails. This is the wired
harness's "an engine that renders differently must never look faster," using a
production terminal as the oracle we get for free.

The whole module is gated behind `version(TuiBenchVtOracle)` (it needs the
`ghostty-vt` pkg-config from the nix devshell); the default build compiles it away
so `dub test` stays toolchain-light. See the package README to enable it.

Scope: runs on the width-1 profiles (`mixed`, `sparse`, `churn`, `scroll`,
`resize`). The `unicode` profile's wide-cell spacer alignment is a follow-up.
+/
module sparkles.tui_render_bench.vt_oracle;

version (TuiBenchVtOracle):

import sparkles.ghostty;
import sparkles.tui_render_bench.cell : calibAttrs, calibColorPayload, calibColorTag, Cell,
    firstCodepoint, Grid;

// ---------------------------------------------------------------------------
// Shared normalized fingerprint (identical hashing on both sides).
// ---------------------------------------------------------------------------

private enum ulong fnvOffset = 0xCBF29CE484222325UL;

private void mix(ref ulong h, ubyte b) @safe pure nothrow @nogc
{
    h ^= b;
    h *= 0x0000_0100_0000_01B3UL;
}

private void mix16(ref ulong h, ushort v) @safe pure nothrow @nogc
{
    mix(h, cast(ubyte)(v & 0xFF));
    mix(h, cast(ubyte)(v >> 8));
}

private void mix32(ref ulong h, uint v) @safe pure nothrow @nogc
{
    foreach (i; 0 .. 4)
        mix(h, cast(ubyte)((v >> (8 * i)) & 0xFF));
}

/// Hash one normalized cell — the single canonical form both sides target.
private void hashCell(ref ulong h, uint cp,
    ubyte fgTag, ubyte fa, ubyte fb, ubyte fc,
    ubyte bgTag, ubyte ba, ubyte bb, ubyte bc, ubyte attrs) @safe pure nothrow @nogc
{
    mix32(h, cp);
    mix(h, fgTag);
    mix(h, fa);
    mix(h, fb);
    mix(h, fc);
    mix(h, bgTag);
    mix(h, ba);
    mix(h, bb);
    mix(h, bc);
    mix(h, attrs);
}

/// Canonical attribute bits: bold=1, dim=2, italic=4, underline=8, reverse=16.
/// Mapped from `TermStyle` via `calibAttrs` (underline is a shape, not a TextAttr bit).

/// Fingerprint the target grid in the shared normalized form.
ulong normFingerprint(in Grid g) @safe pure nothrow @nogc
{
    ulong h = fnvOffset;
    mix16(h, g.cols);
    mix16(h, g.rows);
    foreach (ushort y; 0 .. g.rows)
        foreach (ushort x; 0 .. g.cols)
        {
            const c = g.at(x, y);
            const cp = firstCodepoint(c.grapheme);
            ubyte fa, fb, fc, ba, bb, bc;
            calibColorPayload(c.style.fg, fa, fb, fc);
            calibColorPayload(c.style.bg, ba, bb, bc);
            hashCell(h, cp,
                calibColorTag(c.style.fg), fa, fb, fc,
                calibColorTag(c.style.bg), ba, bb, bc,
                calibAttrs(c.style));
        }
    return h;
}

// ---------------------------------------------------------------------------
// The VT oracle.
// ---------------------------------------------------------------------------

/// A libghostty-vt terminal that reconstructs a renderer's picture from bytes.
struct VtOracle
{
    private GhosttyTerminal _term;
    private ushort _cols;
    private ushort _rows;

    ///
    ushort cols() const @safe pure nothrow @nogc => _cols;
    ///
    ushort rows() const @safe pure nothrow @nogc => _rows;

    /// Create the terminal at `cols`×`rows` (default allocator, no scrollback).
    void open(ushort cols, ushort rows) @trusted
    {
        GhosttyTerminalOptions opts;
        opts.cols = cols;
        opts.rows = rows;
        opts.max_scrollback = 0;
        const r = ghostty_terminal_new(null, &_term, opts);
        assert(r == GHOSTTY_SUCCESS, "ghostty_terminal_new failed");
        _cols = cols;
        _rows = rows;
    }

    /// Free the terminal (idempotent).
    void close() @trusted
    {
        if (_term !is null)
        {
            ghostty_terminal_free(_term);
            _term = null;
        }
    }

    /// Resize (on a `resize`-profile event; the renderer full-repaints after).
    void resize(ushort cols, ushort rows) @trusted
    {
        ghostty_terminal_resize(_term, cols, rows, 0, 0);
        _cols = cols;
        _rows = rows;
    }

    /// Feed one frame's emitted bytes into the terminal.
    void writeFrame(scope const(char)[] bytes) @trusted
    {
        if (bytes.length)
            ghostty_terminal_vt_write(_term, cast(const(ubyte)*) bytes.ptr, bytes.length);
    }

    /// Fingerprint the active screen in the shared normalized form.
    ulong fingerprint() @trusted
    {
        ulong h = fnvOffset;
        mix16(h, _cols);
        mix16(h, _rows);
        foreach (ushort y; 0 .. _rows)
            foreach (ushort x; 0 .. _cols)
            {
                GhosttyPoint pt;
                pt.tag = GHOSTTY_POINT_TAG_ACTIVE;
                pt.value.coordinate.x = x;
                pt.value.coordinate.y = y;

                GhosttyGridRef gref;
                gref.size = GhosttyGridRef.sizeof;
                if (ghostty_terminal_grid_ref(_term, pt, &gref) != GHOSTTY_SUCCESS)
                {
                    hashCell(h, 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0);
                    continue;
                }

                uint[8] cps;
                size_t outLen;
                ghostty_grid_ref_graphemes(&gref, cps.ptr, cps.length, &outLen);
                const cp = outLen ? cps[0] : 0x20;

                GhosttyStyle st;
                st.size = GhosttyStyle.sizeof;
                ghostty_grid_ref_style(&gref, &st);

                ubyte fgTag, fa, fb, fc;
                normColor(st.fg_color, fgTag, fa, fb, fc);
                ubyte bgTag, ba, bb, bc;
                normColor(st.bg_color, bgTag, ba, bb, bc);
                const ubyte attrs = cast(ubyte)(
                    (st.bold ? 1 : 0) | (st.faint ? 2 : 0) | (st.italic ? 4 : 0)
                        | (st.underline ? 8 : 0) | (st.inverse ? 16 : 0));

                hashCell(h, cp, fgTag, fa, fb, fc, bgTag, ba, bb, bc, attrs);
            }
        return h;
    }
}

private void normColor(in GhosttyStyleColor c, out ubyte tag, out ubyte a, out ubyte b, out ubyte cc) @trusted
{
    switch (c.tag)
    {
        case GHOSTTY_STYLE_COLOR_PALETTE:
            tag = 1;
            a = c.value.palette;
            break;
        case GHOSTTY_STYLE_COLOR_RGB:
            tag = 2;
            a = c.value.rgb.r;
            b = c.value.rgb.g;
            cc = c.value.rgb.b;
            break;
        default: // GHOSTTY_STYLE_COLOR_NONE
            tag = 0;
            break;
    }
}

// ---------------------------------------------------------------------------
// Verify a renderer against the oracle over a whole scenario.
// ---------------------------------------------------------------------------

/// The first frame at which a renderer's reconstructed grid diverged, if any.
struct VerifyResult
{
    bool ok = true;
    size_t frame;
    ulong targetFp;
    ulong vtFp;
}

/// Replay a renderer over a scenario, checking every frame against the oracle.
VerifyResult verifyAgainstOracle(R, S)(ref R renderer, in S scn) @system
{
    import sparkles.tui_render_bench.replay : replayScenario;
    import sparkles.tui_render_bench.sink : Sink;

    VtOracle oracle;
    oracle.open(scn.cols, scn.rows);
    scope (exit)
        oracle.close();

    Sink sink;
    VerifyResult res;
    replayScenario(renderer, scn, sink,
        (in Grid target, scope const(char)[] frameBytes, size_t fi) {
        if (!res.ok)
            return;
        if (target.cols != oracle.cols || target.rows != oracle.rows)
            oracle.resize(target.cols, target.rows);
        oracle.writeFrame(frameBytes);
        const vfp = oracle.fingerprint();
        const tfp = normFingerprint(target);
        if (vfp != tfp)
        {
            res.ok = false;
            res.frame = fi;
            res.targetFp = tfp;
            res.vtFp = vfp;
        }
    });
    return res;
}

@("vtOracle.allRenderers.reconstructTargetEveryFrame")
@system
unittest
{
    import std.meta : AliasSeq;
    import sparkles.tui_render_bench.pocs.reference_fullpaint : ReferenceFullpaint;
    import sparkles.tui_render_bench.pocs.line_diff : LineDiff;
    import sparkles.tui_render_bench.pocs.line_diff_lazy : LineDiffLazy;
    import sparkles.tui_render_bench.pocs.cell_grid : CellGrid;
    import sparkles.tui_render_bench.scenario : generateScenario, Profile;

    // The diffing renderers legitimately emit different bytes from the reference
    // and from each other — but every one must reconstruct the identical picture,
    // on every frame, on the width-1 profiles.
    static foreach (R; AliasSeq!(ReferenceFullpaint, LineDiff, LineDiffLazy, CellGrid))
        foreach (p; [Profile.sparse, Profile.churn, Profile.scroll, Profile.resize, Profile.mixed])
        {
            auto scn = generateScenario(p, 80, 24, 40);
            R r;
            const res = verifyAgainstOracle(r, scn);
            assert(res.ok, R.label ~ " diverged from the VT oracle");
        }
}
