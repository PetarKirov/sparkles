/** Source-only DUB cache import from a Nix-vendored dependency bundle. */
module dub_cache;

import std.exception : enforce;
import std.file : SpanMode, copy, dirEntries, exists, getAttributes,
    isDir, isSymlink, mkdirRecurse, rename, rmdirRecurse, setAttributes;
import std.path : buildPath, dirName, relativePath;
import std.process : environment;
import std.uuid : randomUUID;

/// The writable user package home, respecting DUB_HOME. Nix shells use this
/// same location; custom DUB settings.json dubHome users should set DUB_HOME.
string userDubHome() @safe
{
    const configured = environment.get("DUB_HOME", "");
    if (configured.length) return configured;
    version (Windows)
        return buildPath(environment.get("LOCALAPPDATA", environment.get("APPDATA")), "dub");
    else
        return buildPath(environment.get("HOME"), ".dub");
}

/// Import only packages/<name>/<version>, never settings, registrations or
/// compiled artifacts. Existing versions (including locally edited sources)
/// are left untouched. Stage each version beside its destination and rename
/// it into place only after the writable copy is complete.
size_t seedDubHome(string sourceHome, string destinationHome) @safe
{
    const packages = buildPath(sourceHome, "packages");
    enforce(packages.isDir, "DUB source bundle has no packages directory: " ~ sourceHome);
    size_t imported;
    foreach (packageEntry; dirEntries(packages, SpanMode.shallow))
    {
        if (!packageEntry.isDir || packageEntry.isSymlink) continue;
        foreach (versionEntry; dirEntries(packageEntry.name, SpanMode.shallow))
        {
            if (!versionEntry.isDir || versionEntry.isSymlink) continue;
            const destination = buildPath(destinationHome, "packages",
                relativePath(versionEntry.name, packages));
            if (destination.exists) continue;
            mkdirRecurse(destination.dirName);
            const staging = destination ~ ".seed-" ~ randomUUID().toString();
            mkdirRecurse(staging);
            scope(exit) if (staging.exists) rmdirRecurse(staging);
            foreach (entry; dirEntries(versionEntry.name, SpanMode.depth))
            {
                // The Nix importer produces real source trees. Do not follow
                // links into the immutable store or outside the source tree.
                enforce(!entry.isSymlink, "Symlink in DUB source bundle: " ~ entry.name);
                const target = buildPath(staging, relativePath(entry.name, versionEntry.name));
                if (entry.isDir)
                    mkdirRecurse(target);
                else
                {
                    mkdirRecurse(target.dirName);
                    copy(entry.name, target);
                    version (Posix)
                    {
                        import core.sys.posix.sys.stat : S_IRUSR, S_IWUSR;
                        setAttributes(target, getAttributes(entry.name) | S_IRUSR | S_IWUSR);
                    }
                }
            }
            // Another seed invocation may have finished the same version.
            if (destination.exists) continue;
            try
                rename(staging, destination);
            catch (Exception e)
            {
                if (destination.exists) continue;
                throw e;
            }
            ++imported;
        }
    }
    return imported;
}

/// An ordinary DUB-built ci still works without Nix; a packaged ci always
/// supplies the bundle explicitly through its wrapper.
size_t seedBundledDubHome(string destinationHome) @safe
{
    const bundle = environment.get("SPARKLES_DUB_SOURCES", "");
    return bundle.length ? seedDubHome(buildPath(bundle, ".dub"), destinationHome) : 0;
}

@("ci.dubCache.writableSourcesPreserveExistingAndExcludeArtifacts")
unittest
{
    import std.file : readText, tempDir, write;
    const root = buildPath(tempDir, "sparkles-dub-seed-" ~ randomUUID().toString());
    scope(exit) if (root.exists) rmdirRecurse(root);
    const source = buildPath(root, "source");
    const destination = buildPath(root, "destination");
    const packagePath = buildPath("packages", "example", "1.2.3", "example");
    mkdirRecurse(buildPath(source, packagePath));
    write(buildPath(source, packagePath, "dub.sdl"), "name \"example\"");
    version (Posix)
    {
        import core.sys.posix.sys.stat : S_IRUSR, S_IRGRP, S_IROTH;
        setAttributes(buildPath(source, packagePath, "dub.sdl"), S_IRUSR | S_IRGRP | S_IROTH);
    }
    mkdirRecurse(buildPath(source, "cache"));
    write(buildPath(source, "cache", "artifact"), "do not import");
    write(buildPath(source, "settings.json"), "do not import");
    assert(seedDubHome(source, destination) == 1);
    assert(!buildPath(destination, "cache").exists);
    assert(!buildPath(destination, "settings.json").exists);
    const manifest = buildPath(destination, packagePath, "dub.sdl");
    write(manifest, "user edit");
    assert(seedDubHome(source, destination) == 0);
    assert(manifest.readText == "user edit");
}
