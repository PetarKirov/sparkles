/// ImportC bindings for notcurses' `ncstrwidth`, scoped to the text-conformance
/// harness. The declaration lives in `sparkles.notcurses.notcurses_c` (compiled
/// from `notcurses_c.c`); the symbol resolves from `libnotcurses-core`.
module sparkles.notcurses;

public import sparkles.notcurses.notcurses_c;
