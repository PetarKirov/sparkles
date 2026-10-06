/**
The capability VFS: a file-system interface over directory handles.

A program is given open directory handles instead of path strings and names
every file relative to one of them, so code holding a handle cannot reach
anything outside that directory, even while another process renames entries
or plants symbolic links inside it. Each handle carries rights checked at
compile time, which can be narrowed but never widened.

Specified in `docs/specs/base/vfs/SPEC.md`.
*/
module sparkles.base.vfs;

public import sparkles.base.io.errors;
public import sparkles.base.vfs.concept;
public import sparkles.base.vfs.handles;
public import sparkles.base.vfs.mem;
public import sparkles.base.vfs.types;
