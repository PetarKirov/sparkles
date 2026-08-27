/**
`sparkles:reflection` — dependency-free structural reflection.

The shared reflection kernel of the monorepo: a closed structural
classification ($(MREF sparkles,reflection,kind)), member/field/property
primitives with one-pass CTFE tables ($(MREF sparkles,reflection,member)), and
the DbI type and value visitor shells
($(MREF sparkles,reflection,visit)) whose hooks are all optional.

Consumers supply semantics; the kernel supplies structure. The property tree,
the text writers, query-path resolution, and serialization front ends
dispatch on the same classification and the same field spine, so "what shape
is this type" has exactly one answer. Whether a shape is presented, edited,
serialized, or queried remains each consumer's policy.
*/
module sparkles.reflection;

public import sparkles.reflection.kind;
public import sparkles.reflection.member;
public import sparkles.reflection.visit;
