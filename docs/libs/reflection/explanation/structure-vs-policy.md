# Structure versus policy

The kernel answers exactly one question — $(B what shape is this type?) — and
enumerates the members a shape has. Everything else is the consumer's policy,
and the boundary is deliberate:

| The kernel owns                                                              | The consumer owns                                            |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------ |
| Type classification                                                          | Whether a shape is presented, edited, serialized, or queried |
| Field and property discovery                                                 | Visibility, editing, and mutation rules                      |
| `SumType` alternatives                                                       | Which alternative naming a wire format uses                  |
| Pointer and collection descent                                               | Error and result models                                      |
| Recursion detection                                                          | Depth and size budgets                                       |
| Neutral `@Name`/`@Aliases`/`@Description` metadata (via `sparkles:metadata`) | Domain-specific attributes and their enforcement             |

## Why the hooks live on the visitor

The first sketch of the query-language integration put a policy type on the
$(B queried) side: event libraries implemented projection hooks so a query
engine could derive paths. That inverted the dependency — window-system
types named the query engine's concepts. The visitor reverses it: the
queried types stay plain data, and the consumer's visitor decides what the
walk observes. A domain library that wants computed values exposed uses the
language capability (`@property`); one that wants a canonical token carries
neutral metadata. Neither learns anything about the consumer.

## Value-like wrappers

A fieldless type whose single public `@property` returns a scalar —
`InlineUtf8`, `ScaleFactor` — is, for structural purposes, that value.
`valueLikeGetter` states the rule once; the query schema presents such types
as leaves at their own address and the resolver hands the property's result
to the sink. The rule is derived from language capabilities, so the wrapper
author opts in by writing idiomatic D, not by annotating for a consumer.

## The one dispatch body

The text writers show the smallest integration: plain and styled output were
two ladders that had already drifted (one accepted string-like narrow
slices, the other did not). Both now call one dispatch body classified by
`typeKindOf`, differing only in a presentation hook. When a type's leaf-ness
or scalar-ness is in question there is exactly one place to look.
