/**
Variants: the ways each package is compiled, keyed so that two requests that
compile a package the same way share it (build-graph SPEC BGV1–BGV3).

$(LREF planVariants) takes resolutions and gives each binary target a
$(LREF Variant). A variant's key holds what changes its object code: the
package, its configuration and role, its build options and flags, its
versions and debug versions, the inheritance mode, the toolchain and the
platform. Versions a dependent passed down are **pruned**: one is kept only
if a file under the variant's source, import or string import roots
mentions it, since an identifier nothing the compile reads tests cannot
change what it emits. So a test root's configuration-local version no longer
forks its whole dependency closure, and the dependency libraries of many
test roots dedupe into one.

Planning reads the files through the resolution's tree, so each read joins
the read set (BGP1). Two lints come with the scan and fail the plan: an
`isVersion` use whose argument is not a predefined version identifier
(BGV1), and, in the divergent mode, a dependency that tests a version its
dependent withholds from it (D13).
*/
module sparkles.build_graph.variants;

import std.algorithm.iteration : filter, map;
import std.algorithm.searching : canFind, startsWith;
import std.algorithm.sorting : sort;
import std.array : array, join;
import std.conv : text;

import sparkles.build_primitives.resolve.configure : Resolution, ResolvedTarget, VersionInheritance;
import sparkles.build_primitives.resolve.platform : BuildPlatform;
import sparkles.build_primitives.resolve.libraries : PkgConfigDriver;
import sparkles.build_primitives.resolve.settings : BuildSettings, TargetType, optionNames, requirementNames;
import sparkles.build_primitives.resolve.tree : ResolveTree;
import sparkles.build_primitives.task.model : PlanExpected, planErr, planOk;
import sparkles.d_source.mentions : Mention, ScannedSource, StringConditionKind, isPredefinedVersion,
    isVersionUses, scanSource, scanText;

/// A variant's role (BGV2).
enum Role : ubyte
{
    /// The package's own sources compiled with `-unittest` into its test
    /// binary.
    testRoot,
    /// What a dependent links against: the library configuration, without
    /// `-unittest`.
    dependencyLibrary,
    /// A root compiled for shipping.
    application,
}

/**
The toolchain a variant is compiled with (§8). Planning takes it as given:
`identity` is the digest §8 specifies, `vendor` the compiler's vendor
(`ldc`, `dmd`), which a task id carries in its place (OBD2).
*/
struct ToolchainIdentity
{
    string vendor;   ///
    string identity; ///
}

/// One way of compiling one package.
struct Variant
{
    string package_;      /// the package
    string configuration; /// the configuration it builds in
    Role role;            ///
    string directory;     /// the package directory
    /// The packages compiled into it: itself, then the source libraries it
    /// folds in (BGV3: a source library has no variant of its own).
    string[] packages;
    /// The resolved settings, with versions and debug versions pruned.
    BuildSettings settings;
    /// The inherited versions and debug versions kept, because a scanned
    /// file mentions them or because nothing can be pruned (see `keptAll`).
    string[] keptVersions;
    string[] keptDebugVersions; /// ditto
    /// The inherited ones dropped.
    string[] prunedVersions;
    string[] prunedDebugVersions; /// ditto
    /// Why every inherited identifier is kept, if one is: a string-built
    /// condition or a generated root. Null when pruning applied.
    string keptAll;
    VersionInheritance inheritance; ///
    ToolchainIdentity toolchain;    ///
    BuildPlatform platform;         ///
    /// The `.pc` files its `libs` resolved through (BGR5).
    string[] pcFiles;
    /// The SHA-256 of $(LREF Variant.keyText).
    ubyte[32] key;

    /// The canonical text the key digests, one field per line.
    string keyText() const @safe
    {
        string[] versions = settings.versions.dup.sort.release;
        string[] debugVersions = settings.debugVersions.dup.sort.release;
        return [
            "package=" ~ package_,
            "configuration=" ~ configuration,
            text("role=", role),
            "targetType=" ~ text(settings.targetType),
            "options=" ~ optionNames(settings.options).join(","),
            "requirements=" ~ requirementNames(settings.requirements).join(","),
            // Flag order is meaningful to the compiler, so it is kept.
            "dflags=" ~ settings.dflags.join("\x1f"),
            "versions=" ~ versions.join(","),
            "debugVersions=" ~ debugVersions.join(","),
            text("inheritance=", inheritance),
            "toolchain=" ~ toolchain.vendor ~ ":" ~ toolchain.identity,
            "platform=" ~ platformText(platform),
        ].join("\n") ~ "\n";
    }

    /// The key as lowercase hexadecimal.
    string keyHex() const @safe pure nothrow => hex(key);
}

