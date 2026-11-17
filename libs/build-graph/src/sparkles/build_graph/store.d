/**
The shared store (build-graph SPEC §6): published results, the manifest lists
of declared keys, and the leases of the processes using them, on the VFS
beneath the store's own root (BGF4).

$(LREF Store) is one store's layout version directory, `<store>`:

$(LIST
    * `results/<key>/` a published result: `out/`, the action's outputs and
        its `output.log`, and `record`, their digests and the action's status;
        * `manifests/<key>` the manifest list of a declared key, most recently
        used first (BGK3);
        * `leases/<key>/<holder>` one file per process using a result (BGS4);
        * `staging/` entries being written, published by one rename (BGS2);
        * `trash/` entries a loser, a corruption or a removal moved aside.
)

A result's key is its declared key for an action without a manifest, and,
for a compile, the digest of its declared key and its manifest's entries
($(LREF resultKey)). Every file the store writes records its format version
(BGS10), and one in another format is a miss.

Lookup ($(LREF Store.find)) leases the result before it reads it and checks
that each recorded output exists with its size (BGS6); one that does not is
moved to `trash/` and is a miss. Publication ($(LREF Store.publish)) moves an
action's output directory into a staging entry beside its record, publishes
the entry by one rename, and leaves a relative link in the output directory's
place, so the run reads the result where the store holds it. When another
producer published the key first, the entry goes to `trash/` and the link
names the winner's (BGS3); the outputs that differ are reported.

Eviction, digest records, preimages, miss explanations, inspection and the
determinism check (BGS5–BGS9) are not here yet.
*/
module sparkles.build_graph.store;

import std.algorithm.iteration : splitter;
import std.algorithm.searching : startsWith;
import std.array : array;
import std.conv : text;

import sparkles.base.vfs.types : Access, Disposition, EntryKind, OpenMode, Rights, Stat, StatMask;

/// The store's layout version: the name of its directory, `v1` (BGS1, BGS10).
enum uint layoutVersion = 1;

/// The format version of every record and manifest list (BGS10, BGK1): it
/// changes with any change to how a key, a manifest or a record is made.
enum uint formatVersion = 1;

/// How many manifests a declared key keeps (BGK3).
enum size_t manifestBound = 16;

/// One published result, as inspection lists it (BGS7).
struct StoreEntry
{
    string key;       ///
    string task;      /// the task that published it
    string toolchain; ///
    ulong bytes;      /// its outputs' bytes
    long recency;     /// when a lease on it was last created, in ns since the epoch
}

/// What an eviction did (BGS5).
struct EvictionReport
{
    string[] evicted;      /// the result keys evicted, their records kept
    string[] leased;       /// the ones a live lease held back: the overshoot
    size_t recordsDropped; /// records and preimages dropped for the second bound
    ulong resultBytes;     /// the results' bytes afterwards
    ulong recordBytes;     /// the records' bytes afterwards
}

/// One output of a result: a regular file beneath its `out/`.
struct OutputRecord
{
    string path;     /// relative to `out/`, `/`-separated
    ulong size;      ///
    bool executable; ///
    ubyte[32] digest; /// BLAKE3 (D48)
}

/// One file a compile read, with the digest of what it read (BGK2).
struct ManifestEntry
{
    string path;      /// root-relative, or absolute for a store path
    ubyte[32] digest; ///
}

/// What a compile resolved (BGK2): the files it read and the absent
/// candidates its searches probed.
struct Manifest
{
    ManifestEntry[] files; ///
    string[] absent;       ///

    /// The canonical text, one entry per line, files first.
    string text() const @safe pure
    {
        string s;
        foreach (ref f; files)
            s ~= "file " ~ hexOf(f.digest) ~ " " ~ f.path ~ "\n";
        foreach (a; absent)
            s ~= "absent " ~ a ~ "\n";
        return s;
    }
}

/// A published result's record.
struct ResultRecord
{
    string task;          /// the task id that published it
    string toolchain;     /// the toolchain identity it was built with (§8)
    string declaredKey;   ///
    string resultKey;     ///
    int status;           /// the exit status
    OutputRecord[] outputs; /// sorted by path

    /// The record's text.
    string text() const @safe pure
    {
        string s = "format " ~ formatVersion.text ~ "\ntask " ~ task ~ "\ntoolchain " ~ toolchain ~ "\ndeclared " ~ declaredKey
            ~ "\nresult " ~ resultKey ~ "\nstatus " ~ status.text ~ "\n";
        foreach (ref o; outputs)
            s ~= "output " ~ hexOf(o.digest) ~ " " ~ o.size.text ~ " " ~ (o.executable ? "x" : "-")
                ~ " " ~ o.path ~ "\n";
        return s;
    }

