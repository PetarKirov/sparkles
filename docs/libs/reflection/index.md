# Reflection

`sparkles:reflection` is the dependency-free structural reflection kernel of
the monorepo: one closed type classification and the member/field/property
primitives — the field spine, getter discovery, and the value-like wrapper
rule — that consumers build their own walks from.

Consumers supply semantics; the kernel supplies structure. The property tree,
the text writers, query-path resolution, and serialization front ends
dispatch on the same classification and the same field spine, so "what shape
is this type" has exactly one answer across the repository.

## Documentation

- [Getting started](tutorial/getting-started.md)
- [API reference](reference/api.md)
- [Structure versus policy](explanation/structure-vs-policy.md)