/// A string-built condition planning found (D34): it keeps every inherited
/// identifier of the variants that scan its file.
struct ConditionReport
{
    string file; ///
    uint line;   ///
    StringConditionKind kind; ///
    /// Inside a `unittest` block: reported, and it keeps nothing.
    bool insideUnittest;
}

/// What planning resolved the requests' variants to.
struct VariantPlan
{
    /// Every distinct variant, in the order first met.
    Variant[] variants;
    /// For each request, the variant of each of its resolution's targets,
    /// in the targets' order.
    size_t[][] requests;
    /// Every string-built condition in a scanned file, sorted.
    ConditionReport[] conditions;
    /// Every layout finding, sorted; those in registry packages are all
    /// that a plan that succeeded can hold.
    LayoutFinding[] layout;
}

/// Why planning failed: a lint's finding, at a place in a file.
struct PlanError
{
    string message; ///
    string file;    /// empty when no one place is at fault
    uint line;      ///

    void toString(W)(ref W w) const
    {
        import std.range.primitives : put;

        if (file.length)
            put(w, text(file, ":", line, ": "));
        put(w, message);
    }
}

/// What planning takes besides the resolutions.
/// One finding of the layout lint (BGV5).
struct LayoutFinding
{
    string package_; /// the package whose library compiles the file
    string file;     ///
    uint line;       ///
    string what;     /// what the `version (unittest)` changes, as a phrase
    /// Whether the package comes from the registry: reported, and it does
    /// not fail the plan, since this repository cannot fix it.
    bool registry;
}

/**
The layout lint, as planning calls it: `sparkles:unittest-layout`'s
`checkLayout`, which parses with DMD's frontend, so it reaches planning as a
callback and this package links no frontend (D56).

Params:
    path = the file's path, for its findings
    source = its text
    dependedOn = whether the library configuration depends on a module's
        package, by the module's dotted name
    versionSet = whether the variant sets a version identifier
    finding = called with each finding's line and what it changes

Returns: whether the file parsed.
*/
alias LayoutCheck = bool delegate(string path, const(char)[] source,
    scope bool delegate(const(char)[] module_) @safe dependedOn,
    scope bool delegate(const(char)[] identifier) @safe versionSet,
    scope void delegate(uint line, string what) @safe finding) @safe;

/// What planning takes besides the resolutions.
struct PlanOptions
{
    ToolchainIdentity toolchain; ///
    /// The layout lint (BGV5); null plans without it.
    LayoutCheck layoutCheck;
    /// The root names of the registry packages, whose findings are
    /// reported without failing the plan.
    const(string)[] registry;
    /// Resolves each target's `libs` (BGR5); null leaves them as resolved.
    /// Planning's own goes through a `RecordingPkgConfig`, so the read set
    /// holds its queries (BGP1).
    PkgConfigDriver pkgConfig;
}

/**
Gives each target of each resolution its variant, deduplicated across all of
them.

Params:
    resolutions = one per request, each read through `tree`
    options = the toolchain
    tree = the tree the resolutions read; the scans read through it, so its
        read set covers them

Returns: the plan, or the first lint finding, by file and line.
*/
PlanExpected!(VariantPlan, PlanError) planVariants(const Resolution[] resolutions,
    PlanOptions options, ResolveTree tree) @safe
{
    auto scans = SourceScans(tree);
    // BGF3: a link the resolutions met that leaves its root.
    if (auto e = treeFault(tree))
        return planErr!VariantPlan(*e);
    VariantPlan plan;
    size_t[string] byKey;

    foreach (ref r; resolutions)
    {
        size_t[] indices;
        foreach (i, ref t; r.targets)
        {
            auto v = variantOf(r, t, i == 0, options, options.pkgConfig, scans);
            if (v.hasError)
                return planErr!VariantPlan(v.error);
            auto variant = v.value;
            const hexKey = variant.keyHex;
            if (auto existing = hexKey in byKey)
                indices ~= *existing;
            else
            {
                byKey[hexKey] = plan.variants.length;
                indices ~= plan.variants.length;
                plan.variants ~= variant;
            }
        }
        plan.requests ~= indices;

        if (r.inheritance == VersionInheritance.divergent)
            if (auto e = divergentLint(r, scans))
                return planErr!VariantPlan(PlanError(e.message, e.file, e.line));
    }

    if (auto e = treeFault(tree))
        return planErr!VariantPlan(*e);
    if (auto e = scans.firstLintError)
        return planErr!VariantPlan(*e);
    if (options.layoutCheck !is null)
    {
        plan.layout = layoutFindings(plan, options, scans);
        if (auto e = layoutError(plan.layout))
            return planErr!VariantPlan(PlanError(e.message, e.file, e.line));
    }
    plan.conditions = scans.conditionReports
        .sort!((a, b) => a.file != b.file ? a.file < b.file : a.line < b.line).release;
    return planOk!PlanError(plan);
}