    /// The digest of the outputs alone: what a consumer's key holds of
    /// them (BGK1), the same for every producer that made the same bytes.
    string outputsDigest() const @safe pure
    {
        import sparkles.base.hash.blake3 : blake3;

        string s;
        foreach (ref o; outputs)
            s ~= hexOf(o.digest) ~ " " ~ o.size.text ~ " " ~ (o.executable ? "x" : "-") ~ " " ~ o.path ~ "\n";
        return hexOf(blake3(s));
    }
}

/// Parses a record; false for another format or a malformed one.
bool parseRecord(scope const(char)[] source, out ResultRecord r) @safe pure
{
    import std.conv : ConvException, to;
    import std.string : lineSplitter;

    bool formatSeen;
    foreach (line; source.lineSplitter)
    {
        string rest;
        if (word(line, "format", rest))
            formatSeen = rest == formatVersion.text;
        else if (word(line, "task", rest))
            r.task = rest;
        else if (word(line, "toolchain", rest))
            r.toolchain = rest;
        else if (word(line, "declared", rest))
            r.declaredKey = rest;
        else if (word(line, "result", rest))
            r.resultKey = rest;
        else if (word(line, "status", rest))
        {
            try
                r.status = rest.to!int;
            catch (ConvException)
                return false;
        }
        else if (word(line, "output", rest))
        {
            // <digest> <size> <x|-> <path>
            OutputRecord o;
            if (rest.length < 64 + 1 || !parseHex(rest[0 .. 64], o.digest))
                return false;
            rest = rest[65 .. $];
            size_t space = 0;
            while (space < rest.length && rest[space] != ' ')
                ++space;
            try
                o.size = rest[0 .. space].to!ulong;
            catch (ConvException)
                return false;
            if (space + 3 > rest.length)
                return false;
            o.executable = rest[space + 1] == 'x';
            o.path = rest[space + 3 .. $];
            r.outputs ~= o;
        }
    }
    return formatSeen && r.resultKey.length;
}

/// Parses a manifest list: manifests separated by `--` lines, after a
/// `format` line; empty for another format.
Manifest[] parseManifestList(scope const(char)[] source) @safe pure
{
    import std.string : lineSplitter;

    Manifest[] list;
    Manifest current;
    bool any, formatSeen;
    foreach (line; source.lineSplitter)
    {
        string rest;
        if (word(line, "format", rest))
        {
            if (rest != formatVersion.text)
                return null;
            formatSeen = true;
        }
        else if (line == "--")
        {
            if (any)
                list ~= current;
            current = Manifest.init;
            any = false;
        }
        else if (word(line, "file", rest))
        {
            ManifestEntry e;
            if (rest.length < 66 || !parseHex(rest[0 .. 64], e.digest))
                return null;
            e.path = rest[65 .. $];
            current.files ~= e;
            any = true;
        }
        else if (word(line, "absent", rest))
        {
            current.absent ~= rest;
            any = true;
        }
    }
    if (any)
        list ~= current;
    return formatSeen ? list : null;
}

/// A manifest list's text.
string manifestListText(const Manifest[] list) @safe pure
{
    string s = "format " ~ formatVersion.text ~ "\n";
    foreach (ref m; list)
        s ~= "--\n" ~ m.text;
    return s;
}

/// A compile's result key: the digest of its declared key and its
/// manifest's entries (BGK3).
string resultKey(string declaredKey, const ref Manifest m) @safe pure
{
    import std.digest.sha : sha256Of;

    return hexOf(sha256Of("result " ~ formatVersion.text ~ "\n" ~ declaredKey ~ "\n" ~ m.text));
}

/// A declared key: the SHA-256 of its preimage, the text naming each
/// component BGK1 lists, one per line (BGS8 keeps it to explain a miss).
string declaredKeyOf(scope const(char)[] preimage) @safe pure
{
    import std.digest.sha : sha256Of;

    return hexOf(sha256Of(preimage));
}

/**
One store: its layout version directory, opened through a directory handle
of a root that also holds the run directories, so a publication renames and
never copies.
*/
struct Store(D)
{
    private D v;           // `<store>`
    private string holder; // this process's lease name
    private string[] leased;
    private size_t staged;

    /// Why a publication failed, or what it found; null when nothing.
    string note;

    @disable this(this);

