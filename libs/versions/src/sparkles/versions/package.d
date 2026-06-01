/**
`sparkles:versions` — an ecosystem-aware version library.

Parses, compares, and constrains the version strings of many package
ecosystems. Each ecosystem is a hand-written struct (`SemVer`,
`PypiVersion`, `DebianVersion`, …) conforming to the compile-time concepts
$(REF isVersion, sparkles,versions,traits) and
$(REF isVersionScheme, sparkles,versions,traits); generic algorithms
(`Ranges!V`, the optional-capability fast paths) operate over any conforming
type.

This package module publicly re-exports the concepts and capability
vocabulary, the parse types, the generic `Ranges!V` type, and every shipped
scheme. A consumer who needs a single ecosystem can instead import just that
scheme module (e.g. `sparkles.versions.schemes.semver`).

See `docs/specs/versions/SPEC.md` for the full specification.
*/
module sparkles.versions;

public import sparkles.versions.traits;
public import sparkles.versions.parsing;
public import sparkles.versions.ranges;
public import sparkles.versions.schemes;

version (unittest)
    public import sparkles.versions.testing;