private:

// The first lookup the tree refused (BGF3), as a planning error naming the
// link or path.
PlanError* treeFault(ResolveTree tree) @safe
{
    const faults = tree.faults;
    if (faults.length == 0)
        return null;
    const f = faults[0];
    return new PlanError(f.target.length ? text(f.reason, ": `", f.path, " -> ", f.target, "`")
        : text(f.reason, ": `", f.path, "`"), f.path);
}

// The layout lint over every dependency library's own files (BGV5), once per
// file and set of versions: the lint skips the imports of branches a variant
// does not compile.
LayoutFinding[] layoutFindings(ref const VariantPlan plan, const PlanOptions options, ref SourceScans scans) @safe
{
    bool[string] done;
    LayoutFinding[] found;
    foreach (ref v; plan.variants)
    {
        if (v.role != Role.dependencyLibrary)
            continue;
        const versions = v.settings.versions.dup.sort.release;
        const registry = options.registry.canFind(rootName(v.package_));
        foreach (file; v.settings.sourceFiles)
        {
            import std.algorithm.searching : endsWith;

            const key = file ~ "\0" ~ versions.join(",");
            if (!file.endsWith(".d") || key in done)
                continue;
            done[key] = true;
            string text_;
            if (!scans.tree.readText(file, text_))
                continue;
            const importPaths = v.settings.importPaths;
            bool dependedOn(const(char)[] module_) @safe
                => isToolchainModule(module_) || scans.moduleFile(module_.idup, importPaths).length > 0;
            bool versionSet(const(char)[] id) @safe => versions.canFind(id);
            const pkg = v.package_;
            const parsed = options.layoutCheck(file, text_, &dependedOn, &versionSet,
                (uint line, string what) @safe { found ~= LayoutFinding(pkg, file, line, what, registry); });
            if (!parsed)
                found ~= LayoutFinding(pkg, file, 0, "a module the layout lint could not parse", registry);
        }
    }
    // One finding per place, whichever variants met it.
    found.sort!((a, b) => a.file != b.file ? a.file < b.file : a.line != b.line ? a.line < b.line : a.what < b.what);
    LayoutFinding[] unique;
    foreach (f; found)
        if (!unique.length || unique[$ - 1].file != f.file || unique[$ - 1].line != f.line || unique[$ - 1].what != f.what)
            unique ~= f;
    return unique;
}

// The plan fails on the in-tree findings, all of them in one message.
const(PlanError)* layoutError(const LayoutFinding[] findings) @safe
{
    string message;
    const(LayoutFinding)* first;
    foreach (ref f; findings)
        if (!f.registry)
        {
            if (first is null)
                first = &f;
            message ~= text("\n  ", f.file, ":", f.line, ": ", f.what);
        }
    if (first is null)
        return null;
    return new PlanError("`version (unittest)` changes what a dependent sees (BGV4):" ~ message,
        first.file, first.line);
}

// Modules of the toolchain's own import directories, which no recipe names.
bool isToolchainModule(scope const(char)[] m) @safe pure nothrow @nogc
    => m == "object" || m.startsWith("std.") || m.startsWith("core.") || m.startsWith("etc.")
        || m.startsWith("ldc.") || m.startsWith("gcc.");

string rootName(string package_) @safe pure nothrow @nogc
{
    foreach (i, c; package_)
        if (c == ':')
            return package_[0 .. i];
    return package_;
}

PlanExpected!(Variant, PlanError) variantOf(ref const Resolution r, ref const ResolvedTarget t, bool isRoot,
    const PlanOptions options, PkgConfigDriver pkgConfig, ref SourceScans scans) @safe
{
    import sparkles.build_primitives.resolve.libraries : resolveLibraries;

    Variant v;
    v.package_ = t.package_;
    v.configuration = t.configuration;
    v.directory = t.directory;
    v.packages = t.packages.dup;
    v.settings = t.settings.dup;
    if (pkgConfig !is null)
        v.pcFiles = resolveLibraries(v.settings, r.platform, pkgConfig).pcFiles;
    v.inheritance = r.inheritance;
    v.toolchain = options.toolchain;
    v.platform = r.platform.dup;
    v.role = !isRoot ? Role.dependencyLibrary
        : r.testRoot.configuration.length ? Role.testRoot
        : t.settings.targetType == TargetType.executable ? Role.application
        : Role.dependencyLibrary;

    if (t.inheritedVersions.length || t.inheritedDebugVersions.length)
    {
        const facts = scans.factsOf(t.settings);
        if (facts.keepAll.length)
        {
            v.keptAll = facts.keepAll;
            v.keptVersions = t.inheritedVersions.dup;
            v.keptDebugVersions = t.inheritedDebugVersions.dup;
        }
        else
        {
            foreach (id; t.inheritedVersions)
                (facts.versions.canFind(id) ? v.keptVersions : v.prunedVersions) ~= id;
            foreach (id; t.inheritedDebugVersions)
                (facts.debugVersions.canFind(id) ? v.keptDebugVersions : v.prunedDebugVersions) ~= id;
        }
        v.settings.versions = v.settings.versions.filter!(id => !v.prunedVersions.canFind(id)).array;
        v.settings.debugVersions = v.settings.debugVersions
            .filter!(id => !v.prunedDebugVersions.canFind(id)).array;
    }
    else
        // Even with nothing to prune, the lints read every variant's files.
        cast(void) scans.factsOf(t.settings);

    import std.digest.sha : sha256Of;

    v.key = sha256Of(v.keyText);
    return planOk!PlanError(v);
}

