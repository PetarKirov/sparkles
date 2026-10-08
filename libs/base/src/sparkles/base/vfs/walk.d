/**
The component walk: resolves a path one entry at a time from a held directory
handle (VFP3–VFP8, VFR1, VFR4).

Each step opens one entry relative to the handle the previous step returned,
never following it (VFO2). A `..` returns to a handle the walk still holds and
is never opened through the backend (VFP7). Under `symlinks = beneath`, a link
met on the way is read and its target spliced into the rest of the path,
resolved from the directory holding the link (VFP5). A root whose resolution
is `kernelWholePath` asks the backend's resolver instead, and its refusal is
the result (VFR4).

The walk owns every handle it opens and closes all but the one it returns,
on success and on failure alike.
*/
module sparkles.base.vfs.walk;

import sparkles.base.io.errors : ErrorKind, IoError, IoErrorStage, IoResult, OpKind, ioErr, ioOk;
import sparkles.base.vfs.concept : hasSearchOpen, hasWholePathResolver, isVfs, resolverWithdrawn;
import sparkles.base.vfs.names : checkName, checkWalkPath, isAbsolutePath, isSeparator,
    lexicalError;
import sparkles.base.vfs.types : ResolvePolicy, Resolution, Sharing, StatMask, SymlinkPolicy,
    maxSplicedPathLength, maxSymlinkHops, maxWalkDepth;

/**
Resolves `path` from `start`, which the walk does not own, and returns an
owned handle to the directory it names. With `createMissing`, a component
that does not exist is created with `sharing` (`walkAll`).
*/
// `H` rather than `V.Handle`: a backend whose `Handle` aliases another
// backend's would otherwise make `V` deduce two ways.
IoResult!(V.Handle) walkFrom(V, H)(ref V vfs, H start, scope const(char)[] path,
    ResolvePolicy policy, Resolution resolution, bool createMissing, Sharing sharing,
    bool requireKernel = false)
if (isVfs!V && is(H == V.Handle))
{
    const lexical = checkWalkPath(path, policy);
    if (lexical != ErrorKind.other)
        return ioErr!(V.Handle)(lexicalError(lexical, OpKind.resolve));

    static if (hasWholePathResolver!V)
    {
        if (resolution == Resolution.kernelWholePath)
        {
            // VFR5: once the resolver is found withdrawn, a root that requires it
            // fails, and any other root uses the component walk from then on.
            const withdrawn = resolverWithdrawn(vfs);
            if (withdrawn && requireKernel)
                return ioErr!(V.Handle)(ErrorKind.unsupported, OpKind.resolve, 0,
                    IoErrorStage.probe, "the kernel resolver is no longer available");
            if (!withdrawn && !createMissing)
            {
                // VFR4: a kernel refusal is the result; the walk never runs for it.
                // Only a withdrawal found during this very call falls through.
                auto r = vfs.resolveWhole(start, path, policy);
                if (!r.hasError || requireKernel || r.error.kind != ErrorKind.unsupported
                    || r.error.stage != IoErrorStage.probe)
                    return r;
            }
        }
    }

    Walk!V w = Walk!V(&vfs, start, policy, createMissing, sharing);
    return w.run(path);
}

private struct Walk(V)
{
    V* vfs;
    V.Handle start;
    ResolvePolicy policy;
    bool createMissing;
    Sharing sharing;

    // stack[0 .. depth] holds the directories entered before `cur`; stack[0]
    // is `start` once anything is entered. `cur` is owned exactly when
    // depth > 0, and so is every stack entry above index 0.
    V.Handle[maxWalkDepth] stack;
    ulong[maxWalkDepth] devices;
    size_t depth;
    V.Handle cur;
    ulong curDevice;

    char[maxSplicedPathLength] pending;
    size_t length, pos;

    @disable this(this);

    this(V* vfs, V.Handle start, ResolvePolicy policy, bool createMissing, Sharing sharing)
    {
        this.vfs = vfs;
        this.start = start;
        this.policy = policy;
        this.createMissing = createMissing;
        this.sharing = sharing;
        cur = start;
    }

