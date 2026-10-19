---
status: draft
owner: sparkles:shaders
reviewed: 2026-10-19
---

# `sparkles:shaders` — The build step and build integration

How a package's device modules become shaders during its build. `SHP1`–`SHP10`
and `SHB1`–`SHB7` are the accepted contract of 2026-10-16, revised for one
compilation per [profile](./profiles.md): `SHP1`, `SHP3`–`SHP8` and `SHP10`
change, the rest stand. This page is part of the [specification](./SPEC.md).

## The build step

The build step, `shader-compile`, turns a package's device modules into
shaders, one set of files per [profile](./profiles.md). It takes the package's
directory, an output directory, and the name of the device configuration
(`--config`, `shaders` by default), and it learns everything else from the
package's build recipe and from the compiler's manifest of the unit
([`SHC5`](./profiles.md)). The configuration is chosen by that name and must
then be a device build (`SHP1`). `--ldc` names the compiler (`SHP9`),
`--if-stale` asks for the freshness check (`SHB2`), and `--keep` and
`--quiet` change only what it prints and leaves behind.

**SHP1: Device configuration.** _(Revised.)_ A package declares its device compilation
once, as a [device configuration](../../glossary.md#device-configuration): a [dub](https://dub.pm/) configuration whose `dflags` contain
`-mdcompute-targets=<target>`, where the target is exactly one of
`vulkan-100`, `vulkan-110`, `vulkan-120`, `vulkan-130` and `vulkan-140`;
`shaders` is the conventional name. The build
step **must** use that configuration's import paths, version identifiers and
flags as `dub describe` reports them, and **must** treat a configuration
without the flag as a configuration error. The target names the compiler's
code generator, which every profile uses, and not the SPIR-V version: the
pinned code generator emits SPIR-V 1.6 for every Vulkan target. The profiles
come from the unit itself (`SHC4`).

**SHP2: Host flags excluded.** The build step **must** describe the device
configuration with the `DFLAGS` environment variable removed.

_Rationale:_ dub folds `$DFLAGS` into the flags it reports, and a host build
sets it for its own compiler. A test harness's `--threads=N` or a sanitizer's
`-fsanitize=address` is meaningless to the device compiler, or fatal to it.

**SHP3: The unit.** _(Revised.)_ The [shader unit](../../glossary.md#shader-unit)
**must** be every module, among the source files of the package and all its
dependencies, that `SHM5` classifies as a device module. It **must** contain
at least one device-only module, and the build step **must** compile all of
it in a single compiler invocation per profile ([`SHC6`](./profiles.md)).

_Rationale:_ A SPIR-V module is self-contained; there is no linker to find a
function in another one. A device module in a dependency, such as this
library's own vocabulary, therefore belongs to the unit as much as the
package's own.

**SHP4: Validation.** _(Revised.)_ The SPIR-V compiled for a profile **must**
pass `spirv-val` under that profile's environment before anything else reads
it: Vulkan 1.3's rules for `vulkan1.3`, the universal SPIR-V 1.6 rules for
`gl330` and `gles100`. It is then optimised with `spirv-opt -O`, and the
optimised module and every module written from it **must** pass the
capability audit ([`SHC9`](./profiles.md)).

_Rationale:_ Each output is validated against the rules of what consumes it:
Vulkan's rules reject the loose uniforms OpenGL needs, so the GL profiles
cannot be held to them, and the Vulkan profile, which has none, must be.

**SHP5: Translation.** _(Revised.)_ For each entry point of the optimised
module of a profile, the build step **must** write the files `SHC2` gives
that profile and the entry point's stage: for `gl330` and `gles100`, the
entry point translated to GLSL 3.30 and GLSL ES 1.00, in which the combined
image-sampler the translation introduces carries the name of the `Sampler2D`
parameter it came from; for `vulkan1.3`, a SPIR-V module holding that entry
point alone. Unused interface variables are removed.

_Rationale:_ A consumer binds textures by name, and the name it knows is the
one written in D. A Vulkan consumer creates one shader module per stage, and
one entry point per module keeps each free of the others' interface.

**SHP6: Output validation.** _(Revised.)_ Every generated GLSL file **must**
pass the reference GLSL validator, `glslangValidator`, and every generated
SPIR-V file `spirv-val` under its profile's environment, before it is written
to the output directory.

**SHP7: Provenance.** _(Revised.)_ Every generated GLSL file **must** begin with a comment that
names the package as its recipe names it, every device-only module of the
unit relative to the package directory, and the entry point, and that states
the file is generated; a generated SPIR-V file **must** carry the same text in
an `OpModuleProcessed` instruction. The generated files' bytes **must not** depend on the
directory the step runs from (the stamp's paths may).

**SHP8: Atomic output.** _(Revised.)_ Nothing **must** be written to the
output directory until every profile of the unit has compiled, validated,
passed the audit and been translated; a failure in any profile leaves the
directory as it was. Each output file and the stamp **must** then be written
through a temporary file and a rename, the stamp last. Every `*.frag`, `*.vert`
and `*.spv` file in
the output directory that no entry point produces **must** be removed, and so
must a temporary whose writer is no longer running: the directory belongs to
the build step. A temporary is named `<file>.tmp-<pid>`, and its writer is
judged running by its process id: concurrent runs are assumed to share one
host and process-id namespace, and a writer outside it looks gone. A file
that only resembles a temporary, or whose writer cannot be judged, stays.
Other files there, such as a `.gitignore`, are left alone.

_Rationale:_ Several builds that depend on the same package may run the step
at once. A reader then sees an old file or a new one, never half of one, and
never a stamp that vouches for output not yet written.

**SHP9: Compiler.** The device compiler **must** be the executable named by
`--ldc`, or else `ldc2-vulkan` on `PATH`. No environment variable selects it.

**SHP10: Outcomes.** _(Revised.)_ The build step **must** exit 0 on success or when the
output is fresh (`SHB2`), 1 when compilation, validation or translation
fails, 2 for a usage or configuration error, and 3 when the toolchain cannot
do the work. It **must** decide them in this order, reporting the first that
applies:

1. the arguments are malformed: 2;
2. with `--if-stale`, the output is fresh: 0;
3. the device compiler, dub, or a SPIR-V or GLSL tool cannot be run: 3;
4. the device configuration cannot be described, describes no build target
   (it has no sources, or a target type that builds nothing), names no
   dcompute target, names anything but exactly one of the Vulkan targets of
   `SHP1`, or yields no device-only module: 2;
5. the manifest cannot be produced: 1 if the compiler reports the unit's
   error, 3 if it cannot produce a manifest for a minimal `@fragment` shader
   either;
6. the manifest names a profile the table does not define, or lists no entry
   point: 2 (`SHC3`, `SHC5`);
7. the profiles are then processed one at a time, in the table's order, each
   compiled, validated, audited (`SHC9`) and translated before the next
   begins, and the first failure decides the outcome: a failure to compile
   is 3 if the device compiler cannot compile a minimal `@fragment` shader
   for that target either, and 1 otherwise; any other failure is 1. Either
   names the profile.

Every non-zero exit **must** print the cause; exit 3 **must** say how to
obtain the toolchain.

_Rationale:_ Describing the configuration runs the compiler, so a missing
compiler comes before every configuration error. Whether a compiler has the
fragment stage is decided by what it can compile, not by matching its
messages about the unit, which name neither cause reliably; the minimal
shader is tried only once the unit has failed, so a successful run pays
nothing for it.

## Build integration

A consumer runs the build step inside its own build, as a step dub performs
before compiling. The freshness stamp is what makes that cheap. It is a
shortcut for the edit loop, not a build system: it records what a developer
edits (the unit's modules and their recipes), not the compiler, the SPIR-V
and GLSL tools, or a module the unit imports without containing it. Output
that ships, or that a build machine caches, comes from a Nix derivation whose
inputs are all of those, placed with a `prebuilt` stamp (`SHB3`, `D14`).

**SHB1: The stamp.** After a successful run the output directory **must**
contain `.stamp`. Its first line names the stamp format version; then one
line per input with its SHA-256 and its path relative to the package
directory; then one line per output file. The inputs are the unit's modules
and the build recipe of each package that contributes one, and each hash is
taken as soon as the configuration is described, before the compiler reads
the file, so a file edited while the step runs leaves the stamp stale.

**SHB2: Freshness.** With `--if-stale`, the build step **must** exit 0
without running dub or the device compiler when the stamp's format version is
the current one, every recorded input exists with its recorded hash, and
every recorded output exists, and it records at least one input and one
output. A stamp with any other line, or a malformed one, is stale, except
the prebuilt stamp of `SHB3`. Lines of each kind may come in any order.
Otherwise it **must** regenerate.

**SHB3: Prebuilt output.** With `--if-stale`, a stamp whose only line is
`prebuilt`, trailing blank lines aside, **must** be treated as fresh. Without
`--if-stale` the step always regenerates.

_Rationale:_ A packager that builds the output once, elsewhere, can hand it
to every build without the device compiler. Builds that place it trust the
packager, not the stamp.

**SHB4: Unit membership.** Freshness **must** fail when a device module
enters or leaves the unit, even if no recorded input changed. To decide it
without dub or the compiler, the stamp **must** record a deterministic
digest of the device modules among the files the unit can be drawn from (the
source directories of the device configuration and of every dependency):
each one's relative path and `SHM5` mode, not its contents, and nothing about
the other files. The candidates are a
[fileset](../build-primitives/filesets/SPEC.md) resolution, and the digest
**must** depend only on those paths and modes, never on timestamps,
enumeration order, the host or the checkout's location.

_Rationale:_ A list of the files a unit was built from cannot notice a file
that was not on it. A digest of every file that could belong to the unit
does. Membership changes only when a device module appears, disappears or
changes mode, so a digest of contents, or of every file's path, would
regenerate the GLSL, and require the device compiler, on unrelated edits to
any dependency; the unit's own modules are already inputs (`SHB1`).

**SHB5: Opt-in configuration.** A package whose code uses generated shaders
**must** provide them in a dub configuration of its own, separate from its
default one. That configuration runs the build step with `--if-stale` as a
pre-generate command, adds the output directory to its string-import paths,
and defines a version identifier by which its code selects the shader-using
declarations. The default configuration **must** build with no device
compiler on the machine.

**SHB6: Selection beside the dependency.** The opt-in configuration **must**
be selected beside every dependency through which it is reached: each package
whose configuration adds such a dependency selects it in that configuration,
next to the `dependency` directive, and not in its top-level settings. An
application, which nothing depends on, **may** select it at top level. The
code that needs the generated shaders **should** fail to compile, with a
message naming the configuration, when it is built without it.

_Rationale:_ dub applies a dependency's top-level `subConfiguration`, and one
inside its library configuration, even when the dependency is reachable only
through a parent configuration that the build does not select. An opt-in
selected there leaks into builds that never asked for a GPU. The package that
needs the opt-in may itself be reachable only that way, as a backend is, so
the selection belongs to each package that adds the edge; an application's
top level leaks into nothing.

**SHB7: Concurrent builds.** Dependents building in parallel **must not**
race on the build of the step itself or on its output. The pre-generate
command builds and runs the step with `dub run --temp-build`, which builds in
a temporary directory rather than into the step's package, and the step's own
writes are atomic (`SHP8`).
