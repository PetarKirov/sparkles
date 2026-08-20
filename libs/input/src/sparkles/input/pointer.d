/**
Pointer-shape vocabulary at the input/host boundary.

The enum itself remains in `sparkles:base`: `sparkles:input` already depends on
base, while moving the definition upward and re-exporting it from base would
create a dependency cycle. This module gives input and WSI consumers the
semantic import path while preserving every existing terminal-control import.
*/
module sparkles.input.pointer;

public import sparkles.base.term_control : PointerShape;
