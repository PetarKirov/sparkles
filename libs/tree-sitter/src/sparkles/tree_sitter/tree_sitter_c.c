// ImportC shim for the tree-sitter C runtime. The include path comes from
// pkg-config (`libs "tree-sitter"` in dub.sdl → -P-I…); see
// docs/guidelines/importc-c-libraries.md.
//
// The unique file stem (`tree_sitter_c`, never `c.c`) avoids the ImportC
// module-name collision with other in-repo shims linked into one binary.
//
// tree-sitter's runtime is stateful — `pure` is deliberately omitted.
#pragma attribute(push, nogc, nothrow)
#include <tree_sitter/api.h>
#pragma attribute(pop)