    /**
    The store in `dir`, the store's top directory (`build`): its layout
    directory is created with its subdirectories, and the top directory
    holds a `CACHEDIR.TAG` (BGS7). `holder` names this process's leases.
    */
    static bool open(ref D dir, string holder, out Store s)
    {
        import core.lifetime : move;

        if (dir.writeFileAtomic("CACHEDIR.TAG", cacheDirTag).hasError)
            return false;
        auto v = dir.walkAll("v" ~ layoutVersion.text);
        if (v.hasError)
            return false;
        foreach (sub; ["results", "manifests", "leases", "staging", "trash", "preimages", "recency", "records", "digests"])
            if (v.value.walkAll(sub).hasError)
                return false;
        s.v = move(v.value);
        s.holder = holder;
        return true;
    }

    /// The manifests recorded for `declaredKey`, most recently used first.
    Manifest[] manifests(string declaredKey)
    {
        string source;
        if (!readAll(v, "manifests/" ~ declaredKey, source))
            return null;
        return parseManifestList(source);
    }

    /// Records `m` as the most recently used manifest of `declaredKey`,
    /// keeping at most `manifestBound` (BGK3). A concurrent update may lose
    /// an entry (BGS3).
    void useManifest(string declaredKey, const ref Manifest m)
    {
        Manifest[] list = [cast(Manifest) m];
        const text_ = m.text;
        foreach (ref other; manifests(declaredKey))
            if (other.text != text_ && list.length < manifestBound)
                list ~= other;
        auto dir = v.walk("manifests");
        if (!dir.hasError)
            cast(void) dir.value.writeFileAtomic(declaredKey, manifestListText(list));
    }

    /**
    Leases `resultKey`, then reads its record: null when it is not
    published, is in another format, or fails the lookup's check that each
    recorded output exists with its size, in which case it is moved to
    `trash/` (BGS4, BGS6).
    */
    ResultRecord* find(string resultKey)
    {
        lease(resultKey);
        string source;
        if (!readAll(v, "results/" ~ resultKey ~ "/record", source))
            return null;
        auto r = new ResultRecord;
        if (!parseRecord(source, *r) || r.resultKey != resultKey)
            return null;
        auto out_ = v.walk("results/" ~ resultKey ~ "/out");
        if (out_.hasError)
            return discard(resultKey, "its out directory is missing");
        foreach (ref o; r.outputs)
        {
            auto st = statPath(out_.value, o.path);
            if (st.hasError || st.value.kind != EntryKind.regular || st.value.size != o.size)
                return discard(resultKey, "output " ~ o.path ~ " is missing or changed size");
        }
        return r;
    }

    /**
    Publishes the directory `name` in `parent`, which must lie beneath the
    same root, under `record.resultKey` (BGS2): it moves to a staging entry
    beside its record, the entry is renamed into `results/`, and `name`
    becomes a link to the published `out/`, written as `linkTarget`, the
    path from `parent` to `<store>/results/<key>/out` (`{}` standing for the
    key). Returns the record of what `name` names afterwards: this one, or
    the one a concurrent producer published first (BGS3), with `note`
    naming the outputs that differ. Null when nothing was published, with
    `note` saying why: `name` is then as it was.
    */
    const(ResultRecord)* publish(P)(ref P parent, string name, const ref ResultRecord record,
        string linkTarget)
    {
        import std.array : replace;

        note = null;
        const key = record.resultKey;
        const stage = text(key[0 .. key.length < 16 ? $ : 16], "-", holder, "-", staged++);
        auto staging = v.walk("staging");
        if (staging.hasError)
            return failed("no staging directory");
        if (staging.value.mkdirAt(stage).hasError)
            return failed("cannot create a staging entry");
        auto entry = staging.value.walk(stage);
        if (entry.hasError)
            return failed("cannot open the staging entry");
        if (entry.value.writeFileAtomic("record", record.text).hasError)
            return failed("cannot write the record");
        if (parent.renameAt(name, entry.value, "out").hasError)
            return failed("cannot move the outputs into staging");

        lease(key);
        auto results = v.walk("results");
        const(ResultRecord)* published = &record;
        if (results.hasError || staging.value.renameAt(stage, results.value, key).hasError)
        {
            // BGS3: the first rename won; adopt its entry, if it is whole.
            auto winner = find(key);
            if (winner is null)
            {
                // Put the outputs back: they serve this run (BGS2).
                cast(void) entry.value.renameAt("out", parent, name);
                return failed("cannot publish the entry");
            }
            const differing = differences(*winner, record);
            if (differing.length)
                note = "nondeterministic: result " ~ key ~ " differs in " ~ differing;
            auto trash = v.walk("trash");
            if (!trash.hasError)
                cast(void) staging.value.renameAt(stage, trash.value, stage);
            published = winner;
        }
        if (parent.symlinkAt(name, linkTarget.replace("{}", key)).hasError)
            note ~= (note.length ? "; " : "") ~ "cannot link " ~ name ~ " to the result";
        return published;
    }

