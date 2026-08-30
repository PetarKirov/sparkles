/**
`sparkles:reflection` — dependency-free structural reflection.

The shared reflection kernel of the monorepo: a closed structural
classification ($(MREF sparkles,reflection,kind)) and member/field/property
primitives ($(MREF sparkles,reflection,member)) — the field spine, public
`@property` getter discovery, the value-like wrapper rule, and CTFE helpers
such as `firstDuplicate`.

Consumers supply semantics; the kernel supplies structure. The property tree,
the text writers, query-path resolution, and serialization front ends
dispatch on the same classification and the same field spine, so "what shape
is this type" has exactly one answer. Whether a shape is presented, edited,
serialized, or queried remains each consumer's policy.
*/
module sparkles.reflection;

public import sparkles.reflection.kind;
public import sparkles.reflection.member;