// D13's divergent-mode lint: in the divergent mode a dependent's
// configuration-level versions do not pass down, so a dependency whose
// files test one of them silently builds without it.
const(PlanError)* divergentLint(ref const Resolution r, ref SourceScans scans) @safe
{
    foreach (ref parent; r.targets)
    {
        if (parent.withheldVersions.length == 0 && parent.withheldDebugVersions.length == 0)
            continue;
        foreach (name; parent.dependencies)
        {
            auto child = r.target(name);
            if (child is null)
                continue;
            foreach (ref m; scans.ownMentionsOf(*child))
            {
                const withheld = m.mention.debug_ ? parent.withheldDebugVersions : parent.withheldVersions;
                if (withheld.canFind(m.mention.identifier))
                    return new PlanError(text("`", child.package_, "` tests ",
                        m.mention.debug_ ? "debug version" : "version", " `", m.mention.identifier,
                        "`, which its dependent `", parent.package_,
                        "` sets in its configuration and the divergent mode withholds (D13)"),
                        m.file, m.mention.line);
            }
        }
    }
    return null;
}

struct Facts
{
    const(string)[] versions;      // every mentioned version identifier
    const(string)[] debugVersions; // and debug identifier
    string keepAll;                // why nothing may be pruned, or null
}

struct LocatedMention
{
    string file;
    Mention mention;
}

// The scans of every file planning reads, each read once.
struct SourceScans
{
    ResolveTree tree;
    ScannedSource*[string] sources; // D files, by path
    Mention[][string] texts;        // string-import files, by path
    string[][string] listings;      // by root and patterns
    bool[string] reexporting;       // module name → re-exports isVersion
    string[string][string] moduleIndex; // root → module name → file
    bool[string] linted;            // D files whose isVersion uses were checked
    ConditionReport[] conditionReports;
    PlanError* firstLintError;

    this(ResolveTree tree) @safe
    {
        this.tree = tree;
    }

    string[] list(string root, string[] names) @safe
    {
        const k = root ~ "\0" ~ names.join("\0");
        if (auto l = k in listings)
            return *l;
        auto l = tree.files(root, names);
        listings[k] = l;
        return l;
    }

    const(ScannedSource)* source(string path) @safe
    {
        if (auto s = path in sources)
            return *s;
        string content;
        if (!tree.readText(path, content))
            return null;
        auto s = new ScannedSource;
        *s = scanSource(content);
        foreach (c; s.stringConditions)
            if (!(s.moduleName == "sparkles.base.meta" && c.kind == StringConditionKind.mixin_))
                conditionReports ~= ConditionReport(path, c.line, c.kind, c.insideUnittest);
        sources[path] = s;
        return s;
    }

    const(Mention)[] textOf(string path) @safe
    {
        if (auto m = path in texts)
            return *m;
        string content;
        const m = tree.readText(path, content) ? scanText(content) : null;
        texts[path] = m.dup;
        return texts[path];
    }

    // The D files a compile with `s` can reach, and every file under its
    // string import roots: its source files, then each module one of them
    // imports, found under the import roots as the compiler searches them.
    // A reached file that may import through a `mixin` makes every D file
    // under the import roots reachable.
    void filesOf(const ref BuildSettings s, out string[] dFiles, out string[] textFiles) @safe
    {
        bool[string] seen;
        void addD(string f)
        {
            if (f !in seen && (f.endsWithAny(".d", ".di")))
            {
                seen[f] = true;
                dFiles ~= f;
            }
        }
        foreach (f; s.sourceFiles)
            addD(f);
        bool everything;
        for (size_t next = 0; next < dFiles.length && !everything; ++next)
        {
            auto src = source(dFiles[next]);
            if (src is null)
                continue;
            if (src.mixinImports.length)
                everything = true;
            foreach (ref imp; src.imports)
                if (auto f = moduleFile(imp.module_, s.importPaths))
                    addD(f);
        }
        if (everything)
            foreach (root; s.importPaths)
                foreach (f; list(root, ["*.d", "*.di"]))
                    addD(f);
        foreach (root; s.stringImportPaths)
            foreach (f; list(root, ["*"]))
                if (f !in seen)
                {
                    seen[f] = true;
                    textFiles ~= f;
                }
    }