    /// Records `preimage`, the declared key's, as the one `task` last
    /// published (BGS8); a newer one replaces it.
    void recordPreimage(string task, scope const(char)[] preimage)
    {
        auto dir = v.walkAll("preimages");
        if (!dir.hasError)
            cast(void) dir.value.writeFileAtomic(taskFileName(task),
                "format " ~ formatVersion.text ~ "\ntask " ~ task ~ "\n" ~ preimage);
    }

    /// The preimage `task` last published, without its header; null when
    /// none is recorded.
    string preimage(string task)
    {
        string source;
        if (!readAll(v, "preimages/" ~ taskFileName(task), source))
            return null;
        const header = "format " ~ formatVersion.text ~ "\ntask " ~ task ~ "\n";
        return source.startsWith(header) ? source[header.length .. $] : null;
    }

    /**
    BGK5: the file system's clock, as the store's directory holds it: the
    modification time of a probe file written now, and the device it lies
    on. False when no probe can be written.
    */
    bool probeClock(out long nowNs, out ulong device)
    {
        import sparkles.base.vfs.types : StatMask;

        if (v.writeFileAtomic("clock-probe", holder).hasError)
            return false;
        auto st = v.statAt("clock-probe", StatMask.mtime);
        if (st.hasError || !st.value.hasMtime)
            return false;
        nowNs = st.value.mtimeNs;
        device = st.value.device;
        return true;
    }

    /**
    BGK5: the digest cached for `path`, if its identity tuple (`st`: device,
    inode, size, modification and change times) is the one recorded with it
    and neither time is later than the recording time minus two seconds,
    git's rule for racily clean entries. A file whose times are not old
    enough is rehashed by the caller.
    */
    bool cachedDigest(string path, const ref Stat st, out ubyte[32] digest)
    {
        import std.conv : ConvException, to;
        import std.string : lineSplitter;

        string source;
        if (!readAll(v, "digests/" ~ taskFileName(path), source))
            return false;
        long[string] n;
        string hex, recordedPath;
        foreach (line; source.lineSplitter)
        {
            string rest;
            foreach (field; ["dev", "ino", "size", "mtime", "ctime", "recorded"])
                if (word(line, field, rest))
                {
                    try
                        n[field] = rest.to!long;
                    catch (ConvException)
                        return false;
                }
            if (word(line, "digest", rest))
                hex = rest;
            if (word(line, "path", rest))
                recordedPath = rest;
        }
        if (recordedPath != path || "recorded" !in n || !source.startsWith("format " ~ formatVersion.text ~ "\n"))
            return false;
        enum long margin = 2_000_000_000;
        const recorded = n["recorded"];
        if (n.get("dev", -1) != cast(long) st.device || n.get("ino", -1) != cast(long) st.inode
            || n.get("size", -1) != cast(long) st.size || n.get("mtime", -1) != st.mtimeNs
            || n.get("ctime", -1) != st.ctimeNs)
            return false;
        if (st.mtimeNs >= recorded - margin || st.ctimeNs >= recorded - margin)
            return false;
        return parseHex(hex, digest);
    }

    /// Records `digest` for `path` with its identity tuple and the
    /// recording time `recordedNs`, the probe's (BGK5).
    void cacheDigest(string path, const ref Stat st, long recordedNs, const ref ubyte[32] digest)
    {
        auto dir = v.walkAll("digests");
        if (!dir.hasError)
            cast(void) dir.value.writeFileAtomic(taskFileName(path), text("format ", formatVersion, "\npath ", path,
                "\ndev ", st.device, "\nino ", st.inode, "\nsize ", st.size, "\nmtime ", st.mtimeNs, "\nctime ",
                st.ctimeNs, "\nrecorded ", recordedNs, "\ndigest ", hexOf(digest), "\n"));
    }

    /// Whether `resultKey`'s result is published.
    bool published(string resultKey)
    {
        string source;
        return readAll(v, "results/" ~ resultKey ~ "/record", source);
    }

    /// Leases `resultKey` for the rest of this process's run (BGS4), and
    /// marks the result used now: its recency is when a lease on it was
    /// last created (BGS5, D38).
    void lease(string resultKey)
    {
        foreach (k; leased)
            if (k == resultKey)
                return;
        auto dir = v.walkAll("leases/" ~ resultKey);
        if (dir.hasError)
            return;
        enum mode = OpenMode(Access.write, Disposition.createOrTruncate);
        auto f = dir.value.openFile!mode(holder);
        if (!f.hasError)
            leased ~= resultKey;
        auto recency = v.walkAll("recency");
        if (!recency.hasError)
            cast(void) recency.value.writeFileAtomic(resultKey, "");
    }

