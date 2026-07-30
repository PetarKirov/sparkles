module sample;
// ---cut---
// NB: `total` is backticked below on purpose — DDoc auto-emphasis wraps the
// parameter name again, so the popup shows a nested code span.
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