    Facts factsOf(const ref BuildSettings s) @safe
    {
        Facts facts;
        if (s.preGenerateCommands.length || s.preBuildCommands.length)
            facts.keepAll = "a generator fills one of its roots";

        string[] dFiles, textFiles;
        filesOf(s, dFiles, textFiles);
        bool[string] versions, debugVersions;
        void note(const Mention m)
        {
            (m.debug_ ? debugVersions : versions)[m.identifier] = true;
        }
        foreach (f; dFiles)
        {
            auto src = source(f);
            if (src is null)
                continue;
            foreach (m; src.mentions)
                note(m);
            if (!facts.keepAll.length)
                foreach (c; src.stringConditions)
                    // A `unittest` block compiles only in its own test root,
                    // which inherits nothing.
                    if (!c.insideUnittest
                        && !(src.moduleName == "sparkles.base.meta" && c.kind == StringConditionKind.mixin_))
                    {
                        facts.keepAll = text("a condition built from strings at ", f, ":", c.line);
                        break;
                    }
            lint(f, *src, s);
        }
        foreach (f; textFiles)
            foreach (m; textOf(f))
                note(m);
        facts.versions = versions.keys;
        facts.debugVersions = debugVersions.keys;
        return facts;
    }

    // A target's own files' mentions: its source files only, the ones its
    // own recipe names.
    LocatedMention[] ownMentionsOf(const ref ResolvedTarget t) @safe
    {
        LocatedMention[] found;
        foreach (f; t.settings.sourceFiles)
            if (f.startsWith(t.directory))
                if (auto src = source(f))
                    foreach (m; src.mentions)
                        found ~= LocatedMention(f, m);
        return found;
    }

    // The `isVersion` lint (BGV1) over one file.
    void lint(string path, const ref ScannedSource src, const ref BuildSettings s) @safe
    {
        if (path in linted || firstLintError !is null)
            return;
        linted[path] = true;
        bool reexports(const(char)[] module_) @safe => reexportsIsVersion(module_.idup, s.importPaths, 0);
        foreach (use; isVersionUses(src, &reexports))
            if (!use.literalArgument || !isPredefinedVersion(use.literal))
            {
                firstLintError = new PlanError(use.literalArgument
                    ? text("`isVersion!\"", use.literal, "\"` names no predefined version identifier;",
                        " a configuration's version would be pruned from it (BGV1, D34)")
                    : "`isVersion` takes a string literal naming a predefined version identifier"
                        ~ " (BGV1, D34)", path, use.line);
                return;
            }
    }

    // Whether `module_`'s public names include `sparkles.base.meta.isVersion`:
    // it is that module, or publicly imports one that does.
    bool reexportsIsVersion(string module_, const string[] importPaths, uint depth) @safe
    {
        if (module_ == "sparkles.base.meta")
            return true;
        if (auto known = module_ in reexporting)
            return *known;
        reexporting[module_] = false; // a cycle re-exports nothing new
        if (depth > 16)
            return false;
        const file = moduleFile(module_, importPaths);
        bool result;
        if (file.length)
            if (auto src = source(file))
                foreach (ref imp; src.imports)
                    if (imp.public_ && reexportsIsVersion(imp.module_, importPaths, depth + 1)
                        && (imp.bindings.length == 0 || imp.bindings.canFind!(b => b.name == "isVersion")))
                    {
                        result = true;
                        break;
                    }
        reexporting[module_] = result;
        return result;
    }

    // The file a module name resolves to under `importPaths`, or null: from
    // the roots' listings, which the scans make anyway, so no lookup probes
    // a path that is not there.
    string moduleFile(string module_, const string[] importPaths) @safe
    {
        foreach (root; importPaths)
            if (auto f = module_ in modulesUnder(root))
                return *f;
        return null;
    }

    // The modules beneath `root`, by the name their path gives them.
    string[string] modulesUnder(string root) @safe
    {
        import std.algorithm.searching : endsWith;
        import std.array : replace;

        if (auto m = root in moduleIndex)
            return *m;
        string[string] index;
        foreach (f; list(root, ["*.d", "*.di"]))
        {
            if (f.length <= root.length + 1)
                continue;
            auto rel = f[root.length + 1 .. $];
            rel = rel[0 .. rel.endsWith(".di") ? $ - 3 : $ - 2];
            if (rel.endsWith("/package"))
                rel = rel[0 .. $ - "/package".length];
            const name = rel.replace("/", ".");
            // The first listed wins. D rejects `a.d` beside `a/package.d`, and a
            // `.d` and its `.di` declare the same imports.
            if (name !in index)
                index[name] = f;
        }
        moduleIndex[root] = index;
        return index;
    }
}

