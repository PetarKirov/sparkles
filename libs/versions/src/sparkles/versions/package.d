/**
Design-by-Introspection versioning library.

This package provides $(LREF Version), a generic engine for SemVer 2.0.0
and other versioning schemes (DMD, CalVer, …), plus pre-built layouts
and a parser.

See `docs/specs/versions/SPEC.md` for the full specification.
*/
module sparkles.versions;

public import sparkles.versions.engine :
    Component,
    ComponentDesc,
    GetCoreType,
    InternalFlag,
    InternalFlagDesc,
    LayoutDescriptor,
    SlotComparator,
    SlotValidator,
    StringSlot,
    Version,
    layoutBody;

public import sparkles.versions.semver_rules :
    semVerBuildSlot,
    semVerPrereleaseSlot;

public import sparkles.versions.layouts :
    DmdLayout,
    DmdOptimized,
    DmdVer,
    SemVer,
    SemVerLayout,
    TinyLayout,
    TinyVer;

public import sparkles.versions.parser :
    parse,
    ParseError,
    ParseErrorCode,
    ParseMode,
    ParseResult;

public import sparkles.versions.presets :
    CalVerYYMM,
    CalVerYYMMLayout,
    CalVerYYYYMMDD,
    CalVerYYYYMMDDLayout,
    VimLayout,
    VimVer;