    /// Every published result, with its output bytes and recency (BGS7).
    StoreEntry[] entries()
    {
        import sparkles.base.vfs.types : StatMask;

        StoreEntry[] all;
        foreach (key; names("results"))
        {
            string source;
            ResultRecord r;
            if (!readAll(v, "results/" ~ key ~ "/record", source) || !parseRecord(source, r))
                continue;
            StoreEntry e = StoreEntry(key, r.task, r.toolchain);
            foreach (ref o; r.outputs)
                e.bytes += o.size;
            auto recency = v.walk("recency");
            auto st = recency.hasError ? typeof(recency.value.statAt(key, StatMask.mtime))(recency.error)
                : recency.value.statAt(key, StatMask.mtime);
            if (st.hasError)
            {
                auto results = v.walk("results");
                if (!results.hasError)
                    st = results.value.statAt(key, StatMask.mtime);
            }
            if (!st.hasError)
                e.recency = st.value.mtimeNs;
            all ~= e;
        }
        return all;
    }

    /// The bytes of the records the store keeps: manifest lists, digest
    /// records and preimages (BGS5's second bound).
    ulong recordBytes()
    {
        ulong n;
        foreach (dir; ["manifests", "records", "preimages"])
        {
            auto d = v.walk(dir);
            if (d.hasError)
                continue;
            foreach (name; names(dir))
            {
                auto st = d.value.statAt(name);
                if (!st.hasError)
                    n += st.value.size;
            }
        }
        return n;
    }

    /// Whether another process holds a live lease on `resultKey`: `alive`
    /// says whether a lease's holder still runs. A dead holder's lease is
    /// reclaimed (BGS4).
    bool leasedByOthers(string resultKey, scope bool delegate(string holder) alive)
    {
        auto dir = v.walk("leases/" ~ resultKey);
        if (dir.hasError)
            return false;
        bool live;
        foreach (h; names("leases/" ~ resultKey))
        {
            if (h == holder)
                continue;
            if (alive(h))
                live = true;
            else
                cast(void) dir.value.unlinkAt(h);
        }
        return live;
    }

    /**
    Garbage collection (BGS5): empties `trash/`, removes the staging entries
    and leases of holders that no longer run. Returns how many entries went.
    */
    size_t collectGarbage(scope bool delegate(string holder) alive)
    {
        size_t n;
        auto trash = v.walk("trash");
        if (!trash.hasError)
            foreach (name; names("trash"))
                if (!trash.value.removeTree(name).hasError)
                    ++n;
        auto staging = v.walk("staging");
        if (!staging.hasError)
            foreach (name; names("staging"))
            {
                // `<key prefix>-<pid>-<start>-<n>`: its producer's holder name.
                const parts = name.splitter('-').array;
                if (parts.length >= 4 && !alive(parts[$ - 3] ~ "-" ~ parts[$ - 2]) && !staging.value.removeTree(name).hasError)
                    ++n;
            }
        foreach (key; names("leases"))
            cast(void) leasedByOthers(key, alive);
        return n;
    }

    /**
    Verification (BGS6, BGS7): rehashes every recorded output of the results
    `keys` names, or of every result when null. A result that differs is
    moved to `trash/`. Returns the keys found corrupt.
    */
    string[] verify(const string[] keys = null)
    {
        import sparkles.base.hash.blake3 : blake3;

        string[] corrupt;
        foreach (key; keys !is null ? keys.dup : names("results"))
        {
            string source;
            ResultRecord r;
            if (!readAll(v, "results/" ~ key ~ "/record", source) || !parseRecord(source, r))
                continue;
            foreach (ref o; r.outputs)
            {
                ubyte[] bytes;
                if (!readBytes(v, "results/" ~ key ~ "/out/" ~ o.path, bytes) || bytes.length != o.size
                    || blake3(bytes) != o.digest)
                {
                    corrupt ~= key;
                    discard(key, "output " ~ o.path ~ " does not match its digest");
                    break;
                }
            }
        }
        return corrupt;
    }

    /**
    Removal (BGS7): moves to `trash/` every result whose record `which`
    selects, waiting for none: a result another live process leases is left,
    and reported in `held`. Returns the keys removed.
    */
    string[] remove(scope bool delegate(const ref ResultRecord) which,
        scope bool delegate(string holder) alive, out string[] held)
    {
        string[] removed;
        foreach (key; names("results"))
        {
            string source;
            ResultRecord r;
            if (!readAll(v, "results/" ~ key ~ "/record", source) || !parseRecord(source, r) || !which(r))
                continue;
            if (leasedByOthers(key, alive))
            {
                held ~= key;
                continue;
            }
            if (moveToTrash(key))
                removed ~= key;
        }
        return removed;
    }