bool endsWithAny(string s, string a, string b) @safe pure nothrow @nogc
{
    import std.algorithm.searching : endsWith;

    return s.endsWith(a) || s.endsWith(b);
}

string platformText(const BuildPlatform p) @safe
    => text(p.platform.join(","), "|", p.architecture.join(","), "|", p.compiler, "|",
        p.frontendVersion, "|", p.compilerVersion);

string hex(const ubyte[32] bytes) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    char[64] buf;
    foreach (i, b; bytes)
    {
        buf[2 * i] = digits[b >> 4];
        buf[2 * i + 1] = digits[b & 0xF];
    }
    return buf[].idup;
}

version (unittest)
{
    import sparkles.build_primitives.resolve.configure : ResolveRequest, resolve;
    import sparkles.build_primitives.resolve.tree : memoryTree;

    private enum linuxLdc = BuildPlatform(["linux", "posix"], ["x86_64"], "ldc", "ldc2", 2111, "1.41.0");
    private enum ldc = PlanOptions(ToolchainIdentity("ldc", "test-toolchain"));

    // Two test roots, `t1` and `t2`, each with a configuration-local version
    // and both on `mid`, which uses `leaf`. `mid` mentions `T1Only`; `leaf`
    // mentions neither.
    private string[string] fixtureFiles() @safe
    {
        return [
            "/r/dub.sdl": "name \"r\"\nsubPackage \"t1\"\nsubPackage \"t2\"\nsubPackage \"mid\"\nsubPackage \"leaf\"\n",
            "/r/t1/dub.sdl": "name \"t1\"\ndependency \"r:mid\" path=\"..\"\n"
                ~ "configuration \"library\" {\n}\nconfiguration \"unittest\" {\n    versions \"T1Only\"\n}\n",
            "/r/t1/source/t1.d": "module t1;\n",
            "/r/t2/dub.sdl": "name \"t2\"\ndependency \"r:mid\" path=\"..\"\n"
                ~ "configuration \"library\" {\n}\nconfiguration \"unittest\" {\n    versions \"T2Only\"\n}\n",
            "/r/t2/source/t2.d": "module t2;\n",
            "/r/mid/dub.sdl": "name \"mid\"\ndependency \"r:leaf\" path=\"..\"\n",
            "/r/mid/source/mid.d": "module mid;\nversion (T1Only) enum traced = true;\n",
            "/r/leaf/dub.sdl": "name \"leaf\"\n",
            "/r/leaf/source/leaf.d": "module leaf;\nint leaf;\n",
        ];
    }

    private Resolution resolvedIn(string[string] files, string pkg,
        VersionInheritance inheritance = VersionInheritance.faithful) @safe
    {
        auto r = resolve(ResolveRequest(directory: "/r", subPackage: pkg, buildType: "unittest",
            platform: linuxLdc, testRoot: true, inheritance: inheritance), memoryTree(files));
        assert(r.hasValue, r.hasError ? r.error.message : null);
        return r.value;
    }

    private VariantPlan planned(string[string] files, string[] packages...) @safe
    {
        auto tree = memoryTree(files);
        Resolution[] rs;
        foreach (p; packages)
        {
            auto r = resolve(ResolveRequest(directory: "/r", subPackage: p, buildType: "unittest",
                platform: linuxLdc, testRoot: true), tree);
            assert(r.hasValue, r.hasError ? r.error.message : null);
            rs ~= r.value;
        }
        auto plan = planVariants(rs, ldc, tree);
        assert(plan.hasValue, plan.hasError ? text(plan.error) : null);
        return plan.value;
    }

    private const(Variant) variantIn(const VariantPlan plan, size_t request, string pkg) @safe
    {
        foreach (i; plan.requests[request])
            if (plan.variants[i].package_ == pkg)
                return plan.variants[i];
        assert(false, "no variant of " ~ pkg);
    }
}

