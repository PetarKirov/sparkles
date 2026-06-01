/**
The shipped version schemes.

This package publicly re-exports every built-in scheme struct. Each scheme is
a hand-written struct conforming to
$(REF isVersion, sparkles,versions,traits) and
$(REF isVersionScheme, sparkles,versions,traits); the per-scheme catalogue
(capabilities, examples, ordering rules, provenance) is in
`docs/specs/versions/PRESETS.md`.

Eleven schemes ship: `SemVer` is the reference; `Dmd`/`DmdCompact`/`Tiny` and
the calendar/`VimVer` schemes are SemVer-shaped compact encodings; `pypi`,
`maven`, and `deb` are structural; `Generic` is the opaque baseline.

See `docs/specs/versions/SPEC.md` §8.
*/
module sparkles.versions.schemes;

public import sparkles.versions.schemes.semver : SemVer;
public import sparkles.versions.schemes.dmd : Dmd;
public import sparkles.versions.schemes.dmd_compact : DmdCompact;
public import sparkles.versions.schemes.tiny : Tiny;
public import sparkles.versions.schemes.calver_yymm : CalVerYYMM;
public import sparkles.versions.schemes.calver_yyyymmdd : CalVerYYYYMMDD;
public import sparkles.versions.schemes.vim : VimVer;
public import sparkles.versions.schemes.pypi : PypiVersion;
public import sparkles.versions.schemes.maven : MavenVersion;
public import sparkles.versions.schemes.deb : DebianVersion;
public import sparkles.versions.schemes.generic : Generic;
