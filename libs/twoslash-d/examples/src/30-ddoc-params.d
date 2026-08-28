module sample;
// ---cut---
// NB: `total` is backticked below on purpose. DDoc pairs backticks left to
// right and auto-emphasizes the parameter name on top, so the row arrives as
// three abutting code runs — the case `collapseCodeSpans` merges into one.
/++
Renders a progress meter.

Params:
    value = the current position; values outside `[0, `total`]` are
            silently clamped rather than rejected
    total = the end of the range; must be positive
    width = the meter's width in cells
Returns: The rendered bar, exactly width characters wide.
+/
string meter(double value, double total, size_t width)
//     ^?
    => value >= total ? "full" : "partial";
//     ^?
