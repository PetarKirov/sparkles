/**
Semantic Versioning parser and comparator.

This package provides $(LREF SemVer), a value type for parsing, formatting,
and comparing Semantic Versioning 2.0.0 versions.

Standards: $(LINK2 https://semver.org/, Semantic Versioning 2.0.0)
*/
module sparkles.semver;

public import sparkles.semver.core :
    SemVer,
    SemVerException,
    SemVerParseError,
    SemVerParseErrorCode,
    SemVerParseMode,
    SemVerParseResult;
