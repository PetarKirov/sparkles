# The SQLite VFS as substrate (portability layer / OS-interface seam)

Every other entry in this catalog treats the **format** as the invariant. This one argues the format is only half of it: SQLite travels because its b-tree sits on a seventeen-function access layer that can be replaced without the file changing, and the same b-tree pages that arrive from a `pread(2)` also arrive from an OPFS sync handle, an HTTP 206 response, a `localStorage` key, or a byte range appended to the end of an executable.

| Field           | Value                                                                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Portability layer — two C structs of function pointers (`sqlite3_vfs`, `sqlite3_io_methods`) plus the shims and browser VFSes built on them                         |
| Language        | C (core, `os_unix.c`, `os_win.c`, `os_kv.c`, `ext/misc/*vfs*.c`); JavaScript (the three OPFS VFSes in `ext/wasm/api/`)                                              |
| License         | Public domain (SQLite's blessing-in-place-of-a-licence)                                                                                                             |
| Repository      | [sqlite/sqlite][repo] (the GitHub mirror of the canonical Fossil tree)                                                                                              |
| Documentation   | [The SQLite OS Interface or "VFS"][vfs-doc] · [`sqlite3_vfs`][c3-vfs] · [`sqlite3_io_methods`][c3-io] · [Persistent Storage Options (WASM/JS)][persistence]         |
| First release   | The `sqlite3_vfs` object shipped with SQLite 3.5.0 (2007-09-04); `iVersion` reached 3 in 3.7.6 (2011-04-12); `opfs` VFS 2022, `opfs-sahpool` 3.43, `opfs-wl` 3.53.0 |
| Axis profile    | Multiplicity **1** / Reflexivity **2** / Closure **0** / Mutability **2**                                                                                           |
| Index anchoring | **out-of-band** — the VFS holds no index; it is the layer at which anchoring becomes _negotiable_ (see [`appendvfs`](#the-appendvfs-proof))                         |
| Dispatch owner  | **consumer** — the application names a VFS at `sqlite3_open_v2()` or in a `file:…?vfs=name` URI; no kernel, no loader, no sniffing                                  |

> **Latest revision surveyed:** `sqlite/sqlite` at [`8a988271`][repo] (2026-08-26), `VERSION` = `3.54.0`; [`whatwg/fs`][fs-repo] at `cd55e558` (2026-03-15); [`phiresky/sql.js-httpvfs`][httpvfs-repo] at `c64536d2` (2023-03-02); [`WebAssembly/tool-conventions`][tc-repo] at `83e5d715`. **Platform:** the C layer is universal; the OPFS VFSes are browser-only and Worker-only.

---

## Overview

### What it solves

SQLite's stack is five layers deep — interface, tokenizer/parser/code-generator, virtual machine, b-tree, pager, OS interface — and everything above the bottom one is written against byte offsets, not against files. The pager asks for "`iAmt` bytes at `iOfst`" and for "make the previous writes durable". It never asks for a file descriptor, a path, an `mmap`, or a `fsync`. That separation is not an accident of layering; it is the explicit portability strategy, and it is what this catalog's [thesis 5][concepts] names.

The consequence that matters here is asymmetric. A format-level portability strategy — [APE's][ape] simultaneous satisfaction of six loaders, [ZIP-suffix parasitism][zip] — buys reach by making the _bytes_ acceptable to more parsers, and every new target costs new cleverness in the byte stream. A substrate-level strategy buys reach by making the _access layer_ replaceable, and every new target costs one implementation of a fixed interface with the byte stream untouched. The 2022–2026 browser work is the natural experiment: SQLite reached the web without a single change to the [file format][fileformat], by writing three new VFSes.

The catalog's counter-case is [SELF][self], which declines format multiplicity entirely (`Multiplicity = 1`) and bets that the substrate travels instead. That bet is only as good as the seam, so the seam deserves a page.

### Design philosophy

The canonical statement is one paragraph, and it is thesis 5 asserted as an engineering plan ([sqlite.org/vfs.html][vfs-doc] §2):

> _"The OS Interface - also called the 'VFS' - is what makes SQLite portable across operating systems. Whenever any of the other modules in SQLite needs to communicate with the operating system, they invoke methods in the VFS. The VFS then invokes the operating-specific code needed to satisfy the request. Hence, porting SQLite to a new operating system is simply a matter of writing a new OS interface layer or 'VFS'."_

The same page describes the layer above it in terms that make the interface's narrowness deliberate:

> _"The OS Interface is a thin abstraction that provides a common set of routines for adapting SQLite to run on different operating systems."_

What makes the seam load-bearing rather than merely tidy is a second decision: multiple VFSes coexist, and selection is per-connection and even per-`ATTACH`ed file.

> _"Multiple VFSes can be registered at the same time. Each VFS has a unique name. Separate database connections within the same process can be using different VFSes at the same time. For that matter, if a single database connection has multiple database files open using the ATTACH command, then each attached database might be using a different VFS."_

That sentence is why "execute this program out of OPFS / out of S3 / out of a range-requested URL" is a configuration question and not an engineering one — the [open question](#open-question-the-smallest-browser-side-self-exec) this page closes on.

---

## How it works

### Two structs, seventeen and eighteen slots

The whole interface is two vtables in [`src/sqlite.h.in`][sqlite-h]. [`sqlite3_vfs`][c3-vfs] handles everything that is about the _namespace_ — opening, deleting, probing, canonicalising — plus a handful of not-really-filesystem services (randomness, sleep, clock) that were folded in "for completeness":

```c
/* src/sqlite.h.in — sqlite3_vfs, abridged */
struct sqlite3_vfs {
  int iVersion;            /* Structure version number (currently 3) */
  int szOsFile;            /* Size of subclassed sqlite3_file */
  int mxPathname;          /* Maximum file pathname length */
  sqlite3_vfs *pNext;      /* Next registered VFS */
  const char *zName;       /* Name of this virtual file system */
  void *pAppData;          /* Pointer to application-specific data */
  int (*xOpen)(sqlite3_vfs*, sqlite3_filename zName, sqlite3_file*,
               int flags, int *pOutFlags);
  int (*xDelete)(sqlite3_vfs*, const char *zName, int syncDir);
  int (*xAccess)(sqlite3_vfs*, const char *zName, int flags, int *pResOut);
  int (*xFullPathname)(sqlite3_vfs*, const char *zName, int nOut, char *zOut);
  /* xDlOpen / xDlError / xDlSym / xDlClose  — loadable extensions   */
  /* xRandomness / xSleep / xCurrentTime / xGetLastError             */
  /* v2: xCurrentTimeInt64                                           */
  /* v3: xSetSystemCall / xGetSystemCall / xNextSystemCall           */
};
```

[`sqlite3_io_methods`][c3-io] handles everything that is about one _open file_, and `xOpen` is the factory that ties the two together by storing a pointer to an `sqlite3_io_methods` in the caller-allocated `sqlite3_file`:

```c
/* src/sqlite.h.in — sqlite3_io_methods */
int (*xClose)(sqlite3_file*);
int (*xRead)(sqlite3_file*, void*, int iAmt, sqlite3_int64 iOfst);
int (*xWrite)(sqlite3_file*, const void*, int iAmt, sqlite3_int64 iOfst);
int (*xTruncate)(sqlite3_file*, sqlite3_int64 size);
int (*xSync)(sqlite3_file*, int flags);
int (*xFileSize)(sqlite3_file*, sqlite3_int64 *pSize);
int (*xLock)(sqlite3_file*, int);
int (*xUnlock)(sqlite3_file*, int);
int (*xCheckReservedLock)(sqlite3_file*, int *pResOut);
int (*xFileControl)(sqlite3_file*, int op, void *pArg);
int (*xSectorSize)(sqlite3_file*);
int (*xDeviceCharacteristics)(sqlite3_file*);
/* v2: xShmMap / xShmLock / xShmBarrier / xShmUnmap  — the WAL index */
/* v3: xFetch / xUnfetch                            — memory mapping */
```

Three groupings inside that list decide almost everything a substrate can and cannot do:

- **`xRead`/`xWrite`/`xTruncate`/`xFileSize`** are the byte-range channel. A VFS sees `(offset, length)` and nothing else; it never learns that a page is a b-tree interior node, that a cell has overflowed, or which table a byte belongs to.
- **`xLock`/`xUnlock`/`xCheckReservedLock`** implement [SQLite's five-state lock ladder][lockingv3] — `NONE`, `SHARED`, `RESERVED`, `PENDING`, `EXCLUSIVE` — which is the concurrency contract, not a filesystem detail.
- **`xSync`, `xSectorSize`, `xDeviceCharacteristics`** are the durability contract. `xDeviceCharacteristics` returns a bit vector ([`SQLITE_IOCAP_*`][iocap]) by which the substrate _declares_ what the hardware guarantees, and SQLite reshapes its journalling accordingly.

### What a VFS is allowed to do

Everything about _where and how_ bytes live. `xOpen` receives the filename, the `SQLITE_OPEN_*` flags — including which _kind_ of file this is (`MAIN_DB`, `MAIN_JOURNAL`, `WAL`, `TEMP_DB`, `SUBJOURNAL`, `SUPER_JOURNAL`) — and may do anything it likes with them. The header spells out how far that freedom reaches:

> _"The file I/O implementation can use the object type flags to change the way it deals with files. For example, an application that does not care about crash recovery or rollback might make the open of a journal file a no-op. Writes to this journal would also be no-ops, and any attempt to read the journal would return SQLITE_IOERR."_

A VFS may also invent filenames (`xOpen` with a `NULL` `zName` must, and the flags will then include `SQLITE_OPEN_DELETEONCLOSE`), redefine `xFullPathname` to any canonicalisation it likes, decline locking altogether, and stack: a _shim_ VFS wraps another and forwards. [`cksumvfs`][cksumvfs] uses a shim to write a per-page checksum into the [reserved bytes at the tail of each page][fileformat]; [`vfstrace`][vfstrace-src] logs every call; [`vfsstat`][vfsstat-src] counts them.

### What a VFS is not allowed to do

Four prohibitions do the real work, and every substrate in this page's table is shaped by them.

1. **It may not be asynchronous.** Every method returns an `int`; there is no continuation, no callback, no promise. This single fact is the entire reason the browser story looks the way it does.
2. **It may not lie about short reads.** The header is unusually blunt:
   > _"If xRead() returns SQLITE_IOERR_SHORT_READ it must also fill in the unread portions of the buffer with zeros. A VFS that fails to zero-fill short reads might seem to work. However, failure to zero-fill short reads will eventually lead to database corruption."_
3. **It may not see or alter page structure.** The pager hands `xWrite` a finished page image. A blob that spills onto overflow pages is already chained, with a four-byte next-page pointer at the front of each overflow page, _above_ the VFS — which is precisely why the `mmap`-the-segments idea in [the SELF deep-dive][self] cannot be solved by writing a clever VFS. The seam is one layer too low for that problem.
4. **It may not mutate itself after registration.** `pNext` is the only field SQLite touches, under a static mutex; the docs state that "the application should never modify anything within the `sqlite3_vfs` object once the object has been registered."

The layer's amendability is versioned rather than open: `iVersion` on both structs is monotone, new fields append, and a VFS declaring `iVersion = 1` on its `sqlite3_io_methods` is simply telling SQLite that `xShmMap` and `xFetch` are absent. Both official OPFS VFSes do exactly that — `opfsIoMethods.$iVersion = 1` in [`opfs-common-shared.c-pp.js`][opfs-shared] and [`sqlite3-vfs-opfs-sahpool.c-pp.js`][sahpool] — which is how "no WAL in the browser" and "no memory mapping in the browser" are expressed: not as an error, as a version number.

### The browser case, and why there is a Worker

The [Origin-Private FileSystem][fs-spec] is the browser's persistent byte store, and its only _synchronous_ surface is [`FileSystemSyncAccessHandle`][fs-spec], obtained by `await fileHandle.createSyncAccessHandle()`. Its whole interface is six synchronous methods:

```
interface FileSystemSyncAccessHandle {
  unsigned long long read(AllowSharedBufferSource buffer, optional FileSystemReadWriteOptions options = {});
  unsigned long long write(AllowSharedBufferSource buffer, optional FileSystemReadWriteOptions options = {});
  undefined truncate([EnforceRange] unsigned long long newSize);
  unsigned long long getSize();
  undefined flush();
  undefined close();
};
```

That maps onto `xRead`/`xWrite`/`xTruncate`/`xFileSize`/`xSync`/`xClose` almost slot-for-slot — the interface SQLite has had since 2007 and the interface WHATWG specified in 2022 are the same interface. The spec is explicit about why it exists:

> _"The returned `FileSystemSyncAccessHandle` offers synchronous methods. This allows for higher performance on contexts where asynchronous operations come with high overhead, e.g., WebAssembly."_

But **acquiring** the handle is asynchronous and takes an exclusive lock:

> _"Creating a `FileSystemSyncAccessHandle` takes an exclusive lock on the file entry locatable with `fileHandle`'s locator. This prevents the creation of further `FileSystemSyncAccessHandles` or `FileSystemWritableFileStreams` for the entry, until the access handle is closed."_

So the sequence "open a database, read page 1" requires an `await` inside a function that must return an `int`. There is no way to suspend a synchronous WebAssembly call stack. The `opfs` VFS resolves this by putting the `await`s in a _second_, dedicated Worker and blocking the first one on `Atomics.wait()` over a `SharedArrayBuffer`. [`opfs-common-shared.c-pp.js`][opfs-shared] allocates one SAB slot per proxied method —

```js
state.opIds.whichOp = i++; /* which method the sync side wants */
state.opIds.rc = i++; /* where the async side writes the result */
state.opIds.xAccess = i++;
state.opIds.xClose = i++;
state.opIds.xDelete = i++;
state.opIds.xFileSize = i++;
state.opIds.xLock = i++;
state.opIds.xOpen = i++;
state.opIds.xRead = i++;
state.opIds.xSleep = i++;
state.opIds.xSync = i++;
state.opIds.xTruncate = i++;
state.opIds.xUnlock = i++;
state.opIds.xWrite = i++;
```

— plus a second, 64 KiB + `2 × mxPathname` SAB for payload and argument serialisation (64 KiB because "64k = max sqlite3 page size, and xRead/xWrite() will never deal in blocks larger than that"). `opRun()` serialises the arguments, stores the opcode, `Atomics.notify()`s, and then spins on `Atomics.wait()` until the answer slot changes:

```js
Atomics.store(state.sabOPView, state.opIds.rc, -1);
Atomics.store(state.sabOPView, state.opIds.whichOp, opNdx);
Atomics.notify(state.sabOPView, state.opIds.whichOp);
while ('not-equal' !== Atomics.wait(state.sabOPView, state.opIds.rc, -1)) {
  /* … */
}
```

The proxy in [`sqlite3-opfs-async-proxy.c-pp.js`][opfs-proxy] then does the real work — `getSyncHandle(fh,'xRead')` followed by `sah.read(fh.sabView.subarray(0,n), {at: Number(offset64)})` — and `storeAndNotify()`s the result code back. `xSync` is `await fh.syncHandle.flush()`. `getSyncHandle` contains a six-attempt exponential wait-and-retry loop because `createSyncAccessHandle()` throws `NoModificationAllowedError` when another tab holds the lock.

Because a synchronous C API therefore requires a Worker that is _itself_ blocked for the duration of every I/O, the whole SQLite instance has to live off the main thread. That is what the **Worker1** message API and the **promiser** wrapper on top of it exist for: [`sqlite3-worker1-promiser.c-pp.js`][promiser] "implements a Promise-based proxy for the sqlite3 Worker API #1", so a main-thread application talks to a database it can never touch directly. The promiser is not ergonomics; it is the shape the synchronous VFS contract forces on everything above it.

### The same b-tree over five substrates

The catalog's framing is "same b-tree, five substrates". Enumerated against the shipped code, with what each one actually costs:

| Substrate           | VFS name(s)                                                       | Implementation                                                                                         | Locking                                                                               | `xFetch`?                                         | Byte identity                               | Admission price                                                               |
| ------------------- | ----------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------- | ------------------------------------------------- | ------------------------------------------- | ----------------------------------------------------------------------------- |
| Unix file           | `unix`, `unix-dotfile`, `unix-excl`, `unix-none`, `unix-namedsem` | [`src/os_unix.c`][os-unix] — `pread`/`pwrite`, POSIX advisory locks, `mmap`                            | full five-state ladder                                                                | **yes**                                           | exact                                       | none                                                                          |
| OPFS sync handles   | `opfs`, `opfs-wl`                                                 | [`opfs-common-shared.c-pp.js`][opfs-shared] + a dedicated Worker running [the async proxy][opfs-proxy] | exclusive only; SQLite's ladder is approximated, contention surfaces as `SQLITE_BUSY` | no (`iVersion = 1`)                               | exact                                       | COOP `same-origin` + COEP `require-corp`, HTTPS, a Worker                     |
| OPFS handle pool    | `opfs-sahpool`                                                    | [`sqlite3-vfs-opfs-sahpool.c-pp.js`][sahpool] — pre-acquired handles, 4096-byte private header         | none; `xLock` returns 0                                                               | no                                                | **offset-shifted** by 4096, opaque filename | one connection per origin; explicit `installOpfsSAHPoolVfs()`                 |
| HTTP range requests | _(no shipped VFS)_                                                | [`sql.js-httpvfs`][httpvfs-repo] as an Emscripten `FS` backend; a true VFS is unwritten                | read-only; no locking needed                                                          | no                                                | exact (remote)                              | `Accept-Ranges: bytes`, no transport re-encoding, CORS exposure of the header |
| In-memory           | `memdb`, `:memory:`                                               | [`src/memdb.c`][memdb] — one heap buffer; `sqlite3_serialize`/`sqlite3_deserialize`                    | a process-local mutex over a shared `MemStore`                                        | **yes** (`memdbFetch` returns `p->aData + iOfst`) | exact, on serialise                         | none; nothing persists                                                        |
| Key/value strings   | `kvvfs`                                                           | [`src/os_kv.c`][os-kv] — one entry per page, hex + base-26 zero-run encoding                           | none                                                                                  | no                                                | **re-encoded**                              | main-thread only (v1); one db per storage object                              |

A sixth row is the one this catalog cares about most and it does not exist yet: **whatever a `self-exec` would do with `mmap`**. On Linux that means a VFS handing back a pointer into a file mapping, which `unixFetch` already does for SQLite's own page reads — but not for a _program loader_, because a loader wants the segment bytes contiguous and page-aligned, and [the overflow-chain analysis in the SELF deep-dive][self] shows the b-tree will not deliver them that way at any page size. In the browser the row is simply empty: there is no mapping primitive to build it on. Both observations are [thesis 4][concepts] holding its ground against thesis 5.

Note also what the browser build chooses as its _default_: [`ext/wasm/GNUmakefile`][wasm-mk] passes `-DSQLITE_DEFAULT_UNIX_VFS="unix-none"` and `-DSQLITE_THREADSAFE=0`. The fallback substrate is a `unix` VFS with all locking compiled out, over Emscripten's in-memory filesystem — correct because there is exactly one thread and one process, and a nice illustration that the ladder is a _ceiling_ on what SQLite may ask for rather than a set of operations a substrate must genuinely perform.

### Three OPFS VFSes, three prices

| VFS            | Since  | Locking                                                 | Needs `SharedArrayBuffer` | Concurrency                     | Filename transparency                |
| -------------- | ------ | ------------------------------------------------------- | ------------------------- | ------------------------------- | ------------------------------------ |
| `opfs`         | 2022   | bespoke `Atomics.wait`/`notify` over a SAB              | **yes** (COOP + COEP)     | multi-tab, `SQLITE_BUSY`-driven | 1:1 — client path _is_ the OPFS path |
| `opfs-wl`      | 3.53.0 | [Web Locks][fs-spec], FIFO; needs `Atomics.waitAsync()` | **yes**                   | same as `opfs`, fairer          | same as `opfs`                       |
| `opfs-sahpool` | 3.43   | none — `xLock` is bookkeeping that always returns 0     | **no**                    | **single connection**           | **none** — opaque pooled files       |

`opfs-sahpool` is the interesting one, because it falsifies the tidy version of this page's own argument. It pre-acquires a fixed pool of sync access handles at initialisation, holds them for the process lifetime, and therefore never needs to `await` anything inside a VFS method — so it needs no second Worker, no `SharedArrayBuffer`, and no COOP/COEP headers. Its `xLock` is the honest expression of what it gave up:

```js
xLock: function(pFile,lockType){
  const pool = getPoolForPFile(pFile);
  const file = pool.getOFileForS3File(pFile);
  file.lockType = lockType;   /* record it; there is nothing to lock */
  return 0;
},
```

The five-state ladder collapses to a field assignment, which is _correct_ — the pool already holds the file exclusively, so every lock SQLite could ask for is already held — and it is why the official guidance is a straight trade: "clients which value performance more than concurrency, or are unable to set the COOP/COEP response headers, should use the `opfs-sahpool` VFS. Clients which requires multi-tab concurrency should use either the `opfs` VFS or `opfs-wl` VFS" ([Persistent Storage Options][persistence]).

### The admission price, and why it is the browser's `pledge`/`unveil`

`SharedArrayBuffer` is gated on **cross-origin isolation**, and the docs name the exact headers:

> _"JavaScript's `SharedArrayBuffer` type is required for the OPFS VFS, and that class is only available if the web server includes the so-called COOP and COEP response headers when delivering scripts:_
> `Cross-Origin-Embedder-Policy: require-corp`
> `Cross-Origin-Opener-Policy: same-origin`
> _Without these headers, the `SharedArrayBuffer` will not be available, so the OPFS VFS will not load."_

Three further constraints ride along. WebAssembly cannot be loaded from `file://` at all — [`ext/wasm/index.html`][wasm-index] states it as a flat prohibition: _"All of these pages must be served via an HTTP server. Browsers do not support loading WASM files via file:// URLs."_ OPFS itself is `[SecureContext]` and Worker-only. And emitting the headers requires a server you control: the docs list Apache's `Header always append`, Cloudflare Pages' `_headers`, and SQLite's own [`althttpd -enable-sab`][althttpd] as the three worked examples.

That combination is worth naming precisely, because it is the structural analogue of the sandboxing primitives in [the threat-model page][threat]. `COOP: same-origin` severs the browsing-context group — no cross-origin opener, no `window.opener` back-reference. `COEP: require-corp` requires every subresource to opt in to being embedded. Together they buy back the shared-memory primitive that Spectre took away, by proving the process contains nothing cross-origin worth reading. That is the same bargain `pledge(2)` and `unveil(2)` strike: **a capability is restored in exchange for a verifiable narrowing of what else the principal can reach**, enforced by the substrate rather than by the application, and paid for in deployment constraints rather than in code. The differences are instructive too — `pledge` narrows _syscalls_ and `unveil` narrows _paths_, both irrevocably and both self-imposed by the running program; COOP/COEP narrow _embedding_ and _opener_ relationships, are imposed by the server on the document, and are checked at navigation rather than at each call. But the trade has the same shape, and `opfs-sahpool` is the proof that it is a trade and not a tax: give up concurrency, keep your deployment.

> [!NOTE]
> Cross-origin isolation is not required for SQLite in the browser generally. It is required for _one_ VFS, because that VFS uses shared memory to fake synchrony. Two of the five substrates below need no headers at all.

---

## Format identity and multiplicity

**Multiplicity = 1.** A VFS is not a byte stream, so the axis applies to it only through what it does to the artifact underneath, and the answer there is "usually nothing at all, deliberately."

The `opfs` and `opfs-wl` VFSes map client filenames onto OPFS paths one-for-one (`getDirForFilename()` walks the path components, creating leading directories when the `create` flag is set), and write the pager's page images through unmodified. What lands in OPFS is therefore _the database file_, byte for byte. That is the property the identity test exercises.

### The identity test

The outline's test is: pull the file out of OPFS and open it in a desktop SQLite viewer. The official documentation supplies both the tooling and the reason it is needed —

> _"For SQLite's purposes, the OPFS API is an internal implementation detail which is not exposed directly to client code. This means, for example, that the SQLite API cannot be used to traverse the list of files stored in OPFS, nor to delete a database file. … The OPFS Explorer extension for Chromium-based browsers provides an interactive tree of OPFS-hosted files for a given HTTP origin."_

— and the [WHATWG spec][fs-spec] is careful to promise nothing about what the extraction will find on disk:

> _"While user agents will typically implement this by persisting the contents of a bucket file system to disk, it is not intended that the contents are easily user accessible. Similarly there is no expectation that files or directories with names matching the names of children of a bucket file system exist."_

So the test is a claim about the _bytes the VFS wrote_, not about the browser's storage layout, and it passes for the reason that matters: a database written by `sqlite3.wasm` through the `opfs` VFS is a `SQLite format 3` file, opens in `sqlite3(1)`, and reports the same `sqlite_schema`. The inbound direction is the same operation in reverse and is a supported API — `opfsUtil.importDb(filename, bytes)` in [`opfs-common-shared.c-pp.js`][opfs-shared] `affirmIsDb()`s the input, writes it verbatim at offset 0, and refuses anything whose length is not a positive multiple of 512. The outbound direction has an in-library equivalent in `sqlite3_js_db_export()`, which serialises the connection to a `Uint8Array` a page at a time.

This is [thesis 2][concepts] — self-description is what makes a format survivable — demonstrated rather than argued, and it is the sharpest available demonstration because the two runtimes share no code whatsoever: one is a JavaScript VFS calling browser APIs inside a Worker, the other is `os_unix.c` calling `pread(2)`. The only thing they agree on is the 100-byte header and the b-tree.

### Where the identity breaks, and what that reveals

Two of the five substrates break it, and each break is informative.

- **`opfs-sahpool` breaks the _name_ and the _offset_.** It allocates a pool of randomly-named files under a `.opaque` directory and stores the client's logical path in a 4096-byte private header at the front of each one — 512 bytes of path, four bytes of flags, an eight-byte digest — with the database body starting at `HEADER_OFFSET_DATA = SECTOR_SIZE` (4096). Every `xRead` and `xWrite` adds that constant. The docs call this out as a disadvantage in the plainest terms: _"No filesystem transparency, i.e. names clients assign their databases are different than the names this VFS stores them under and the VFS manages a sort of virtual filesystem."_ Pulling such a file out and opening it in a desktop viewer fails on the first four bytes. The VFS therefore ships `exportFile(name)` and `importDb(name, bytes)` to restore the identity explicitly — an admission that the property is worth paying for.
- **`kvvfs` breaks the _encoding_.** [`src/os_kv.c`][os-kv] stores each database page as a separate `localStorage`/`sessionStorage` entry, hex-encoding every non-zero byte and run-length-encoding zero runs as little-endian base-26 (`"b"` = one zero, `"c"` = two, `"z"` = 25, `"ab"` = 26). There is no file at all; the "artifact" is a set of string keys. Round-tripping requires `VACUUM INTO 'file:local?vfs=kvvfs'` in one direction and a serialise in the other.

The generalisation is a small taxonomy the catalog can reuse: a substrate is **byte-transparent** (`unix`, `opfs`, `opfs-wl`, `memdb` under `sqlite3_serialize`), **offset-shifted** (`opfs-sahpool`, `appendvfs`), or **re-encoded** (`kvvfs`). Only the first preserves the artifact's identity for free; the second preserves it under a known affine transform; the third does not preserve it at all.

### The `appendvfs` proof

The strongest evidence for thesis 5 in the whole source tree is a 900-line shim that ships in `ext/misc`. [`appendvfs.c`][appendvfs] makes a SQLite database **prefix-tolerant** — legal to place arbitrary bytes before it — without touching one byte of the format:

> _"This file implements a VFS shim that allows an SQLite database to be appended onto the end of some other file, such as an executable. A special record must appear at the end of the file that identifies the file as an appended database and provides the offset to the first page of the exposed content."_

The record is 25 bytes: `Start-Of-SQLite3-` followed by a big-endian 64-bit offset to page 1, and the database is aligned up to a 4096-byte boundary (`APND_ROUNDUP`). `xRead` and `xWrite` add `iPgOne`; `xFileSize` returns `iMark - iPgOne`. Identification is a five-rule decision procedure applied in order — empty file → ordinary database; trailing append-mark → appended database; leading `SQLite format 3` → ordinary database; `SQLITE_OPEN_CREATE` → append a new one; otherwise `SQLITE_CANTOPEN`. The CLI exposes it as `sqlite3 --append`, and it is the mechanism behind self-contained [SQLAR][sqlar] archives stapled to a program.

Read against [the concepts page's tolerance rule][concepts], this is the same structural move as [ZIP's `EOCD`][zip]: a footer that names its own extent makes the front of the file free. The difference — and it is the point of this page — is that ZIP's footer is _in the format_ and every ZIP reader on earth implements the backward scan, whereas SQLite's is _in a swappable access layer_ and the format still believes its header sits at offset 0. By the [multiplicity taxonomy][concepts] the result is a **chimera**, not a polyglot: prefix file, padding, database and append-mark occupy disjoint regions, and the scan that discriminates them is the VFS's, not a second parser's. Multiplicity supplied by the substrate is cheaper than multiplicity welded into the bytes, and it is revocable — drop the shim and the file is inert rather than mis-parsed.

---

## Index anchoring and random access

The VFS holds no index. SQLite's remains where [the format][fileformat] puts it: a 100-byte header at offset 0, page 1 as the root of `sqlite_schema`, everything else reached by descending b-trees. What the VFS changes is the _cost model_ of a page read, and that is what makes remote consumption possible.

Because the pager only ever asks for one page-sized range at a time, a substrate whose unit is "a range of bytes fetched over a network" fits without any adaptation. The canonical demonstration is [`sql.js-httpvfs`][httpvfs-repo], and it produces the numbers this catalog wants. From [`databench.txt`][httpvfs-bench], one query (`select * from videoData where author = 'Adam Ragusea' limit 20`) against a large hosted database:

| Database page size | Request size | Index on `author`? | Bytes fetched | Requests |
| -----------------: | -----------: | ------------------ | ------------: | -------: |
|               4096 |         4096 | no                 |       581,490 |      142 |
|               4096 |          512 | no                 |       580,496 |    1,136 |
|              32768 |        32768 | no                 |       622,573 |       19 |
|                512 |          512 | **yes**            |    **24,017** |   **47** |
|               4096 |         4096 | **yes**            |        98,280 |       24 |
|              16384 |        16384 | **yes**            |       327,660 |       20 |

Two facts fall out. **Random access over HTTP is real** — an indexed lookup costs 24 KiB and 47 requests against a database of many megabytes — and **the page size becomes a network tuning parameter**, trading bytes against round trips along a curve that has no analogue on a local disk. The project's setup instructions accordingly begin `pragma page_size = 1024; … vacuum;`, which is a _format_ decision made for a _substrate_ reason.

> [!WARNING]
> **`sql.js-httpvfs` is not an `sqlite3_vfs`,** despite being universally described as one (this catalog's own source outline included). It is an Emscripten filesystem backend: `createLazyFile()` in [`src/lazyFile.ts`][httpvfs-lazyfile] installs custom `stream_ops` on an Emscripten `FS` node, and SQLite reaches it through the ordinary `unix` VFS's `read(2)` calls into Emscripten's POSIX emulation. The README says so and names the missing work: _"It might also be useful to implement this lazy fetching as an SQLite VFS since then SQLite could be compiled with e.g. WASI SDK without relying on all the emscripten OS emulation."_ The correction matters for this page's thesis, not against it: the demonstration works _one layer higher_ than the seam, which is why it also inherits Emscripten's whole POSIX emulation. A real range-request VFS would be about 200 lines and would drop that dependency. See [range-request access][range] for the pattern in general.

Two further anchoring facts belong here. `appendvfs` adds a **footer** below an unmodified header-anchored format, as above. And the memory-mapping seam — `xFetch`/`xUnfetch`, the `iVersion = 3` methods — is the one place a VFS can hand SQLite a _pointer_ instead of a copy: `unixFetch()` returns `&pMapRegion[iOff]` out of an `mmap`, and `memdbFetch()` returns `p->aData + iOfst` straight out of the heap. Both OPFS VFSes decline it (`iVersion = 1`), because OPFS has no mapping primitive. This is where [thesis 4][concepts] bites the substrate story directly: portability migrated to the access layer, but _demand paging did not migrate with it_.

---

## Reflexivity and query surface

**Reflexivity = 2.** The VFS is not itself queryable — but it is the layer at which SQLite's query surface can be pointed at the access layer, and two shipped shims do exactly that.

[`ext/misc/vfsstat.c`][vfsstat-src] is a VFS shim that counts calls and exposes the counters as an **eponymous virtual table** in the database it is serving:

> _"This file contains the implementation of an SQLite vfs shim that tracks I/O. Access to the accumulated status counts is provided using an eponymous virtual table. … Query usages status using the vfsstat virtual table: `SELECT * FROM vfsstat;` Reset counters using UPDATE statements against vfsstat: `UPDATE vfsstat SET count=0;`"_

That is a genuinely reflexive arrangement and it is the substrate analogue of what [`sqlelf`][sqlelf] does to ELF: the mechanism that reads the artifact becomes a relation _inside_ the artifact's own query language, and `UPDATE` on it is a control operation. [`vfstrace.c`][vfstrace-src] is the logging counterpart. `SQLITE_FCNTL_VFSNAME` (via [`sqlite3_file_control()`][file-control]) lets a connection ask which VFS stack it is actually running on, which is how a shim chain becomes introspectable; [`sqlite3_vfs_find()`][vfs-find] enumerates registrations by name, and the WASM build wraps it as `sqlite3.capi.sqlite3_vfs_find("opfs")` — the documented feature test for whether OPFS is available at all.

What is _not_ available is the inverse: the SQLite API cannot enumerate OPFS, because the enumeration APIs are asynchronous. The docs consider and reject the obvious fix —

> _"Though it may initially seem feasible to provide a virtual table which provides a list of OPFS-hosted files, and the ability to delete them, that cannot work because the relevant OPFS APIs are all asynchronous, making them impossible to use together with the C-level SQLite APIs."_

— which is the same synchrony constraint that produced the Worker, showing up a second time as a limit on reflexivity. A substrate that cannot be queried synchronously cannot be queried through SQL at all, no matter how relational its contents are. That is a real, if narrow, counterweight to [code-as-a-database][code-db]'s general optimism: the query surface is only as reachable as the substrate's calling convention allows.

---

## Closure, dedup, and size model

**Closure = 0**, and the reason is definitional rather than a shortcoming: a VFS is an interface, not an artifact, and it carries nothing. The section is still worth keeping, because the _substrate_ determines the size model of everything above it, in three measurable ways.

- **Encoding overhead.** `kvvfs` hex-encodes: two ASCII characters per non-zero byte, so a page of dense data roughly doubles, offset by base-26 run-length compression of zero runs (a freshly-`VACUUM`ed page of a sparse table can be much smaller than its 4096 bytes). This is the only substrate with a size model that differs from the database's own.
- **Preallocated capacity.** `opfs-sahpool` is a fixed-size pool of files, sized at install time and grown explicitly. Storage is therefore claimed up front rather than on demand, and the VFS's `.opaque` directory holds capacity, not content.
- **Chunking for the network.** `sql.js-httpvfs` ships [`create_db.sh`][httpvfs-repo] to split a database into fixed-size chunks, for hosts with an upload cap and — more interestingly — for CDN cache granularity: _"it allows selective CDN caching of the chunks your users actually use and reduces cache eviction."_ That is content-level dedup arriving from the substrate side, and it is the same idea [content-addressed chunking][chunking] develops for closures.

The catalog's [container-tax thesis][concepts] shows up here in an unexpected form. `appendvfs` is a container tax of exactly 25 bytes plus up to 4095 bytes of alignment padding — the entire cost of making a database prefix-tolerant. Compare [ZIP's central directory][zip], which duplicates every entry's metadata, or [redbean's][ape] `zipos` layer. When the substrate provides the composition, the tax collapses to a footer.

---

## Mutability, dispatch, and trust

**Mutability = 2.** The VFS is where SQLite's transactional guarantees meet the world: `xWrite` for durability of content, `xSync` for durability of ordering, the `xLock` ladder for isolation, and `xDeviceCharacteristics` for what the substrate is willing to promise. Every ACID property SQLite claims is a claim about what these five methods do, which is why a wrong `SQLITE_IOCAP_*` bit is a corruption bug and not a performance bug.

**Dispatch owner: the consumer.** This is the sharpest contrast in the catalog. [`binfmt_misc`][binfmt] decides what a file is by matching magic bytes in the kernel, before anything runs, for every process on the machine, and registration requires root. A VFS is chosen by name, in-process, at `sqlite3_open_v2()` time or in a `file:my.db?vfs=opfs` URI, by the application itself, with no privilege at all — and a different connection in the same process may choose differently. Where `binfmt_misc` is _ambient and global_, VFS selection is _explicit and local_. That is the whole reason a substrate strategy scales: adding a target does not require convincing an operating system of anything.

The trust surface follows from that locality, and it has three distinct parts.

**The substrate is a trust boundary the format cannot police.** `cksumvfs` exists because the format has no integrity check: it commandeers the [reserved-bytes region at the tail of each page][fileformat] to store a checksum, verifies it on every `xRead`, and reports mismatches. Note where this had to be implemented — _below_ the format, in a shim — and note the cost: reserved bytes are per-page and capped at 255, exactly the constraint that [defeats the segment-`mmap` proposals in the SELF deep-dive][self]. The reserved region is a trust channel, not a storage channel.

**The browser substrate enforces least privilege the format never asked for.** `[SecureContext]`, Worker-only, `NoModificationAllowedError` on lock contention, no `file://`, and the COOP/COEP bargain described above. A `.sqlite` file in OPFS is confined to one HTTP origin by construction, and there is no `chmod` that widens it. That is genuinely stronger isolation than the same database gets on a desktop filesystem, and it is enforced below the application — which is precisely the [least-privilege decomposition the catalog asks for][threat] and does not get on Linux. The corollary is uncomfortable and worth stating: _the browser has the enforcement mechanism the self-mutating-executable design needs, and Linux does not._

**Nothing here signs anything.** The VFS layer has no notion of a measured artifact. `xWrite` cannot know that a page belongs to an immutable table, [`VACUUM`][vacuum] rewrites the whole file below any signature, and a shim that computed a Merkle root per table would have to reconstruct page semantics the interface deliberately hides. [Embedded provenance][provenance] owns the problem; the finding this page contributes is that the seam is at the wrong altitude to solve it — the same conclusion, from the opposite direction, as the `mmap` case.

One further trust-relevant detail is a beautiful small violation of the layering. Both OPFS import paths write two bytes into the format header before releasing the file:

```js
sah.write(new Uint8Array([1, 1]), { at: 18 }) /* force db out of WAL mode */;
```

Offsets 18 and 19 are the file-format _write_ and _read_ version bytes — `1` meaning legacy rollback journal, `2` meaning WAL ([`src/btree.c`][btree] sets both in `sqlite3BtreeSetVersion`). The substrate reaches _up_ into the format and rewrites it, because [WAL][wal] needs shared memory (`xShmMap`) and the WASM build has none. WAL is available on OPFS only from 3.47 and only under `pragma locking_mode=exclusive`, which — the docs say flatly — "eliminates all concurrency support from the `opfs` VFS." So the honest version of thesis 5 is not that the format is untouched by the substrate. It is that the substrate's demands on the format are **two bytes and one journalling mode**, against APE's six simultaneous loader parses. That is the size of the difference the thesis is about.

---

## Open question: the smallest browser-side `self-exec`

A [SELF][self] binary inherits every VFS SQLite has, for free. `sqlite3_open_v2(path, &db, flags, "opfs")` is the same call as `sqlite3_open_v2(path, &db, flags, NULL)`; "execute this program out of OPFS", "out of a range-requested URL", "out of an appended blob at the end of another file" are the same program with a different string. So: what is the smallest browser-side `self-exec`?

**The sketch.** A dedicated Worker, cross-origin-isolated so the `opfs` VFS installs. It opens the `.self` database, runs one query, and instantiates the result:

```js
const db = new sqlite3.oo1.OpfsDb('/app.self'); // or ?vfs=opfs-sahpool
const [id] = db.selectValue('PRAGMA application_id'); // 0x53454C46 == 'SELF'
const wasmBytes = db.selectValue(
  "SELECT content FROM segments WHERE type='PT_LOAD' ORDER BY vaddr LIMIT 1",
);
const { instance } = await WebAssembly.instantiate(wasmBytes, imports);
instance.exports._start();
```

That is the whole loader. The Wasm module lives **in** the database; the module loader plays the role [`binfmt_misc`][binfmt] plays on Linux — it decides what the bytes are, and here that decision is `PRAGMA application_id` rather than a masked `memcmp` in kernel space — and the artifact is browser-native with no kernel involvement at all. Three of the four axes come out well: reflexivity is unchanged (the running program can `SELECT` from the file it was loaded from, via the same connection, without the [`argv[0]` fragility][self] because there is no `argv`), mutability is unchanged (`INSERT` into a `visits` table is a transaction on the same file), and dispatch has moved from the kernel to the consumer, where a substrate strategy wants it.

**What does not work, concretely.**

- **No relocations, and that is fine.** [`DynamicLinking.md`][wasm-dl] is explicit: _"WebAssembly dynamic libraries do not require relocations in the code section. This allows for streaming compilation and better code sharing, and reduces the complexity of the dynamic linker."_ Addresses are indices in index spaces, not numbers in a code stream, so there is nothing for a [relocation join][self] to resolve. The `R_WASM_MEMORY_ADDR_REL_SLEB` / `R_WASM_TABLE_INDEX_REL_SLEB` types exist only for `-fPIC` data references relative to imported `__memory_base` / `__table_base` globals, and even then the loader supplies the bases as imports rather than patching bytes. **The relational reformulation of linking that makes SELF interesting has no subject here.** The interesting relational questions move up a level, to [the component model's typed import/export graph][wasm-cm].
- **No `dlopen`.** Wasm's dynamic linking is a custom `dylink.0` section with a `WASM_DYLINK_NEEDED` list, a work in progress by its own admission (_"This ABI is still a work in progress. There is no stable ABI yet."_), implemented by Emscripten's JS loader rather than by the engine. There is no `LD_PRELOAD` to demote to a table, no `RUNPATH` to `UPDATE`, and no in-engine symbol interposition to model. A `needed` table in the database could drive a JS loader — which would be a real and attractive experiment, and would look much more like [the component model's declarative instantiation graph][wasm-cm] than like [`ld.so`][dynlink].
- **The memory model forbids the thing thesis 4 cares about.** A Wasm instance's linear memory is a `WebAssembly.Memory`, an engine-owned buffer that cannot be backed by a file. There is no `mmap`, no demand paging, no copy-on-write, and no cross-instance sharing except through an explicitly `shared` memory — which requires `SharedArrayBuffer` and therefore drags cross-origin isolation back in even for the `opfs-sahpool` path. Every instantiation copies the module bytes out of the b-tree into engine memory, which is [exactly the cost `native.c` pays on Linux][self], with no browser-side equivalent of the page-aligned-trailer fix because there is nothing to map onto. Code sharing between instances is possible — `WebAssembly.Module` objects are structured-cloneable and engines cache compiled code — but it is sharing of _compiled code_, arranged by the engine, not sharing of _file pages_, arranged by the kernel.
- **`WebAssembly.instantiateStreaming` cannot be used**, because its input is a `Response`, and the bytes are coming from a b-tree rather than from the network. The streaming-compilation advantage that Wasm's relocation-free design was built to enable is precisely what putting the module in a database gives up. A range-request VFS would get it back only by inverting the arrangement — fetching the module _as_ a `Response` and keeping only metadata in the database.

**What the experiment would actually settle.** Not whether it runs — it plainly does — but the size of the constant. A browser `self-exec` must ship `sqlite3.wasm` _plus_ the program, so it pays a loader-larger-than-the-program tax that the Linux version does not, on every cold load; the exact figure is build-dependent and is **not measured here or in any surveyed source**, and it belongs to [the measurement page][measure] alongside SELF's `~5 ms` decomposition. Against that, the whole [`memfd` / `execve` / `binfmt_misc` / `argv[0]` apparatus][binfmt] disappears, and so does the requirement for root. The honest framing is that the browser version trades a large fixed cost for the removal of every privileged step — which is the same trade the substrate strategy makes everywhere else in this page.

---

## Strengths

- **The interface is small enough to be re-implemented and stable enough to have been worth it.** Seventeen `sqlite3_vfs` slots and eighteen `sqlite3_io_methods` slots, `iVersion`-extended twice in nineteen years, with the second extension (`xFetch`) optional. Three new substrates reached production in four years without a format change.
- **Selection is per-connection, unprivileged, and composable.** A URI parameter picks the substrate; shims stack; `ATTACH`ed databases may use different ones. Compare the privilege and blast radius of a [`binfmt_misc`][binfmt] registration.
- **The artifact survives transport between runtimes that share no code.** A database written by a JavaScript VFS in a Worker opens in `sqlite3(1)`. This is the catalog's cleanest demonstration of [thesis 2][concepts].
- **Multiplicity becomes purchasable and revocable.** `appendvfs` makes the format prefix-tolerant for 25 bytes plus alignment, at the access layer, with no reader on earth needing to be taught anything.
- **The substrate is a place to add integrity and observability.** `cksumvfs` (per-page checksums), `vfsstat` (I/O counters as a virtual table), `vfstrace` (call logging) — all as shims, none touching the format or the application.
- **The escape hatch is honest.** `opfs-sahpool` demonstrates that the COOP/COEP admission price buys _concurrency specifically_, and that an application willing to give up concurrency can decline it. A layer that lets you see and pay the price separately is a well-drawn layer.

## Weaknesses

- **Synchrony is non-negotiable and it deforms everything above.** No `sqlite3_vfs` method may await. That single constraint produces the second Worker, the two `SharedArrayBuffer`s, the `Atomics.wait()` spin loop, the cross-origin-isolation requirement, the Worker1 message API, the promiser, and the impossibility of an `opfs_files` virtual table.
- **The seam is below page structure, so the problems the catalog most cares about are out of reach.** Overflow chains, page-aligned segment `mmap`, and per-table Merkle roots all require knowing what a page _means_. A VFS never does.
- **`mmap` did not migrate with portability.** `xFetch` is optional and both OPFS VFSes decline it. Demand paging and cross-process sharing are properties of substrates that happen to be filesystems, not properties of the seam. [Thesis 4][concepts] survives thesis 5 intact.
- **The substrate reaches up into the format anyway.** Bytes 18–19 are rewritten on OPFS import to force the database out of WAL mode, because the WASM build has no `xShmMap`. The abstraction is very good, not perfect.
- **Concurrency in the browser is a different regime, not a slower one.** OPFS sync handles are exclusive, so "there's no such thing as 'N concurrent readers' in OPFS-via-VFS." The documented working range is 8–10 workers _provided the client handles `SQLITE_BUSY`_, after a long period of the docs suggesting three.
- **Two of the five substrates break byte identity**, and one of them (`kvvfs`) breaks it irrecoverably without an explicit export step.
- **The best-known "SQLite VFS over HTTP" is not one.** `sql.js-httpvfs` is an Emscripten `FS` backend; the real thing has not been written, which leaves this catalog's most-cited demonstration of thesis 5 sitting one layer above the seam it is meant to demonstrate.

---

## Key design decisions and trade-offs

| Decision                                                      | Rationale                                                                                                          | Trade-off                                                                                                                                  |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------ |
| All OS access behind two vtables of function pointers         | Porting is "simply a matter of writing a new OS interface layer"; the format never changes                         | Every substrate must satisfy the _whole_ contract, including guarantees (zero-fill, lock ladder, `IOCAP` honesty) it may not natively have |
| Every VFS method is synchronous                               | Keeps the pager, b-tree and VM straight-line C with no continuations                                               | An asynchronous substrate must be faked with a second thread and shared memory — the entire browser architecture                           |
| The seam sits **below** page structure                        | A VFS is trivially simple; page format evolution never breaks a substrate                                          | Page-aware substrates (blob `mmap`, per-table integrity, extent relocation) are structurally impossible                                    |
| `iVersion` on both structs; `xShmMap`/`xFetch` optional       | A substrate declares what it cannot do instead of failing at it; WAL and mmap degrade rather than break            | "No WAL in the browser" is expressed as a version number, so the limitation is invisible until a `PRAGMA` behaves oddly                    |
| VFS chosen by name, per connection, unprivileged              | No registration, no root, no global state; shims compose; `ATTACH` can mix substrates                              | Nothing external can _impose_ a substrate — no policy layer, no kernel-side enforcement, no equivalent of `binfmt_misc`                    |
| `opfs`: fake synchrony with a Worker + `SharedArrayBuffer`    | Preserves multi-tab concurrency and 1:1 filename transparency, so the OPFS file _is_ the database                  | Requires COOP `same-origin` + COEP `require-corp`, an HTTPS server you control, and no `file://` — the admission price                     |
| `opfs-sahpool`: pre-acquire a fixed pool of exclusive handles | No second Worker, no `SharedArrayBuffer`, no COOP/COEP; "easily the highest OPFS performance"                      | One connection per origin-directory, and a 4096-byte private header that destroys byte identity                                            |
| `appendvfs`: a 25-byte footer plus 4 KiB alignment, in a shim | Prefix-tolerance — a database appended to an executable — with zero format change and zero reader changes          | 1 GiB size cap; the composition exists only where the shim is loaded, so the file is inert rather than portable elsewhere                  |
| `cksumvfs`: integrity in the per-page reserved region         | Adds a checksum the format never had, below the format, invisibly to applications                                  | Capped at 255 bytes per page and scattered; the same constraint that rules out storing segments there                                      |
| OPFS import rewrites header bytes 18–19                       | The WASM build has no shared memory, so WAL cannot work; forcing rollback-journal mode fails safe rather than late | The substrate mutates the format it claims not to know about — a small, real leak in the abstraction                                       |

---

## Sources

- [The SQLite OS Interface or "VFS"][vfs-doc] — the layering diagram, the portability claim, multiple simultaneous VFSes, the `unix-*` family and their incompatible locking
- [`sqlite3_vfs`][c3-vfs] · [`sqlite3_io_methods`][c3-io] · [`sqlite3_vfs_find()`][vfs-find] · [`sqlite3_file_control()`][file-control] · [`SQLITE_IOCAP_*`][iocap] · [File locking and concurrency][lockingv3]
- [`src/sqlite.h.in`][sqlite-h] — the two structs, the `xOpen` contract, the zero-fill-short-reads requirement, the `iVersion` rules (read at `8a988271`)
- [`src/os_unix.c`][os-unix] — `unixRead` over `pread(2)`, `unixFetch` returning a pointer into the `mmap`; [`src/memdb.c`][memdb] — `memdbFetch` returning a heap pointer; [`src/os_kv.c`][os-kv] — `kvvfsEncode`'s hex + base-26 zero-run encoding
- [`ext/misc/appendvfs.c`][appendvfs] — the `Start-Of-SQLite3-NNNNNNNN` trailer, the five identification rules, `APND_ROUNDUP`, the 1 GiB cap; [`src/shell.c.in`][shell] — `sqlite3 --append`
- [`ext/misc/cksumvfs.c`][cksumvfs-src] and [cksumvfs documentation][cksumvfs] — per-page checksums in the reserved region
- [`ext/misc/vfsstat.c`][vfsstat-src] — a VFS shim whose counters are an eponymous virtual table; [`ext/misc/vfstrace.c`][vfstrace-src]
- [`ext/wasm/api/opfs-common-shared.c-pp.js`][opfs-shared] — the SAB slot table, `opRun`'s `Atomics.wait` loop, the 64 KiB I/O block, `importDb`, the WAL-disabling header write
- [`ext/wasm/api/sqlite3-opfs-async-proxy.c-pp.js`][opfs-proxy] — `getSyncHandle`'s retry loop, `sah.read`/`flush`, `NoModificationAllowedError` handling
- [`ext/wasm/api/sqlite3-vfs-opfs.c-pp.js`][opfs-vfs] (the `xLock`/`xUnlock` half) · [`sqlite3-vfs-opfs-wl.c-pp.js`][opfs-wl] (Web Locks) · [`sqlite3-vfs-opfs-sahpool.c-pp.js`][sahpool] (the pool, the 4096-byte header, the no-op `xLock`) · [`sqlite3-vfs-kvvfs.c-pp.js`][kvvfs-js]
- [`ext/wasm/api/sqlite3-worker1-promiser.c-pp.js`][promiser] and [`sqlite3-api-worker1.c-pp.js`][worker1] — the Promise proxy the synchronous VFS forces into existence
- [`ext/wasm/GNUmakefile`][wasm-mk] — `-DSQLITE_DEFAULT_UNIX_VFS="unix-none"`, `-DSQLITE_OS_KV_OPTIONAL=1`, `-DSQLITE_THREADSAFE=0`; [`ext/wasm/index.html`][wasm-index] — the `file://` prohibition and the `althttpd -enable-sab` recipe
- [Persistent Storage Options][persistence] (`sqlite.org/wasm`) — COOP/COEP, VFS selection guidance, concurrency guidance, the OPFS Explorer extension, WAL-with-`locking_mode=exclusive`, storage limits; [kvvfs documentation][kvvfs-doc]; [SQLite in WASM/JS][wasm-home]
- [WHATWG File System Standard][fs-spec] — `FileSystemSyncAccessHandle`, the exclusive lock, the "higher performance … e.g., WebAssembly" rationale, the bucket-file-system note about on-disk inaccessibility (read at `cd55e558`)
- [`phiresky/sql.js-httpvfs`][httpvfs-repo] — [`src/lazyFile.ts`][httpvfs-lazyfile] (an Emscripten `FS` backend, not a VFS), [`databench.txt`][httpvfs-bench] (the bytes/requests table)
- [`WebAssembly/tool-conventions` — `DynamicLinking.md`][wasm-dl] — no code-section relocations, `dylink.0`, `WASM_DYLINK_NEEDED`, "no stable ABI yet"; [WebAssembly JavaScript Interface][wasm-js-api]
- [`fzakaria/selfdb` — `DESIGN.md`][self-design] — the format whose portability bet this page evaluates
- Runnable companions in this tree: [`self-selfdb/examples/sqlite-header-probe.d`](./self-selfdb/examples/sqlite-header-probe.d) (the 100-byte header the substrate must deliver intact), [`cosmopolitan-ape/examples/zip-eocd-scan.d`](./cosmopolitan-ape/examples/zip-eocd-scan.d) (the footer scan `appendvfs` reproduces below the format)
- Related in this tree: [SELF / selfdb][self] · [redbean / Cosmopolitan / APE][ape] · [SQLite as an application file format][sqlite-app] · [ZIP parasitism][zip] · [footer-indexed formats][footer] · [range-request access][range] · [`binfmt_misc`][binfmt] · [dynamic linking][dynlink] · [the Wasm component model][wasm-cm] · [code as a database][code-db] · [sqlelf][sqlelf] · [content-addressed chunking][chunking] · [embedded provenance][provenance] · [threat model][threat] · [measurement][measure] · [concepts][concepts] · [comparison][comparison] · [umbrella][umbrella]

<!-- References -->

[repo]: https://github.com/sqlite/sqlite/tree/8a9882714dab097da40edc963d0e4226bda1ee07
[sqlite-h]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/src/sqlite.h.in
[os-unix]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/src/os_unix.c
[memdb]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/src/memdb.c
[os-kv]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/src/os_kv.c
[btree]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/src/btree.c
[shell]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/src/shell.c.in
[appendvfs]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/misc/appendvfs.c
[cksumvfs-src]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/misc/cksumvfs.c
[vfsstat-src]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/misc/vfsstat.c
[vfstrace-src]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/misc/vfstrace.c
[opfs-shared]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/api/opfs-common-shared.c-pp.js
[opfs-proxy]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/api/sqlite3-opfs-async-proxy.c-pp.js
[opfs-vfs]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/api/sqlite3-vfs-opfs.c-pp.js
[opfs-wl]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/api/sqlite3-vfs-opfs-wl.c-pp.js
[sahpool]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/api/sqlite3-vfs-opfs-sahpool.c-pp.js
[kvvfs-js]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/api/sqlite3-vfs-kvvfs.c-pp.js
[promiser]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/api/sqlite3-worker1-promiser.c-pp.js
[worker1]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/api/sqlite3-api-worker1.c-pp.js
[wasm-mk]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/GNUmakefile
[wasm-index]: https://github.com/sqlite/sqlite/blob/8a9882714dab097da40edc963d0e4226bda1ee07/ext/wasm/index.html
[fs-repo]: https://github.com/whatwg/fs/tree/cd55e5582e9c915c6341479bceaa4216f7a05413
[httpvfs-repo]: https://github.com/phiresky/sql.js-httpvfs/tree/c64536d2acc78feeac17c34bfa1895df01050129
[httpvfs-lazyfile]: https://github.com/phiresky/sql.js-httpvfs/blob/c64536d2acc78feeac17c34bfa1895df01050129/src/lazyFile.ts
[httpvfs-bench]: https://github.com/phiresky/sql.js-httpvfs/blob/c64536d2acc78feeac17c34bfa1895df01050129/databench.txt
[tc-repo]: https://github.com/WebAssembly/tool-conventions/tree/83e5d715d0c18aee51e2d5ae9434f22d67b6e905
[wasm-dl]: https://github.com/WebAssembly/tool-conventions/blob/83e5d715d0c18aee51e2d5ae9434f22d67b6e905/DynamicLinking.md
[self-design]: https://github.com/fzakaria/selfdb/blob/e63f7c470302f089a677ec87679a7df60b628547/DESIGN.md
[vfs-doc]: https://sqlite.org/vfs.html
[c3-vfs]: https://sqlite.org/c3ref/vfs.html
[c3-io]: https://sqlite.org/c3ref/io_methods.html
[vfs-find]: https://sqlite.org/c3ref/vfs_find.html
[file-control]: https://sqlite.org/c3ref/file_control.html
[iocap]: https://sqlite.org/c3ref/c_iocap_atomic.html
[lockingv3]: https://sqlite.org/lockingv3.html
[fileformat]: https://sqlite.org/fileformat2.html
[wal]: https://sqlite.org/wal.html
[vacuum]: https://sqlite.org/lang_vacuum.html
[cksumvfs]: https://sqlite.org/cksumvfs.html
[sqlar]: https://sqlite.org/sqlar.html
[althttpd]: https://sqlite.org/althttpd/doc/trunk/althttpd.md
[persistence]: https://sqlite.org/wasm/doc/trunk/persistence.md
[kvvfs-doc]: https://sqlite.org/wasm/doc/trunk/kvvfs.md
[wasm-home]: https://sqlite.org/wasm/
[fs-spec]: https://fs.spec.whatwg.org/
[wasm-js-api]: https://www.w3.org/TR/wasm-js-api-2/
[self]: ./self-selfdb/index.md
[ape]: ./cosmopolitan-ape/index.md
[sqlite-app]: ./sqlite-application-file-format.md
[zip]: ./zip-parasitism.md
[footer]: ./footer-indexed-formats.md
[range]: ./range-request-access.md
[binfmt]: ./binfmt-misc.md
[dynlink]: ./dynamic-linking.md
[wasm-cm]: ./wasm-component-model.md
[code-db]: ./code-as-database.md
[sqlelf]: ./sqlelf.md
[chunking]: ./content-addressed-chunking.md
[provenance]: ./embedded-provenance.md
[threat]: ./threat-model.md
[measure]: ./measurement.md
[concepts]: ./concepts.md
[comparison]: ./comparison.md
[umbrella]: ./index.md
