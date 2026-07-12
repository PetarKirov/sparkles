// C port of the `cell_grid` renderer, byte-identical to the D implementation
// (`pocs/cell_grid.d` + `render_util.d`), for a same-algorithm cross-language
// codegen calibration. Compiled by dub via ImportC (no external toolchain), so
// the D side calls `tui_cellgrid_render` directly.
//
// Kept deliberately in lockstep with the D emission: `\x1b[?7l` once, full paint
// on the first frame (rows absolutely positioned, style coalesced per run, ending
// in `\x1b[0m`), then per-cell run diffing (one cursor move per run, no trailing
// reset). Cells carry the primary codepoint (the scene is single-codepoint per
// cell), so codepoint equality matches the D grapheme comparison.

#include <stddef.h>
#include <stdint.h>

// Mark every function `nothrow @nogc` on the D side (they neither allocate via the
// D GC nor throw), so D callers stay in `@nogc nothrow` code. See ghostty's c.c.
#pragma attribute(push, nogc, nothrow)

typedef struct {
    uint32_t cp;    // primary codepoint (0x20 for blank)
    uint8_t width;  // 0 (wide continuation) / 1 / 2
    uint8_t fg_kind, fr, fg_, fb; // kind: 0 default, 1 indexed, 2 rgb
    uint8_t bg_kind, br, bg_, bb;
    uint8_t attrs;  // bold=1 dim=2 italic=4 underline=8 reverse=16
} TuiCell;

// A bounded output cursor.
typedef struct {
    char *buf;
    size_t len;
    size_t cap;
} Out;

static void put_bytes(Out *o, const char *s, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        if (o->len < o->cap)
            o->buf[o->len] = s[i];
        o->len++;
    }
}

static void put_str(Out *o, const char *s) {
    size_t n = 0;
    while (s[n])
        n++;
    put_bytes(o, s, n);
}

static void put_uint(Out *o, unsigned int v) {
    char tmp[10];
    int i = 10;
    do {
        tmp[--i] = (char)('0' + (v % 10));
        v /= 10;
    } while (v != 0);
    put_bytes(o, tmp + i, (size_t)(10 - i));
}

static void put_cp(Out *o, uint32_t cp) {
    char b[4];
    if (cp < 0x80) {
        b[0] = (char)cp;
        put_bytes(o, b, 1);
    } else if (cp < 0x800) {
        b[0] = (char)(0xC0 | (cp >> 6));
        b[1] = (char)(0x80 | (cp & 0x3F));
        put_bytes(o, b, 2);
    } else if (cp < 0x10000) {
        b[0] = (char)(0xE0 | (cp >> 12));
        b[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[2] = (char)(0x80 | (cp & 0x3F));
        put_bytes(o, b, 3);
    } else {
        b[0] = (char)(0xF0 | (cp >> 18));
        b[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
        b[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
        b[3] = (char)(0x80 | (cp & 0x3F));
        put_bytes(o, b, 4);
    }
}

static void put_color(Out *o, uint8_t kind, uint8_t a, uint8_t b, uint8_t c, int fg) {
    if (kind == 1) { // indexed
        put_str(o, fg ? ";38;5;" : ";48;5;");
        put_uint(o, a);
    } else if (kind == 2) { // rgb
        put_str(o, fg ? ";38;2;" : ";48;2;");
        put_uint(o, a);
        put_str(o, ";");
        put_uint(o, b);
        put_str(o, ";");
        put_uint(o, c);
    }
}

static void put_style(Out *o, const TuiCell *cell) {
    put_str(o, "\x1b[0");
    if (cell->attrs & 1) put_str(o, ";1");
    if (cell->attrs & 2) put_str(o, ";2");
    if (cell->attrs & 4) put_str(o, ";3");
    if (cell->attrs & 8) put_str(o, ";4");
    if (cell->attrs & 16) put_str(o, ";7");
    put_color(o, cell->fg_kind, cell->fr, cell->fg_, cell->fb, 1);
    put_color(o, cell->bg_kind, cell->br, cell->bg_, cell->bb, 0);
    put_str(o, "m");
}

static void put_cursor(Out *o, int row, int col) {
    put_str(o, "\x1b[");
    put_uint(o, (unsigned int)row);
    put_str(o, ";");
    put_uint(o, (unsigned int)col);
    put_str(o, "H");
}

static int style_eq(const TuiCell *a, const TuiCell *b) {
    return a->attrs == b->attrs
        && a->fg_kind == b->fg_kind && a->fr == b->fr && a->fg_ == b->fg_ && a->fb == b->fb
        && a->bg_kind == b->bg_kind && a->br == b->br && a->bg_ == b->bg_ && a->bb == b->bb;
}

static int cell_eq(const TuiCell *a, const TuiCell *b) {
    return a->cp == b->cp && a->width == b->width && style_eq(a, b);
}

static void paint_full(Out *o, const TuiCell *frame, int cols, int rows) {
    int y, x;
    for (y = 0; y < rows; y++) {
        put_cursor(o, y + 1, 1);
        int first = 1;
        TuiCell cur;
        cur.cp = 0; // sentinel; `first` forces the initial style emit
        for (x = 0; x < cols; x++) {
            const TuiCell *c = &frame[y * cols + x];
            if (c->width == 0)
                continue;
            if (first || !style_eq(c, &cur)) {
                put_style(o, c);
                cur = *c;
                first = 0;
            }
            put_cp(o, c->cp);
        }
    }
    put_str(o, "\x1b[0m");
}

// Render the whole frame sequence with the cell-grid algorithm; returns the total
// byte count (which may exceed `outcap` — the caller sizes generously and can
// detect truncation by comparing the return value to `outcap`).
size_t tui_cellgrid_render(const TuiCell *frames, int nframes, int cols, int rows,
        char *outbuf, size_t outcap) {
    Out o;
    o.buf = outbuf;
    o.len = 0;
    o.cap = outcap;

    put_str(&o, "\x1b[?7l");

    const TuiCell *prev = 0;
    int f, y, x;
    for (f = 0; f < nframes; f++) {
        const TuiCell *frame = &frames[(size_t)f * cols * rows];
        if (prev == 0) {
            paint_full(&o, frame, cols, rows);
            prev = frame;
            continue;
        }
        for (y = 0; y < rows; y++) {
            x = 0;
            while (x < cols) {
                const TuiCell *c = &frame[y * cols + x];
                const TuiCell *p = &prev[y * cols + x];
                if (cell_eq(c, p)) {
                    x++;
                    continue;
                }
                put_cursor(&o, y + 1, x + 1);
                int first = 1;
                TuiCell cur;
                cur.cp = 0;
                while (x < cols) {
                    c = &frame[y * cols + x];
                    p = &prev[y * cols + x];
                    if (cell_eq(c, p))
                        break;
                    if (c->width == 0) {
                        x++;
                        continue;
                    }
                    if (first || !style_eq(c, &cur)) {
                        put_style(&o, c);
                        cur = *c;
                        first = 0;
                    }
                    put_cp(&o, c->cp);
                    x++;
                }
            }
        }
        prev = frame;
    }
    return o.len;
}

#pragma attribute(pop)