    IoResult!(V.Handle) run(scope const(char)[] path) scope
    {
        if (path.length > pending.length)
            return ioErr!(V.Handle)(ErrorKind.nameTooLong, OpKind.resolve);
        pending[0 .. path.length] = path[];
        length = path.length;

        if (!policy.crossMounts)
        {
            auto st = vfs.fstat(start, StatMask.basic);
            if (st.hasError)
                return ioErr!(V.Handle)(st);
            curDevice = st.value.device;
        }

        size_t hops;
        bool retried;
        while (true)
        {
            size_t componentStart, componentEnd;
            if (!nextComponent(componentStart, componentEnd))
                break;
            const c = pending[componentStart .. componentEnd];

            if (c == "..")
            {
                if (depth == 0)
                    return fail(IoError(ErrorKind.escapesRoot, 0, OpKind.resolve));
                vfs.close(cur);
                --depth;
                cur = stack[depth];
                curDevice = devices[depth];
                continue;
            }

            const nameKind = checkName(c); // a spliced link target is checked here
            if (nameKind != ErrorKind.other)
                return fail(lexicalError(nameKind, OpKind.resolve));

            // VFN14: pass through for search only where the backend can.
            static if (hasSearchOpen!V)
                auto opened = vfs.openSearchAt(cur, c);
            else
                auto opened = vfs.openDirAt(cur, c);
            if (!opened.hasError)
            {
                retried = false;
                ulong device = curDevice;
                if (!policy.crossMounts)
                {
                    auto st = vfs.fstat(opened.value, StatMask.basic);
                    if (st.hasError || st.value.device != curDevice)
                    {
                        vfs.close(opened.value);
                        return fail(st.hasError ? st.error
                            : IoError(ErrorKind.crossesMount, 0, OpKind.openAt));
                    }
                    device = st.value.device;
                }
                if (depth == maxWalkDepth)
                {
                    vfs.close(opened.value);
                    return fail(IoError(ErrorKind.depthExceeded, 0, OpKind.openAt));
                }
                stack[depth] = cur;
                devices[depth] = curDevice;
                ++depth;
                cur = opened.value;
                curDevice = device;
                continue;
            }

            const kind = opened.error.kind;
            if (kind == ErrorKind.symlinkRefused && policy.symlinks == SymlinkPolicy.beneath)
            {
                if (++hops > maxSymlinkHops)
                    return fail(IoError(ErrorKind.symlinkLoop, 0, OpKind.resolve));
                const spliced = splice(c);
                if (spliced.kind != ErrorKind.other)
                    return fail(spliced);
                continue;
            }
            if (kind == ErrorKind.notFound && createMissing && !retried)
            {
                auto made = vfs.mkdirAt(cur, c, sharing);
                if (made.hasError && made.error.kind != ErrorKind.exists)
                    return fail(made.error);
                retried = true;
                pos = componentStart; // open the same component again
                continue;
            }
            return fail(opened.error);
        }

        if (depth == 0)
            return vfs.reopen(start); // VFP3: an empty path yields a new handle
        static if (hasSearchOpen!V)
        {
            // The result was opened for search only; reopen it with full access.
            auto full = vfs.reopen(cur);
            if (full.hasError)
                return fail(full.error);
            vfs.close(cur);
            cur = full.value;
        }
        foreach (i; 1 .. depth)
            vfs.close(stack[i]);
        depth = 0;
        return ioOk(cur);
    }

    // Finds the next component of the pending path; false at its end.
    bool nextComponent(out size_t componentStart, out size_t componentEnd) scope
    {
        while (pos < length)
        {
            while (pos < length && isSeparator(pending[pos]))
                ++pos;
            const s = pos;
            while (pos < length && !isSeparator(pending[pos]))
                ++pos;
            if (pos > s && !(pos - s == 1 && pending[s] == '.'))
            {
                componentStart = s;
                componentEnd = pos;
                return true;
            }
        }
        return false;
    }

    // VFP5: replaces the link component just read with its target.
    IoError splice(scope const(char)[] link) scope
    {
        char[maxSplicedPathLength] target;
        auto n = vfs.readlinkAt(cur, link, target[]);
        if (n.hasError)
            return n.error;
        const t = target[0 .. n.value];
        if (t.length == 0 || isAbsolutePath(t))
            return IoError(ErrorKind.escapesRoot, 0, OpKind.readlinkAt);
        const rest = length - pos;
        const total = t.length + 1 + rest;
        if (total > pending.length)
            return IoError(ErrorKind.nameTooLong, 0, OpKind.resolve);
        // target ~ "/" ~ rest, assembled behind the target and copied back.
        target[t.length] = '/';
        target[t.length + 1 .. total] = pending[pos .. length];
        pending[0 .. total] = target[0 .. total];
        length = total;
        pos = 0;
        return IoError(ErrorKind.other);
    }

    IoResult!(V.Handle) fail(IoError e) scope
    {
        if (depth > 0)
        {
            vfs.close(cur);
            foreach (i; 1 .. depth)
                vfs.close(stack[i]);
            depth = 0;
        }
        return ioErr!(V.Handle)(e);
    }
}