///
@("build_graph.variants.planVariants.prunesAndDedupes")
@safe unittest
{
    const plan = planned(fixtureFiles, ":t1", ":t2");

    // `leaf` mentions neither root's version: both prune it, and the two
    // requests share one `leaf`.
    const leaf1 = variantIn(plan, 0, "r:leaf"), leaf2 = variantIn(plan, 1, "r:leaf");
    assert(leaf1.key == leaf2.key);
    // One variant serves both: the dropped identifiers it records are the
    // first request's.
    assert(leaf1.prunedVersions == ["T1Only"] && leaf2.prunedVersions == ["T1Only"]);
    assert(!leaf1.settings.versions.canFind("T1Only"));
    assert(plan.variants.filter!(v => v.package_ == "r:leaf").array.length == 1);

    // `mid` mentions `T1Only`, so `t1`'s `mid` keeps it and differs from
    // `t2`'s, which prunes `T2Only`.
    const mid1 = variantIn(plan, 0, "r:mid"), mid2 = variantIn(plan, 1, "r:mid");
    assert(mid1.keptVersions == ["T1Only"] && mid1.settings.versions.canFind("T1Only"));
    assert(mid2.prunedVersions == ["T2Only"]);
    assert(mid1.key != mid2.key);

    // Two test roots, two `mid`s, one `leaf`.
    assert(plan.variants.length == 5);
}

@("build_graph.variants.planVariants.roles")
@safe unittest
{
    const plan = planned(fixtureFiles, ":t1");
    assert(variantIn(plan, 0, "r:t1").role == Role.testRoot);
    assert(variantIn(plan, 0, "r:mid").role == Role.dependencyLibrary);
    assert(variantIn(plan, 0, "r:leaf").role == Role.dependencyLibrary);
    // Planning again gives the same keys, in the same order.
    const again = planned(fixtureFiles, ":t1");
    assert(again.variants.map!(v => v.keyHex).array == plan.variants.map!(v => v.keyHex).array);
}

@("build_graph.variants.planVariants.stringBuiltConditionKeepsAll")
@safe unittest
{
    auto files = fixtureFiles;
    files["/r/leaf/source/leaf.d"] = "module leaf;\nmixin(\"version (\" ~ name ~ \") {}\");\n";
    const plan = planned(files, ":t1");
    const leaf = variantIn(plan, 0, "r:leaf");
    assert(leaf.keptVersions == ["T1Only"] && leaf.prunedVersions.length == 0);
    assert(leaf.keptAll.canFind("/r/leaf/source/leaf.d:2"), leaf.keptAll);
    assert(plan.conditions.length == 1 && plan.conditions[0].file == "/r/leaf/source/leaf.d");
}

@("build_graph.variants.planVariants.stringImportMentions")
@safe unittest
{
    auto files = fixtureFiles;
    files["/r/leaf/dub.sdl"] = "name \"leaf\"\nstringImportPaths \"views\"\n";
    files["/r/leaf/views/template.txt"] = "{% version (T1Only) %}\n";
    const plan = planned(files, ":t1");
    assert(variantIn(plan, 0, "r:leaf").keptVersions == ["T1Only"]);
}

@("build_graph.variants.planVariants.isVersionLint")
@safe unittest
{
    auto files = fixtureFiles;
    files["/r/leaf/source/leaf.d"] = "module leaf;\nimport sparkles.base.meta : isVersion;\n"
        ~ "enum ok = isVersion!\"linux\";\nenum bad = isVersion!\"T1Only\";\n"
        ~ "unittest { enum fine = isVersion!\"T1Only\"; }\n";
    auto tree = memoryTree(files);
    const r = resolve(ResolveRequest(directory: "/r", subPackage: ":t1", buildType: "unittest",
        platform: linuxLdc, testRoot: true), tree);
    const plan = planVariants([r.value], ldc, tree);
    assert(plan.hasError);
    assert(plan.error.file == "/r/leaf/source/leaf.d" && plan.error.line == 4, text(plan.error));
}

@("build_graph.variants.planVariants.divergentLint")
@safe unittest
{
    auto files = fixtureFiles;
    auto tree = memoryTree(files);
    const r = resolve(ResolveRequest(directory: "/r", subPackage: ":t1", buildType: "unittest",
        platform: linuxLdc, testRoot: true, inheritance: VersionInheritance.divergent), tree);
    assert(r.hasValue, r.hasError ? r.error.message : null);
    // `mid` tests `T1Only`, which `t1`'s configuration sets and the
    // divergent mode withholds.
    const plan = planVariants([r.value], ldc, tree);
    assert(plan.hasError);
    assert(plan.error.file == "/r/mid/source/mid.d" && plan.error.line == 2, text(plan.error));
    assert(plan.error.message.canFind("`r:mid` tests version `T1Only`"), plan.error.message);

    // `t2`'s version is tested by no dependency: it plans.
    const r2 = resolve(ResolveRequest(directory: "/r", subPackage: ":t2", buildType: "unittest",
        platform: linuxLdc, testRoot: true, inheritance: VersionInheritance.divergent), tree);
    assert(planVariants([r2.value], ldc, tree).hasValue);
}