    /**
    Eviction (BGS5): while the results' output bytes exceed `resultsBound`,
    or the records' bytes `recordsBound`, removes the least recently used
    first, down to 90 % of the bound. A result with a live lease is skipped
    and its overshoot reported. An evicted result keeps its record under
    `records/<key>`: its outputs' digests and sizes and its status.
    */
    EvictionReport evict(ulong resultsBound, ulong recordsBound, scope bool delegate(string holder) alive)
    {
        import std.algorithm.sorting : sort;

        EvictionReport report;
        auto all = entries().sort!((a, b) => a.recency < b.recency).release;
        ulong total;
        foreach (ref e; all)
            total += e.bytes;
        report.resultBytes = total;
        if (total > resultsBound)
        {
            const target = resultsBound / 10 * 9;
            foreach (ref e; all)
            {
                if (total <= target)
                    break;
                if (leasedByOthers(e.key, alive))
                {
                    report.leased ~= e.key;
                    continue;
                }
                string source;
                cast(void) readAll(v, "results/" ~ e.key ~ "/record", source);
                if (!moveToTrash(e.key))
                    continue;
                // Step 3: a lease that appeared meanwhile brings it back.
                if (leasedByOthers(e.key, alive))
                {
                    auto trash = v.walk("trash");
                    auto results = v.walk("results");
                    if (!trash.hasError && !results.hasError)
                        cast(void) trash.value.renameAt(lastTrashed, results.value, e.key);
                    report.leased ~= e.key;
                    continue;
                }
                auto records = v.walkAll("records");
                if (!records.hasError && source.length)
                    cast(void) records.value.writeFileAtomic(e.key, source);
                auto recency = v.walk("recency");
                if (!recency.hasError)
                    cast(void) recency.value.unlinkAt(e.key);
                total -= e.bytes;
                report.evicted ~= e.key;
            }
        }
        report.resultBytes = total;
        // The records' bound: the oldest preimages and digest records first.
        ulong records = recordBytes();
        if (records > recordsBound)
        {
            import sparkles.base.vfs.types : StatMask;

            const target = recordsBound / 10 * 9;
            foreach (dir; ["records", "preimages"])
            {
                auto d = v.walk(dir);
                if (d.hasError)
                    continue;
                foreach (name; names(dir))
                {
                    if (records <= target)
                        break;
                    auto st = d.value.statAt(name);
                    if (!st.hasError && !d.value.unlinkAt(name).hasError)
                    {
                        records -= st.value.size;
                        ++report.recordsDropped;
                    }
                }
            }
        }
        report.recordBytes = records;
        return report;
    }

    // The names in `<store>/<dir>`, sorted.
    private string[] names(string dir)
    {
        import std.algorithm.sorting : sort;

        string[] result;
        auto d = v.walk(dir);
        if (d.hasError)
            return null;
        auto listing = d.value.list();
        if (listing.hasError)
            return null;
        while (true)
        {
            auto more = listing.value.next();
            if (more.hasError || !more.value)
                break;
            result ~= listing.value.front.name.idup;
        }
        return result.sort.release;
    }

    private string lastTrashed;

    // Renames `results/<key>` into `trash/` under a unique name.
    private bool moveToTrash(string key)
    {
        auto results = v.walk("results");
        auto trash = v.walk("trash");
        if (results.hasError || trash.hasError)
            return false;
        lastTrashed = text(key, "-", holder, "-", staged++);
        return !results.value.renameAt(key, trash.value, lastTrashed).hasError;
    }

    /// Ends every lease this process holds (BGS4).
    void releaseLeases()
    {
        foreach (k; leased)
        {
            auto dir = v.walk("leases/" ~ k);
            if (dir.hasError)
                continue;
            cast(void) dir.value.unlinkAt(holder);
            auto top = v.walk("leases");
            if (!top.hasError)
                cast(void) top.value.rmdirAt(k); // only when no other holder's lease is left
        }
        leased = null;
    }

    private const(ResultRecord)* failed(string why)
    {
        note = why;
        return null;
    }

    // BGS6: moves a corrupt entry to `trash/` before it goes.
    private ResultRecord* discard(string key, string why)
    {
        note = "corrupt result " ~ key ~ ": " ~ why;
        auto results = v.walk("results");
        auto trash = v.walk("trash");
        if (!results.hasError && !trash.hasError)
            cast(void) results.value.renameAt(key, trash.value, text(key, "-", holder, "-", staged++));
        return null;
    }
}

