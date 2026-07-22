/++
The shared rendering spec: `renderScene` fills the target grid from the model.

This is the one place that decides what the dashboard $(I looks like) — a full
operations UI (header + clock, scrollable log pane, selectable data table,
expand/collapse tree, spinners + progress footer, status line). Every renderer is
handed the grid this produces and is measured on how cheaply it turns a sequence
of them into bytes; because they all share this exact target, neither the
line-diff nor the cell-grid PoC is favoured by the content.

The target grid is a pure function of the model, recomputed in full each frame.
+/
module sparkles.tui_render_bench.scene;

import sparkles.tui_render_bench.cell : CellStyle, Color, Grid, TextAttr, UnderlineStyle;
import sparkles.tui_render_bench.model : Model;
import sparkles.tui_render_bench.scenario : sceneTableRows, sceneTreeNodes;

// Palette (truecolor — the benchmark must exercise RGB, spec C1).
private enum Color cFg = Color.fromRgb(0xC8, 0xD3, 0xE0);
private enum Color cAccent = Color.fromRgb(0x7A, 0xA2, 0xF7);
private enum Color cBarBg = Color.fromRgb(0x24, 0x28, 0x33);
private enum Color cSelBg = Color.fromRgb(0x33, 0x3A, 0x52);
private enum Color cOk = Color.fromRgb(0x9E, 0xCE, 0x6A);
private enum Color cWarn = Color.fromRgb(0xE0, 0xAF, 0x68);
private enum Color cErr = Color.fromRgb(0xF7, 0x76, 0x8E);
private enum Color cMuted = Color.fromRgb(0x56, 0x5F, 0x89);

private immutable string[10] spinnerFrames = [
    "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
];
private immutable string[sceneTableRows] nodeNames = [
    "node-eu-1", "node-eu-2", "node-us-1", "node-us-2",
    "node-ap-1", "node-ap-2", "gateway", "registry",
];
private immutable string[4] phases = ["build", "transfer", "activate", "verify"];
private immutable string[sceneTreeNodes] treeLabels = [
    "fleet", "  eu", "    node-eu-1", "    node-eu-2", "  us", "    node-us-1",
    "    node-us-2", "  ap", "    node-ap-1", "  services", "    gateway", "    registry",
];

/// Fill `g` with the dashboard for `m` (resizes + clears first).
void renderScene(in Model m, ref Grid g) @safe nothrow
{
    g.resize(m.cols, m.rows);
    if (m.cols < 24 || m.rows < 8)
        return; // too small to lay out; leave blank

    const split = cast(ushort)(m.cols * 3 / 5); // log pane | right column

    drawHeader(m, g);
    drawLog(m, g, 1, cast(ushort)(m.rows - 2), split);
    const rightX = cast(ushort)(split + 1);
    const rightW = cast(ushort)(m.cols - rightX);
    const tableBottom = cast(ushort)(1 + (m.rows - 3) / 2);
    drawTable(m, g, rightX, 1, cast(ushort)(tableBottom - 1), rightW);
    drawTree(m, g, rightX, cast(ushort)(tableBottom + 1), cast(ushort)(m.rows - 2), rightW);
    drawFooter(m, g, cast(ushort)(m.rows - 2));
    drawStatus(m, g, cast(ushort)(m.rows - 1));
}

private void drawHeader(in Model m, ref Grid g) @safe nothrow
{
    const st = CellStyle(fg: cAccent, bg: cBarBg, attrs: TextAttr.bold);
    g.fill(0, 0, m.cols, st);
    g.putText(1, 0, "sparkles ops dashboard", st);

    char[8] clock;
    formatClock(m.clockSecs, clock);
    const cx = cast(ushort)(m.cols >= 10 ? m.cols - 9 : 0);
    g.putText(cx, 0, clock[], CellStyle(fg: cFg, bg: cBarBg));
}

private void drawLog(in Model m, ref Grid g, ushort top, ushort bottom, ushort width) @safe nothrow
{
    const height = bottom > top ? cast(ushort)(bottom - top) : 0;
    const avail = m.visibleLogCount;
    foreach (r; 0 .. height)
    {
        const y = cast(ushort)(top + r);
        // Newest at the bottom, offset by the scroll position.
        const fromBottom = (height - 1 - r) + m.logScroll;
        if (fromBottom < 0 || fromBottom >= avail)
            continue;
        const line = m.logPool[m.logAt(fromBottom)];
        g.putText(0, y, line, logStyle(line, cast(ushort)(width)));
    }
}

private CellStyle logStyle(scope const(string) line, ushort width) @safe nothrow
{
    Color fg = cFg;
    if (line.length >= 4)
    {
        if (line[0 .. 4] == "ERRO")
            fg = cErr;
        else if (line[0 .. 4] == "WARN")
            fg = cWarn;
        else if (line[0 .. 4] == "DEBU" || line[0 .. 4] == "TRAC")
            fg = cMuted;
        else if (line[0 .. 4] == "INFO")
            fg = cOk;
    }
    return CellStyle(fg: fg);
}

