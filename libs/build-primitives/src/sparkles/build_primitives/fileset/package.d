/**
Filesets: values that name sets of files, and their resolution against a
file system.

Specified in `docs/specs/build-primitives/filesets/SPEC.md`; delivered in the
milestones of its `PLAN.md`.
*/
module sparkles.build_primitives.fileset;

public import sparkles.build_primitives.fileset.driver;
public import sparkles.build_primitives.fileset.driver_loop;
public import sparkles.build_primitives.fileset.machine;
public import sparkles.build_primitives.fileset.pattern;
public import sparkles.build_primitives.fileset.plan;
public import sparkles.build_primitives.fileset.tree_literal;
public import sparkles.build_primitives.fileset.value;