/// The `CACHEDIR.TAG` a store's top directory and the runs' directory hold
/// (BGS7), so backup tools skip them.
enum cacheDirTag = "Signature: 8a477f597d28d172789f06886806bc55\n"
    ~ "# This directory is a cache of sparkles' build graph: results anyone can rebuild.\n"
    ~ "# For information about cache directory tags, see https://bford.info/cachedir/\n";

// A task id as one file name: its digest, since an id holds `:`.
private string taskFileName(string task) @safe pure
{
    import sparkles.base.hash.blake3 : blake3;

    return hexOf(blake3(task));
}

/**
BGS8: the components two preimages disagree on, by name (`arg`, `env`,
`input libs/a.d`, …), in the newer's order, comma-separated: each line of
one that the other lacks.
*/
string preimageDifferences(scope const(char)[] older, scope const(char)[] newer) @safe pure
{
    import std.string : lineSplitter;

    bool[string] before, after;
    foreach (line; older.lineSplitter)
        before[line.idup] = true;
    foreach (line; newer.lineSplitter)
        after[line.idup] = true;
    string s;
    bool[string] named;
    void name(scope const(char)[] line)
    {
        // `input <digest> <path>` names its path; any other, its keyword.
        string n;
        if (line.startsWith("input ") && line.length > 6 + 65)
            n = ("input " ~ line[6 + 65 .. $]).idup;
        else
        {
            size_t space = 0;
            while (space < line.length && line[space] != ' ')
                ++space;
            n = line[0 .. space].idup;
        }
        if (n !in named)
        {
            named[n] = true;
            s ~= (s.length ? ", " : "") ~ n;
        }
    }
    foreach (line; newer.lineSplitter)
        if (line !in before)
            name(line);
    foreach (line; older.lineSplitter)
        if (line !in after)
            name(line);
    return s;
}

/// The outputs two records disagree on, comma-separated; empty when none.
string differences(const ref ResultRecord a, const ref ResultRecord b) @safe pure
{
    string s;
    foreach (ref x; a.outputs)
    {
        bool same;
        foreach (ref y; b.outputs)
            if (y.path == x.path && y.digest == x.digest && y.size == x.size)
                same = true;
        if (!same)
            s ~= (s.length ? ", " : "") ~ x.path;
    }
    foreach (ref y; b.outputs)
    {
        bool present;
        foreach (ref x; a.outputs)
            if (x.path == y.path)
                present = true;
        if (!present)
            s ~= (s.length ? ", " : "") ~ y.path;
    }
    return s;
}

/// Lowercase hexadecimal.
string hexOf(scope const(ubyte)[] bytes) @safe pure nothrow
{
    static immutable digits = "0123456789abcdef";
    auto s = new char[bytes.length * 2];
    foreach (i, b; bytes)
    {
        s[2 * i] = digits[b >> 4];
        s[2 * i + 1] = digits[b & 0xF];
    }
    return (() @trusted => cast(string) s)();
}

/// Parses 64 hexadecimal digits.
bool parseHex(scope const(char)[] s, out ubyte[32] digest) @safe pure nothrow @nogc
{
    static int nibble(char c) @safe pure nothrow @nogc
        => c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;

    if (s.length != 64)
        return false;
    foreach (i; 0 .. 32)
    {
        const hi = nibble(s[2 * i]), lo = nibble(s[2 * i + 1]);
        if (hi < 0 || lo < 0)
            return false;
        digest[i] = cast(ubyte)(hi << 4 | lo);
    }
    return true;
}

/**
`path` beneath `root` with every link it crosses replaced by its target,
one component at a time, as planning's tree resolves one (BGF3): the path a
handle on `root` reads without crossing a link, for a link whose target
climbs out of its own directory but not out of the root. Null when a link
leaves the root, is absolute, or the chain is longer than 40 links.
*/
string resolvedPath(D)(ref D root, string path)
{
    import std.array : join, split;

    string[] done;
    string[] rest = path.split("/");
    size_t links;
    while (rest.length)
    {
        const c = rest[0];
        rest = rest[1 .. $];
        if (c.length == 0 || c == ".")
            continue;
        if (c == "..")
        {
            if (!done.length)
                return null;
            done = done[0 .. $ - 1];
            continue;
        }
        const here = (done ~ c).join("/");
        auto st = statPath(root, here);
        if (!st.hasError && st.value.kind == EntryKind.symlink)
        {
            if (++links > 40)
                return null;
            char[4096] buffer;
            string target;
            if (done.length)
            {
                auto dir = root.walk(done.join("/"));
                if (dir.hasError)
                    return null;
                auto t = dir.value.readlinkAt(c, buffer[]);
                if (t.hasError)
                    return null;
                target = t.value.idup;
            }
            else
            {
                auto t = root.readlinkAt(c, buffer[]);
                if (t.hasError)
                    return null;
                target = t.value.idup;
            }
            if (target.length == 0 || target[0] == '/')
                return null;
            rest = target.split("/") ~ rest;
            continue;
        }
        done ~= c;
    }
    return done.join("/");
}

