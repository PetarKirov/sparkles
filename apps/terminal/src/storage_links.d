/// The `~/storage` links `termux-setup-storage` creates (Termux's names),
/// into shared storage at `root`. Pure; see `am_server.setupStorage`.
module storage_links;

/// One `~/storage/<name>` → `target` link.
struct StorageLink
{
    string name, target;
}

/// Termux's set: the shared-storage root and its standard directories.
StorageLink[] storageLinks(string root) @safe pure nothrow
{
    return [
        StorageLink("shared", root),
        StorageLink("downloads", root ~ "/Download"),
        StorageLink("dcim", root ~ "/DCIM"),
        StorageLink("pictures", root ~ "/Pictures"),
        StorageLink("music", root ~ "/Music"),
        StorageLink("movies", root ~ "/Movies"),
        StorageLink("documents", root ~ "/Documents"),
    ];
}

///
@("storage_links.storageLinks")
@safe pure nothrow unittest
{
    const l = storageLinks("/storage/emulated/0");
    assert(l[0] == StorageLink("shared", "/storage/emulated/0"));
    assert(l[1] == StorageLink("downloads", "/storage/emulated/0/Download"));
}