private void drawTable(in Model m, ref Grid g, ushort x, ushort top, ushort bottom, ushort width) @safe nothrow
{
    if (width < 8)
        return;
    // Header row.
    g.putText(x, top, "NODE       PHASE     COUNT  STATE",
        CellStyle(fg: cAccent, attrs: TextAttr.bold, underline: UnderlineStyle.single));
    foreach (r; 0 .. sceneTableRows)
    {
        const y = cast(ushort)(top + 1 + r);
        if (y > bottom)
            break;
        const selected = r == m.selection;
        const rowBg = selected ? cSelBg : Color.init;
        const rowFg = selected ? Color.fromRgb(0xFF, 0xFF, 0xFF) : cFg;
        g.fill(x, y, width, CellStyle(fg: rowFg, bg: rowBg));

        char[16] cnt;
        const n = formatUint(m.counters[r], cnt);
        const state = m.counters[r] % 3 == 0 ? "ok" : (m.counters[r] % 3 == 1 ? "run" : "wait");
        const stFg = state == "ok" ? cOk : (state == "run" ? cWarn : cMuted);

        g.putText(x, y, nodeNames[r], CellStyle(fg: rowFg, bg: rowBg));
        g.putText(cast(ushort)(x + 11), y, phases[r % phases.length], CellStyle(fg: rowFg, bg: rowBg));
        g.putText(cast(ushort)(x + 21), y, cnt[$ - n .. $], CellStyle(fg: rowFg, bg: rowBg));
        g.putText(cast(ushort)(x + 28), y, state, CellStyle(fg: stFg, bg: rowBg));
    }
}

private void drawTree(in Model m, ref Grid g, ushort x, ushort top, ushort bottom, ushort width) @safe nothrow
{
    if (width < 8 || bottom <= top)
        return;
    ushort y = top;
    foreach (n; 0 .. sceneTreeNodes)
    {
        if (y > bottom)
            break;
        const expandable = n + 1 < sceneTreeNodes && treeLabels[n + 1].length > treeLabels[n].length;
        const expanded = (m.treeExpanded & (1u << n)) != 0;
        const marker = expandable ? (expanded ? "▾ " : "▸ ") : "· ";
        g.putText(x, y, marker, CellStyle(fg: cAccent));
        g.putText(cast(ushort)(x + 2), y, treeLabels[n], CellStyle(fg: cFg));
        y++;
    }
}

private void drawFooter(in Model m, ref Grid g, ushort y) @safe nothrow
{
    const st = CellStyle(fg: cFg, bg: cBarBg);
    g.fill(0, y, m.cols, st);
    // Three spinners at different phases.
    ushort x = 1;
    foreach (i; 0 .. 3)
    {
        const frame = spinnerFrames[(m.spinnerFrame + i * 3) % spinnerFrames.length];
        g.putText(x, y, frame, CellStyle(fg: cAccent, bg: cBarBg, attrs: TextAttr.bold));
        x = cast(ushort)(x + 2);
    }
    // Progress bar.
    const barX = cast(ushort)(x + 1);
    const barW = m.cols > barX + 12 ? cast(ushort)(m.cols - barX - 8) : 0;
    if (barW > 0)
    {
        const filled = cast(ushort)((cast(long) barW * m.progressMille) / 1000);
        foreach (i; 0 .. barW)
        {
            const on = i < filled;
            g.putText(cast(ushort)(barX + i), y, on ? "█" : "░",
                CellStyle(fg: on ? cOk : cMuted, bg: cBarBg));
        }
        char[16] pct;
        const pn = formatUint(m.progressMille / 10, pct);
        g.putText(cast(ushort)(barX + barW + 1), y, pct[$ - pn .. $], st);
        g.putText(cast(ushort)(barX + barW + 1 + pn), y, "%", st);
    }
}

private void drawStatus(in Model m, ref Grid g, ushort y) @safe nothrow
{
    const st = CellStyle(fg: cMuted);
    g.fill(0, y, m.cols, st);
    g.putText(1, y, "q quit  ↑↓ select  ⏎ open  r retry", st);
}

// ---------------------------------------------------------------------------

private void formatClock(int secs, ref char[8] out_) @safe pure nothrow @nogc
{
    const s = ((secs % 86400) + 86400) % 86400;
    const hh = s / 3600, mm = (s % 3600) / 60, ss = s % 60;
    out_[0] = cast(char)('0' + hh / 10);
    out_[1] = cast(char)('0' + hh % 10);
    out_[2] = ':';
    out_[3] = cast(char)('0' + mm / 10);
    out_[4] = cast(char)('0' + mm % 10);
    out_[5] = ':';
    out_[6] = cast(char)('0' + ss / 10);
    out_[7] = cast(char)('0' + ss % 10);
}

/// Format `v` right-aligned into `buf`; returns the digit count (use `buf[$-n..$]`).
private size_t formatUint(long v, ref char[16] buf) @safe pure nothrow @nogc
{
    if (v < 0)
        v = 0;
    size_t i = buf.length;
    do
    {
        buf[--i] = cast(char)('0' + (v % 10));
        v /= 10;
    }
    while (v != 0 && i > 0);
    return buf.length - i;
}

@("scene.render.fillsHeaderAndFooter")
@safe nothrow
unittest
{
    import sparkles.tui_render_bench.model : initModel;
    import sparkles.tui_render_bench.scenario : Scenario;

    Scenario s;
    s.cols = 120;
    s.rows = 40;
    s.logPool = ["INFO build: ok", "WARN sync: slow"];
    Model m;
    initModel(m, s);

    Grid g;
    renderScene(m, g);
    assert(g.cols == 120 && g.rows == 40);
    assert(g.at(1, 0).grapheme == "s"); // "sparkles ops dashboard"
    // Status line is present on the last row.
    assert(g.at(1, cast(ushort)(g.rows - 1)).grapheme == "q");
}
