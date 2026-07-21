/**
Theme colors and terminal color-depth folding — re-exported from
`sparkles.base.term_color`.

The color foundation (`Color`, `RgbColor`, `parseHexColor`, the depth fold, and
SGR color emission) lives in `sparkles.base.term_color` so that
`sparkles.base.styled_template` and a future cell-grid backend share one color
type; base cannot depend on syntax, so the types live below and this module
re-exports them. `sparkles.syntax.color.Color` (and friends) therefore still
resolve for every downstream renderer, theme, and app.

See $(REF Color, sparkles,base,term_color) for the four-case color model,
$(REF parseHexColor, sparkles,base,term_color) for bat's `#RRGGBBAA` convention,
and $(REF ansi256FromRgb, sparkles,base,term_color) /
$(REF ansi16FromRgb, sparkles,base,term_color) for the depth fold themes use to
degrade 24-bit authoring to 256- or 16-color terminals.
*/
module sparkles.syntax.color;

public import sparkles.base.term_color :
    Color,
    RgbColor,
    ColorChannel,
    ColorDepth,
    classifyColorDepth,
    detectColorDepth,
    parseHexColor,
    ansi256FromRgb,
    ansi16FromRgb,
    xterm256ToRgb,
    writeSgrColor;