@("build_graph.variants.planVariants.scansWhatIsReachable")
@safe unittest
{
    // `leaf` gains a module with a string-built condition. `mid` reads
    // `leaf`'s sources through its import paths, but imports nothing from
    // it, so `t2`'s `mid` still prunes `T2Only`.
    auto files = fixtureFiles;
    files["/r/leaf/source/gen.d"] = "module gen;\nmixin(\"version (\" ~ name ~ \") {}\");\n";
    assert(variantIn(planned(files, ":t2"), 0, "r:mid").prunedVersions == ["T2Only"]);

    // Once `mid` imports it, the condition is reachable: nothing is pruned.
    files["/r/mid/source/mid.d"] = "module mid;\nimport gen;\nversion (T1Only) enum traced = true;\n";
    const mid = variantIn(planned(files, ":t2"), 0, "r:mid");
    assert(mid.keptVersions == ["T2Only"] && mid.keptAll.canFind("/r/leaf/source/gen.d:2"), mid.keptAll);

    // A mention is reachable the same way: `mid` importing `leaf2`, which
    // tests `T2Only`, keeps it.
    files = fixtureFiles;
    files["/r/leaf/source/leaf2.d"] = "module leaf2;\nversion (T2Only) int x;\n";
    assert(variantIn(planned(files, ":t2"), 0, "r:mid").prunedVersions == ["T2Only"]);
    files["/r/mid/source/mid.d"] = "module mid;\nimport leaf2 : x;\n";
    assert(variantIn(planned(files, ":t2"), 0, "r:mid").keptVersions == ["T2Only"]);
}

@("build_graph.variants.planVariants.mixedInImportsWidenTheScan")
@safe unittest
{
    // A `mixin` that may import makes every file under the import roots
    // reachable, so `leaf2`'s mention keeps `T2Only` in `mid`.
    auto files = fixtureFiles;
    files["/r/leaf/source/leaf2.d"] = "module leaf2;\nversion (T2Only) int x;\n";
    files["/r/mid/source/mid.d"] = "module mid;\nmixin(\"import \" ~ which ~ \";\");\n";
    assert(variantIn(planned(files, ":t2"), 0, "r:mid").keptVersions == ["T2Only"]);
}

@("build_graph.variants.planVariants.unittestConditionsKeepNothing")
@safe unittest
{
    // A unittest block compiles only in its own package's test root, which
    // inherits nothing: its condition is reported and prunes as before.
    auto files = fixtureFiles;
    files["/r/leaf/source/leaf.d"] = "module leaf;\nunittest { mixin(\"version (\" ~ name ~ \") {}\"); }\n";
    const plan = planned(files, ":t1");
    assert(variantIn(plan, 0, "r:leaf").prunedVersions == ["T1Only"]);
    assert(plan.conditions.length == 1 && plan.conditions[0].insideUnittest);
}

@("build_graph.variants.planVariants.layoutLint")
@safe unittest
{
    import std.algorithm.searching : canFind;

    // A stand-in for `sparkles:unittest-layout`: a finding on every line
    // that says `version (unittest) int`, and the predicates it is given.
    bool sawPredicates;
    bool check(string path, const(char)[] source,
        scope bool delegate(const(char)[]) @safe dependedOn,
        scope bool delegate(const(char)[]) @safe versionSet,
        scope void delegate(uint, string) @safe finding) @safe
    {
        import std.string : lineSplitter;

        if (path.canFind("/leaf/"))
            sawPredicates = dependedOn("std.stdio") && dependedOn("leaf") && !dependedOn("absent.module")
                && !versionSet("T1Only");
        uint n;
        foreach (l; source.lineSplitter)
        {
            ++n;
            if (l.canFind("version (unittest) int"))
                finding(n, "a field");
        }
        return true;
    }

    auto files = fixtureFiles;
    files["/r/leaf/source/leaf.d"] = "module leaf;\nstruct S {\nversion (unittest) int x;\n}\n";
    auto tree = memoryTree(files);
    const r = resolve(ResolveRequest(directory: "/r", subPackage: ":t1", buildType: "unittest",
        platform: linuxLdc, testRoot: true), tree);

    // In-tree: the plan fails, naming the place.
    auto options = PlanOptions(ToolchainIdentity("ldc", "test-toolchain"), &check);
    const failed = planVariants([r.value], options, tree);
    assert(failed.hasError && failed.error.file == "/r/leaf/source/leaf.d" && failed.error.line == 3,
        text(failed.error));
    assert(sawPredicates);
    // The test root's own files are not a library's: `t1` is not linted.

    // From the registry: reported, and the plan stands.
    options.registry = ["r"];
    const reported = planVariants([r.value], options, tree);
    assert(reported.hasValue);
    assert(reported.value.layout.length == 1 && reported.value.layout[0].registry);
}
