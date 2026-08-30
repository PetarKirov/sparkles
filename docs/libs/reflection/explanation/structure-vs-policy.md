# Structure versus policy

The kernel answers exactly one question — **what shape is this type?** — and
enumerates the members a shape has. Everything else is the consumer's policy,
and the boundary is deliberate:

| The kernel owns                                                              | The consumer owns                                            |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------ |
| Type classification                                                          | Whether a shape is presented, edited, serialized, or queried |
| Field and property discovery                                                 | Visibility, editing, and mutation rules                      |
| The field spine and getter discovery                                         | Which alternative naming a wire format uses                  |
| The value-like wrapper rule                                                  | Error and result models                                      |
| Const-readability of getters                                                 | Depth and size budgets, traversal order, cycle policy        |
| Neutral `@Name`/`@Aliases`/`@Description` metadata (via `sparkles:metadata`) | Domain-specific attributes and their enforcement             |

## Why the consumer owns the walk

The first sketch of the query-language integration put a policy type on the
**queried** side: event libraries implemented projection hooks so a query
engine could derive paths. That inverted the dependency — window-system
types named the query engine's concepts — so the next sketch centralized a
DbI visitor shell in the kernel instead. That fixed the dependency
direction but not the shape mismatch: the property tree's walk is
value-carrying and disclosure-pruned, a schema's walk is a compile-time
enumeration of every alternative, and a writer never recurses at all. One
shell serving all three meant a hook probe for every capability at every
visited type, and measurement showed the probes and per-descent-path
instantiations dominating the cost of the only consumer the shell had.

So the kernel ships primitives, not a traversal: each consumer writes a
direct `static if` ladder over `typeKindOf`, recursing through the field
spine and getter discovery. The queried types still stay plain data — a
domain library that wants computed values exposed uses the language
capability (`@property`); one that wants a canonical token carries neutral
metadata. Neither learns anything about the consumer.

## Value-like wrappers

A fieldless type whose single public `@property` returns a scalar —
`ScaleFactor` — is, for structural purposes, that value; a fieldless type
that slices to UTF-8 text through a `const` `opSlice()` — base's
`InlineBuffer!(char, N)` — is, for structural purposes, that text.
`valueLikeGetter` and `isTextSliceLike` state the two rules once; the query
schema presents such types as leaves at their own address and the resolver
hands the property's result (or the slice) to the sink. Both rules are
derived from language capabilities, so the wrapper author opts in by writing
idiomatic D, not by annotating for a consumer.

## The one dispatch body

The text writers show the smallest integration: plain and styled output were
two ladders that had already drifted (one accepted string-like narrow
slices, the other did not). Both now call one dispatch body classified by
`typeKindOf`, differing only in a presentation hook. When a type's leaf-ness
or scalar-ness is in question there is exactly one place to look.