/// Reads the whole file at the `/`-separated `path` beneath `dir`.
bool readAll(D)(ref D dir, scope const(char)[] path, out string text_)
{
    ubyte[] bytes;
    if (!readBytes(dir, path, bytes))
        return false;
    text_ = (() @trusted => cast(string) bytes)();
    return true;
}

/// ditto, as bytes.
bool readBytes(D)(ref D dir, scope const(char)[] path, out ubyte[] bytes)
{
    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/')
        --slash;
    bool from(E)(ref E d, scope const(char)[] name)
    {
        auto file = d.openFile!(OpenMode.read)(name);
        if (file.hasError)
            return false;
        ubyte[] buffer = new ubyte[64 * 1024];
        size_t n;
        for (;;)
        {
            if (n == buffer.length)
                buffer.length *= 2;
            auto r = file.value.read(buffer[n .. $]);
            if (r.hasError)
                return false;
            if (r.value == 0)
                break;
            n += r.value;
        }
        bytes = buffer[0 .. n];
        return true;
    }
    if (slash == 0)
        return from(dir, path);
    auto sub = dir.walk(path[0 .. slash - 1]);
    return !sub.hasError && from(sub.value, path[slash .. $]);
}

/// Stats the `/`-separated `path` beneath `dir`, the entry itself, never a
/// link's target.
auto statPath(D)(ref D dir, scope const(char)[] path,
    StatMask mask = StatMask.basic)
{
    import sparkles.base.vfs.types : StatMask;

    size_t slash = path.length;
    while (slash > 0 && path[slash - 1] != '/')
        --slash;
    if (slash == 0)
        return dir.statAt(path, mask);
    auto sub = dir.walk(path[0 .. slash - 1]);
    alias R = typeof(dir.statAt(path, mask));
    if (sub.hasError)
        return R(sub.error);
    return sub.value.statAt(path[slash .. $], mask);
}

private bool word(scope const(char)[] line, string keyword, out string rest) @safe pure
{
    if (line.length > keyword.length && line[0 .. keyword.length] == keyword && line[keyword.length] == ' ')
    {
        rest = line[keyword.length + 1 .. $].idup;
        return true;
    }
    return false;
}

/// A record and a manifest list read back as written; another format is
/// a miss.
@("build_graph.store.encodings")
@safe pure unittest
{
    static ubyte[32] digestOf(ubyte b) @safe pure nothrow @nogc
    {
        ubyte[32] d;
        d[0] = b;
        return d;
    }

    ResultRecord r;
    r.task = "compile:r.leaf:library:ldc:abc";
    r.declaredKey = "d";
    r.resultKey = "k";
    r.outputs = [OutputRecord("libleaf.a", 12, false, digestOf(3))];
    ResultRecord back;
    assert(parseRecord(r.text, back) && back == r);
    assert(!parseRecord("format 0\nresult k\n", back));

    Manifest m;
    m.files = [ManifestEntry("libs/a.d", digestOf(9))];
    m.absent = ["libs/b.d"];
    const list = parseManifestList(manifestListText([m, Manifest([ManifestEntry("x.d", digestOf(1))])]));
    assert(list.length == 2 && list[0] == m && list[1].files[0].path == "x.d");
    assert(parseManifestList("format 0\n--\nabsent a\n") is null);
    assert(resultKey("d", m) != resultKey("e", m));
}

/// BGS8: a declared miss names the components whose lines differ, an input
/// by its path.
@("build_graph.store.preimageDifferences")
@safe pure unittest
{
    enum d1 = "0000000000000000000000000000000000000000000000000000000000000001";
    enum d2 = "0000000000000000000000000000000000000000000000000000000000000002";
    const older = "format 1\nkind compile\narg -O\nenv PATH=\ninput " ~ d1 ~ " libs/a.d\n";
    const newer = "format 1\nkind compile\narg -O3\nenv PATH=\ninput " ~ d2 ~ " libs/a.d\n";
    assert(preimageDifferences(older, newer) == "arg, input libs/a.d");
    assert(preimageDifferences(older, older) == "");
}
