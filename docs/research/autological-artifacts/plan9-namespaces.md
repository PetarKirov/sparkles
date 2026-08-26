# Plan 9 and 9P (operating system / uniform-interface protocol)

The road not taken: make the whole system interrogable by exposing every resource as a _hierarchical namespace_ rather than as tables — one thirteen-message protocol, a per-process mount table, and no query language anywhere.

| Field           | Value                                                                                                                                                                                                       |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Kind            | Operating system + wire protocol; on Linux, a filesystem client and a set of surviving kernel facilities                                                                                                    |
| Language        | C (Plan 9 kernel, `libc`, `lib9p`) · C (Linux `net/9p` + `fs/9p`) · C++ (WSL's `p9fs` server)                                                                                                               |
| License         | MIT (Plan 9 Fourth Edition, 9front) · MIT/Lucent (plan9port) · GPL-2.0 (Linux `v9fs`) · MIT (microsoft/WSL)                                                                                                 |
| Repository      | [0intro/plan9][p9-repo] (Fourth Edition tree) · [9front/9front][9f-repo] · [9fans/plan9port][p9p-repo] · [microsoft/WSL][wsl-repo]                                                                          |
| Documentation   | Section 5 of the Programmer's Manual (`intro(5)`, `version(5)`, `walk(5)`) · [`Documentation/filesystems/9p.rst`][k9p] · [`mount_namespaces(7)`][mountns]                                                   |
| First release   | `9P2000` shipped with the [Fourth Edition][p9-rel4], April 2002 (the 1995 paper describes the system in daily use since 1989) · Linux `v9fs` merged for 2.6.14, [commit `b8cf945b`][v9fs-merge], 2005-09-09 |
| Axis profile    | Multiplicity 1 / Reflexivity 2 / Closure 0 / Mutability 1                                                                                                                                                   |
| Index anchoring | Out-of-band — there is no index and no artifact; the "index" is a live server's directory tree, resolved one path element at a time                                                                         |
| Dispatch owner  | Kernel — the per-process mount table in `chan.c`, consulted after _every_ successful walk                                                                                                                   |

> **Revisions surveyed:** Plan 9 Fourth Edition tree `0aab9506bfc2acb5203a411b917cea62cf3eeb91` · 9front `50aefa0743c8cfd83fdc7f568d24e1bba8b9848e` (2026-08-25) · plan9port `b6564bd96ca189c69e28797738dad56f91eb5967` · microsoft/WSL `8af1856f86f09aa099de169932ef95f7a88466c8` · Linux `e43ffb69e0438cddd72aaa30898b4dc446f664f8`. **Platforms:** Plan 9 / 9front natively; 9P as a client on Linux, and as a server on Windows (WSL), inside QEMU, and in userspace anywhere plan9port builds.

---

## Overview

### What it solves

Every other page in this catalog asks a version of one question: _how do you make a system interrogable through a single uniform interface?_ [`sqlelf`][sqlelf], [SELF][self], [osquery, Steampipe and Datasette][rel] all answer **relations**: declare a schema, generate rows behind it, let a planner do the joining. Plan 9 answered the same question thirteen years before osquery existed, and its answer was **a namespace**: every resource — the network stack, the window system, process control, the CPU itself — is a file tree, every file tree speaks one protocol, and every process assembles its own private view of which trees are visible where.

The two answers are not variations on a theme. They are structurally opposed, and each buys exactly what the other gives up. That comparison is why this page exists in this catalog, and it is developed in [A namespace and a relational surface answer the same question](#a-namespace-and-a-relational-surface-answer-the-same-question).

The concrete problems Plan 9 set out to solve were distribution problems, stated in the opening of [`sys/doc/9.ms`][p9-9ms]: UNIX had "trouble adapting to ideas born after it", graphics and networking "were added to UNIX well into its lifetime and remain poorly integrated and difficult to administer", and personal workstations "fractured, democratized, and ultimately amplified administrative problems". The fix chosen was to keep UNIX's best idea and take it seriously:

> _"The best was its use of the file system to coordinate naming of and access to resources, even those, such as devices, not traditionally treated as files. For Plan 9, we adopted this idea by designing a network-level protocol, called 9P, to enable machines to access files on remote systems."_ — [`sys/doc/9.ms`][p9-9ms]

### Design philosophy

The system rests on exactly three claims, stated as such in the same paper:

> _"The view of the system is built upon three principles. First, resources are named and accessed like files in a hierarchical file system. Second, there is a standard protocol, called 9P, for accessing these resources. Third, the disjoint hierarchies provided by different services are joined together into a single private hierarchical file name space. The unusual properties of Plan 9 stem from the consistent, aggressive application of these principles."_ — [`sys/doc/9.ms`][p9-9ms]

And the consequence, from the same paper's discussion section, is the sentence that most compactly states what kind of system this is:

> _"The best example is 9P, which centralizes naming, access, and authentication. 9P is really the core of the system; it is fair to say that the Plan 9 kernel is primarily a 9P multiplexer."_ — [`sys/doc/9.ms`][p9-9ms]

Two further commitments, both explicit, matter for this catalog because they mark the boundaries the designers refused to cross.

The first is **anti-extensibility**, stated as a _distinction from_ object orientation:

> _"First, 9P defines a fixed set of `methods'; it is not an extensible protocol. More important, files are well-defined and well-understood and come prepackaged with familiar methods of access, protection, naming, and networking. Objects, despite their generality, do not come with these attributes defined. By reducing `object' to `file', Plan 9 gets some technology for free."_ — [`sys/doc/9.ms`][p9-9ms]

The second is **restraint about the metaphor** — a warning against exactly the over-reach that the "everything is a file" slogan invites:

> _"Nonetheless, it is possible to push the idea of file-based computing too far. Converting every resource in the system into a file system is a kind of metaphor, and metaphors can be abused. A good example of restraint is `/proc`, which is only a view of a process, not a representation."_ — [`sys/doc/9.ms`][p9-9ms]

That is a sharper self-assessment than any of the relational systems in this tree offer about themselves, and [The Use of Name Spaces in Plan 9][p9-names] names the specific things that were left out: process creation, network addressing, and shared memory, each because "the details … are too intricate to be described easily in a simple I/O operation."

---

## How it works

### The protocol, in full

The smallness _is_ the argument, so here is the whole thing. `9P2000` defines **thirteen request types**, each paired with a reply one greater in the type byte, plus `Rerror` (there is no `Terror`; type 106 is reserved and illegal). The enumeration is in [`sys/include/fcall.h`][p9-fcall], and each message has a one-page manual entry in section 5 — thirteen pages is the complete specification.

| T-message  | Arguments (after `size[4] type[1] tag[2]`)     | Reply carries       | What it does                                                          |
| ---------- | ---------------------------------------------- | ------------------- | --------------------------------------------------------------------- |
| `Tversion` | `msize[4] version[s]`                          | `msize version`     | Negotiate protocol level and maximum message size; resets the session |
| `Tauth`    | `afid[4] uname[s] aname[s]`                    | `aqid[13]`          | Establish an authentication fid, then read/write it as a file         |
| `Tattach`  | `fid[4] afid[4] uname[s] aname[s]`             | `qid[13]`           | Bind a fid to the root of a served tree, as a named user              |
| `Tflush`   | `oldtag[2]`                                    | —                   | Abandon an outstanding request                                        |
| `Twalk`    | `fid[4] newfid[4] nwname[2] nwname*(wname[s])` | `nwqid*(qid[13])`   | Descend up to 16 path elements, producing a new fid                   |
| `Topen`    | `fid[4] mode[1]`                               | `qid[13] iounit[4]` | Check permissions and prepare a fid for I/O                           |
| `Tcreate`  | `fid[4] name[s] perm[4] mode[1]`               | `qid[13] iounit[4]` | Create a file in the fid's directory and open it                      |
| `Tread`    | `fid[4] offset[8] count[4]`                    | `count[4] data[…]`  | Read bytes at a 64-bit offset                                         |
| `Twrite`   | `fid[4] offset[8] count[4] data[…]`            | `count[4]`          | Write bytes at a 64-bit offset                                        |
| `Tclunk`   | `fid[4]`                                       | —                   | Forget a fid                                                          |
| `Tremove`  | `fid[4]`                                       | —                   | Delete the file and forget the fid                                    |
| `Tstat`    | `fid[4]`                                       | `stat[n]`           | Read the file's metadata record                                       |
| `Twstat`   | `fid[4] stat[n]`                               | —                   | Write (some of) the file's metadata                                   |

Three identifiers carry the whole state model, and each is worth naming precisely because the relational systems in this tree have no equivalent for any of them:

- A **`tag`** is a 16-bit request identifier chosen by the client. Multiple requests may be outstanding; replies may arrive out of order. `NOTAG` (`(ushort)~0`) is reserved for `version`.
- A **`fid`** is a 32-bit client-chosen handle for a "current file" on the server. Per [`intro(5)`][p9p-intro], _"Fids are somewhat like file descriptors in a user process, but they are not restricted to files open for I/O: directories being examined, files being accessed by `stat` calls, and so on — all files being manipulated by the operating system — are identified by fids."_ **9P is stateful**, and this is where the state lives.
- A **`qid`** is the server's 13-byte identity for a file: a one-byte type (`QTDIR`, `QTAPPEND`, `QTEXCL`, `QTAUTH`, `QTTMP`), a four-byte `version`, and an eight-byte `path`. The spec's requirement is exact: _"two files on the same server hierarchy are the same if and only if their qids are the same"_, and _"The path is an integer unique among all files in the hierarchy."_ ([`intro(5)`][p9p-intro].) That uniqueness requirement is a primary key with no enforcement mechanism, and [it breaks in production](#the-qid-collision-a-primary-key-with-no-constraint).

`Twalk` deserves separate attention because it is the only navigation primitive, and its shape determines everything downstream. From [`walk(5)`][9f-walk]: the walk is _elementwise_, the reply returns one `qid` per element successfully traversed, `newfid` is affected **only** if all `nwname` elements succeeded, and

> _"To simplify the implementation of the servers, a maximum of sixteen name elements or qids may be packed in a single message. This constant is called `MAXWELEM`."_ — [`walk(5)`][9f-walk]

There is no wildcard, no pattern, no predicate, and no way to ask about more than one branch of the tree in one message. `Twalk` is a lookup along a single root-to-leaf path. Everything a relational engine calls a _plan_ is, in 9P, the client's own loop.

The wire codec for all of this is **704 lines of C** — [`convS2M.c`][p9-convs2m] (389) and [`convM2S.c`][p9-convm2s] (315) in the Plan 9 tree. The kernel-side mount driver that turns local procedure calls into those messages, [`devmnt.c`][p9-devmnt], is 1,198 lines.

### Writing a server: thirteen function pointers

The server side is the same shape. plan9port's `lib9p` presents a `Srv` struct that is, in its entirety, a dispatch table over the protocol ([`include/9p.h`][p9p-9ph]):

```c
/* plan9port/include/9p.h — struct Srv (abridged) */
void	(*attach)(Req*);
void	(*auth)(Req*);
void	(*open)(Req*);
void	(*create)(Req*);
void	(*read)(Req*);
void	(*write)(Req*);
void	(*remove)(Req*);
void	(*flush)(Req*);
void	(*stat)(Req*);
void	(*wstat)(Req*);
void	(*walk)(Req*);
char*	(*clone)(Fid*, Fid*);
char*	(*walk1)(Fid*, char*, Qid*);
```

Every entry is optional; a server that leaves `walk` nil and supplies `walk1` gets the generic elementwise traversal for free. The reference in-memory filesystem built on it, [`src/lib9p/ramfs.c`][p9p-ramfs], is **168 lines**. Compare that with the `sqlite3_module` implementation osquery needs to expose a table — `xBestIndex`, `xFilter`, constraint routing, cost fabrication — [described in detail on the relational page][rel].

### Per-process namespaces: `bind`, `mount`, `unmount`

Three system calls construct the view a process has of the world ([`bind(2)`][p9-bind2]):

```c
int bind(char *name, char *old, int flag);
int mount(int fd, int afd, char *old, int flag, char *aname);
int unmount(char *name, char *old);
```

`mount` attaches a tree _served over a file descriptor_ — a pipe or a network connection already speaking 9P — at `old`. `bind` duplicates a piece of the existing namespace at another point in it. Both are ordinary, **unprivileged** operations available to any process. The `flag` selects `MREPL`, `MBEFORE`, or `MAFTER`; the last two build a **union directory**, which

> _"behaves like the concatenation of the constituent directories … When a file lookup is performed in a union directory, each component of the union is searched in turn and the first match taken; likewise, when a union directory is read, the contents of each of the component directories is read in turn."_ — [`sys/doc/9.ms`][p9-9ms]

`MCREATE` decides which member of a union receives a newly created file; without it, a directory in a union silently refuses creation. The paper is candid that this took several iterations to get right, and the payoff is that `/bin` is a union of `/$cputype/bin`, `/rc/bin`, and the user's own directory — which "makes the shell `$PATH` variable unnecessary."

Namespace _inheritance_ is a bit in `rfork` ([`fork(2)`][p9-fork2]): `RFNAMEG` gives the child a private copy, `RFCNAMEG` gives it an empty one that must be rebuilt from a mounted file descriptor, and — the security-relevant one — `RFNOMNT` means _"subsequent mounts into the new name space and dereferencing of pathnames starting with `#` are disallowed."_

Bootstrapping uses that `#` syntax: `#c` is the console device, `#p` the process device, `#s` the service registry, `#t` the serial ports. `bind -a '#t' /dev` is how serial ports appear as `/dev/eia1` and `/dev/eia1ctl` at all.

### The kernel side: a mount table consulted on every walk

The implementation is startlingly direct, and [`sys/doc/9.ms`][p9-9ms] describes it in one paragraph:

> _"The kernel representation of the name space is called the mount table, which stores a list of bindings between channels. Each entry in the mount table contains a pair of channels: a `from` channel and a `to` channel. Every time a walk succeeds in moving a channel to a new location in the name space, the mount table is consulted to see if a `from` channel matches the new name; if so the `to` channel is cloned and substituted for the original."_

A union directory is that `to` channel becoming a list; a failed lookup follows the list and retries. Identity is `(type, device, qid.path)` — "The type and device number are analogous to UNIX major and minor device numbers; the qid is analogous to the i-number." The whole of [`chan.c`][p9-chan] is 1,796 lines.

### Everything is a file, taken to its conclusion

The claim is only interesting if the awkward cases are actually done this way, so here are the awkward cases.

**The network stack.** `/net/tcp` contains a `clone` file and one numbered directory per connection; each connection directory holds `ctl`, `data`, `listen`, `local`, `remote`, `status`. Opening `clone` reserves a connection and returns its control file; reading the control file yields the connection number as text. A call is made by writing a string ([`sys/doc/9.ms`][p9-9ms]):

```
connect 135.104.9.52!23
```

and a server announces with `announce 23`. There is no `socket(2)`, no `bind(2)`, no `connect(2)`, no `getsockopt`. Address-family heterogeneity is handled by a _file server_ — `cs`, the connection server — which is asked, in text, which `clone` file to open and what address to present to it.

**The window system.** `8½` is a file server for `/dev/cons`, `/dev/mouse`, and `/dev/bitblt`. Each client sees a _different_ `/dev/cons` because each window is created in its own namespace; and because that is the only mechanism, `8½` runs recursively inside one of its own windows, and X11 runs as a client of it. From [`names.ms`][p9-names]: _"The environment `8½` provides its clients is exactly the environment under which it is implemented."_

**Processes.** `/proc/1`, `/proc/2`, … each a directory of `mem`, `text`, `ctl`, `status`, `note`, `ns`, `fd`. Debugging is `open`/`read`/`write` on `mem`; killing is `echo kill > /proc/n/ctl`; and

> _"the command `cat /proc/*/status` is a crude form of the `ps` command; the actual `ps` merely reformats the data so obtained."_ — [`names.ms`][p9-names]

**The CPU.** `cpu` starts a shell on a remote machine and then _exports the terminal's namespace to it_, so the remote shell's `/dev/cons` is the local window. It is not `rlogin` (which moves to a different namespace) and not NFS (which shares files but forces local execution). Symmetrically, `import helix /net` makes another machine's network interfaces local, and `import helix /proc` makes its processes debuggable by the local debugger — cross-architecture, because `db` infers the CPU type from the executable header on `/proc/27/text`.

---

## Format identity and multiplicity

**This is the axis where the subject scores lowest, and the low score is a structural fact rather than an oversight.** There is no artifact. A namespace is not a byte stream; it is a live binding between a process and a set of servers. Nothing here is prefix-tolerant, suffix-tolerant, or hole-tolerant, because there are no bytes to tolerate — the same "degenerate case" the [relational surfaces page][rel] reaches for osquery and Steampipe, arrived at from the opposite direction.

Three genuine multiplicities survive that disclaimer, and each is a _different_ kind from the [ZIP suffix parasitism][zip] and [APE polyglot][ape] cases:

1. **One name, several trees, simultaneously.** A union directory is not a chimera (regions of one file) and not a polyglot (two parsers over one stream); it is one _name_ that resolves against an ordered list of backing servers, with first-match-wins on lookup and concatenation on read. It is the only construct in this catalog where multiplicity lives in the _namespace_ rather than in the bytes, and it is the one Linux copied most faithfully as `OverlayFS` — with the union semantics but not the per-process scoping.

2. **One file, two meanings by direction.** `/net/tcp/0/ctl` accepts `connect 1.2.3.4!23` when written and yields the connection number when read. `/dev/time`, `/dev/cputime`, `/dev/pid`, `/dev/user` synthesize their contents on demand and modify kernel data structures when written. The read-parse and the write-parse of the same "file" are entirely different grammars — a [parser-differential][diff] surface hiding inside the uniform interface, and one with no schema anywhere to reconcile the two.

3. **A file whose contents are a program that rebuilds the file's own container.** `/proc/$pid/ns` is discussed under [Reflexivity](#reflexivity-and-query-surface); it is the closest this subject comes to autology, and it is real.

The honest summary: 9P deliberately _eliminates_ multiplicity. Everything is one format — a byte stream reached by a path — and the whole design bet is that a single parse, universally agreed, is worth more than any number of simultaneous ones. That bet is the exact inverse of [APE's][ape], and [thesis 5][concepts] frames the two as competing strategies for the same goal of reach.

---

## Index anchoring and random access

The four anchoring choices in the [concepts vocabulary][concepts] assume a file with an index in it. A namespace has neither, so the metadata table says **out-of-band**, and the interesting content is what that costs.

**Within a leaf, random access is native and cheap.** `Tread` carries an eight-byte offset and a four-byte count; `Twrite` likewise. There is no block granularity, no whole-file transfer, and no notion of "open the file to read one byte from the middle". This is precisely why 9P can back a root filesystem over a virtio channel, and why the [range-request][range] pattern — a page-oriented reader over a remote byte range — is expressible over 9P without extending it. `Ropen` even returns an `iounit`, the largest count the server guarantees to handle atomically, so the client knows its own chunking bound.

**Across leaves, there is no index at all.** The only navigation primitive is `Twalk`, along one root-to-leaf path, at most sixteen elements per message. There is no `readdir` filter, no glob in the protocol, and no way to express "every file under here whose `status` contains `Broken`". Answering that costs one `Twalk` plus one `Topen` plus `Tread`s **per candidate file**, driven entirely by the client. `cat /proc/*/status` is a nested-loop scan with the shell as the query engine — an engine with no statistics, no indexes, and no ability to reorder anything.

The consequences are visible in every production 9P deployment:

| Cost                               | Where it shows up                                                                                                                                                                  |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| One round trip per path resolution | WSL's `\\wsl.localhost\<distro>` and `/mnt/c` traversals; Docker's advice to keep bind-mount sources on the Linux side ([below](#the-9p-afterlife-where-it-is-load-bearing-today)) |
| `msize` caps every transfer        | Linux's `DEFAULT_MSIZE` is `(128 * 1024) + P9_IOHDRSZ` ([`include/net/9p/client.h`][k-client-h]); WSL pins it to **65,536** bytes ([`lxinitshared.h`][wsl-lxinit])                 |
| `MAXWELEM = 16` splits deep paths  | A 40-element path is three `Twalk` round trips minimum ([`walk(5)`][9f-walk])                                                                                                      |
| No caching in the protocol         | _"None of the 9P messages consider caching"_ ([`names.ms`][p9-names]); caching is a `qid.version` comparison bolted on by clients                                                  |

The last row is the one that generalises. Plan 9's own answer was minimal and stated as such: `qid.version` changes whenever a file is modified, and on `exec` the kernel re-opens the binary and compares versions with its image cache. Everything richer — a client cache, a write-back mode — is outside the protocol, "transparent to processes … and requires no change to 9P." Linux had to build the richer thing anyway, and its `cache=` bitmask ([`9p.rst`][k9p]) is the receipt: `none`, `readahead`, `mmap`, `loose`, `fscache`, with the warning that _"loose caches … do not necessarily validate cached values on the server."_

There is no [materialized view][concepts] anywhere in the model, and that is a design decision with two faces. Nothing can go stale, because nothing is precomputed; and nothing can be fast, because nothing is precomputed. The single exception is the _declarative_ namespace file — `/lib/namespace`, whose format is specified in [`namespace(6)`][p9-ns6] with `mount`, `bind`, `import`, `cd`, `unmount`, `clear`, and `.` operations — and that file is a stored description of a world that may have moved underneath it, with exactly the staleness failure mode `ldconfig`'s cache and `prelink`'s addresses have.

---

## Reflexivity and query surface

This is the axis where the comparison with [relational system surfaces][rel] is sharpest, and where the honest score is a **2** rather than a 3.

### Self-interrogation is total and costs nothing

A running Plan 9 process can read its own process directory, its own CPU time (`/dev/cputime`), its own pid (`/dev/pid`), its own user (`/dev/user`), and its own memory image (`/proc/$pid/mem`) through the same `open`/`read`/`write` calls it uses for anything else. It requires no library, no in-process query engine, and no cooperating daemon. The `iostats` command in [`names.ms`][p9-names] takes this to its conclusion: it _encapsulates a process in a namespace it serves itself_, monitoring the 9P traffic between that process and the outside world, then reporting the totals. A profiler implemented as a man-in-the-middle file server, with no instrumentation of the subject.

9front carries the idea into tracing: `devdtracy` ([`sys/src/9/port/devdtracy.c`][9f-dtracy]) exposes a DTrace-style engine as `#Δ`, where a probe program is _written to a file_ and its output _read from another one_.

### The namespace describes itself, in the language that builds it

The 1995 paper lists this as a missing feature:

> _"Although Plan 9 has per-process name spaces, it has no mechanism to give the description of a process's name space to another process except by direct inheritance. … It should instead be possible to capture the terminal's name space and transmit its description to a remote process."_ — [`sys/doc/9.ms`][p9-9ms]

It was subsequently added, and the way it was added is the single most catalog-relevant fact on this page: **the namespace became a file.** `Qns` in [`devproc.c`][p9-devproc] walks the process's mount table on read and emits one line per entry:

```c
/* plan9/sys/src/9/port/devproc.c — case Qns (abridged) */
mntscan(mw, p);
if(mw->mh == 0){
    mw->cddone = 1;
    i = snprint(a, n, "cd %s\n", p->dot->path->s);
    ...
}
int2flag(mw->cm->mflag, flag);
if(strcmp(mw->cm->to->path->s, "#M") == 0){
    srv = srvname(mw->cm->to->mchan);
    i = snprint(a, n, "mount %s %s %s %s\n", flag, ...);
}else
    i = snprint(a, n, "bind %s %s %s\n", flag,
        mw->cm->to->path->s, mw->mh->from->path->s);
```

The output is `mount`, `bind`, and `cd` lines — the same verbs as [`namespace(6)`][p9-ns6], the file format that _constructs_ a namespace. [`ns(1)`][p9-ns1] states the loop plainly: _"The output is in the form of an `rc(1)` script that could, in principle, recreate the name space. The output is produced by reading and reformatting the contents of `/proc/pid/ns`."_

A description of the container, obtained from inside the container, in the language that builds containers. That is [autology][concepts] in the catalog's narrow sense, achieved without a database — and note the escape hatch the manual leaves itself: _"in principle"_, plus a `BUGS` section admitting the names are wrong if anything was renamed. Reconstruction is best-effort, because nothing was ever _stored_; the view is recomputed by `mntscan` at read time and is therefore always current and never authoritative.

### What cannot be asked, and why the score is 2

The [reflexivity axis][concepts] has two halves, and 9P passes the second and fails the first.

- _Self-interrogating?_ Yes, natively, at 3.
- _Interrogable through a general question-asking surface?_ **No.** There is a fixed menu of files, exactly as `readelf` answers a fixed menu of questions. A question the server author did not anticipate a file for cannot be asked; it can only be _computed_, by a client program that walks and reads and does the work itself.

The concrete gaps, each with no workaround inside the protocol:

| Missing                | Consequence                                                                                                                                                                                 |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Joins**              | "Which process holds the TCP connection to port 443" requires the client to read all of `/proc/*/fd` and all of `/net/tcp/*/remote` and correlate in its own memory                         |
| **Aggregation**        | No `COUNT`, no `GROUP BY`; the shell pipeline is the aggregator, and it is a single-pass streaming one                                                                                      |
| **Transitive queries** | Process ancestry, dependency closure, reachability — the queries a graph-shaped subject most wants — are hand-written traversals                                                            |
| **Transactions**       | Nothing spans two files. `bind` and `mount` return "a positive integer (a unique sequence number) for success" ([`bind(2)`][p9-bind2]) and there is no way to apply five of them atomically |
| **A schema**           | Nothing anywhere says that `/net/tcp/0/ctl` accepts `connect addr!port`. It is documented in a manual page and enforced by the server's `write` handler                                     |

The last row is [thesis 2][concepts] landing squarely on 9P. The protocol carries a `stat` record — name, permissions, times, owner, group — and _nothing about content_. There is not even a MIME type. Every meaning is convention, and the paper says so approvingly: _"there are known names for services and uniform names for files exported by those services, but the view is entirely local … it is the conventions that guarantee sane behavior in the presence of local names."_ A convention-guaranteed system is a system that accretes conventions, which is precisely what thesis 2 predicts for a format without a schema.

---

## Closure, dedup, and size model

**Closure scores 0, and it is the cleanest zero in the catalog.** A namespace carries nothing. It is pure indirection: every name in it resolves to a fid on a server that must be _alive right now_. Unmount the server and the names evaporate. There is no artifact to `scp`, no bytes to copy, and correspondingly nothing to deduplicate.

What replaces closure is **closure by reference, reconstructed on demand**, and the `cpu` command is the demonstration. Running a shell on a remote CPU server does not ship an environment; it exports the terminal's namespace to the server so that the remote process's `/dev/cons`, `/dev/mouse`, and `/dev/bitblt` are the local window's files. From [`names.ms`][p9-names]: _"Bindings in `/bin` may change because of a change in CPU architecture, and the networks involved may be different because of differing hardware, but the effect feels like simply speeding up the processor in the current name space."_

The size model that results is the opposite of every carrying strategy in this tree:

| Strategy                         | What travels                     | Cost of a second instance                      |
| -------------------------------- | -------------------------------- | ---------------------------------------------- |
| [AppImage / static linking][pkg] | Every dependency, copied         | Full duplication                               |
| [Nix closure][nix]               | Every dependency, shared by hash | One store path, referenced N times             |
| [SELF][self]                     | Every dependency, stored as rows | One database, `VACUUM`-able                    |
| **Plan 9 namespace**             | **A mount table of channels**    | **Another mount table; the bytes never moved** |

The interesting number is what a namespace _costs to carry_, and the answer is the `/proc/$pid/ns` text: a few dozen `bind` and `mount` lines, kilobytes at most. But it is not a closure in the [Nix sense][concepts] — it is not closed under the "references" relation, because each line names a server whose existence it cannot guarantee. It is a _pointer graph serialized without its targets_, which is why the manual hedges with "in principle".

There is one honest dedup story, and it is at the wrong layer to help: the central file server's page cache. From [`sys/doc/9.ms`][p9-9ms], _"The large memory of the central file server acts as a shared cache for all its clients, which reduces the total amount of memory needed across all machines in the network."_ Deduplication is achieved by _not having copies_, which works exactly as long as the network does.

---

## Mutability, dispatch, and trust

### Who dispatches

**The kernel, on every walk.** This is a stronger and more frequent form of dispatch than any other subject in this tree. [`binfmt_misc`][binfmt] decides what a file is once, at `execve`. The [dynamic loader][ld] decides once per `DT_NEEDED` at startup. A [relational surface][rel] decides at query-plan time. Plan 9's mount table is consulted after _every successful path element_, and a match substitutes a cloned channel to a different server. The result is that "what does this program see" is a first-class, per-process, mutable, unprivileged construction — the property Linux spent two decades partially recovering.

Dispatch is on the **name**, never on the bytes. There is no magic number anywhere in the model, no sniffing, and no content-type. That immunity to [parser differentials][diff] is real but purchased: the disagreement moves from "two parsers read one stream differently" to "two processes resolve one name differently", which is not obviously better and is much harder to audit — precisely because there is no artifact to inspect.

### Mutability

Mutability scores **1**. Writing to a file _is_ the API — `connect 1.2.3.4!23`, `b1200`, `kill`, `stop` — so the system's control surface and its data surface are the same surface, and the paper is proud of it: _"in Plan 9, devices are controlled by textual messages, free of byte order problems, with clear semantics for reading and writing. It is common to configure or debug devices using shell scripts."_

But none of that is _self_-mutation in the catalog's sense. The artifact is not its own state store, because there is no artifact. There are no transactions, no atomic multi-file updates, and no rollback. `DMEXCL` (exclusive-use, one client at a time) and `DMAPPEND` (offset ignored on write) are the entire concurrency vocabulary — two mode bits where a database has an isolation level.

[Thesis 4][concepts] — `mmap` is the load-bearing constraint — applies here with unusual clarity, and the evidence comes from the ports rather than from Plan 9 itself. 9P has no `mmap`. Demand paging a binary from a 9P mount means the client kernel must cache pages and decide when they are stale, and the protocol offers only `qid.version` for that. Linux's answer is a dedicated cache mode: `mmap` = `0b00000101`, read-ahead plus write-back file cache, and the base mode `0b00000000` is documented as _"all caches disabled, mmap disabled"_ ([`9p.rst`][k9p]). WSL turns it on unconditionally in its mount string ([`WSLCVirtualMachine.cpp`][wsl-vm]):

```
"{},msize={},trans=fd,rfdno={},wfdno={},aname={},cache=mmap"
```

A protocol designed with no caching semantics cannot support demand paging until a client invents caching semantics for it — which is the same shape of problem SELF has, arrived at from the network rather than from the b-tree.

### The `qid` collision: a primary key with no constraint

The specification is unambiguous: `qid.path` is _"unique among all files in the hierarchy."_ It is a primary key. Nothing in the protocol enforces it, and every real server derives it from something else — WSL's server documents the shortcut in a comment ([`p9defs.h`][wsl-p9defs]): _"On Linux, the path is used as the inode number."_

Inode numbers are unique _per device_, not per tree. Export a host directory that spans two filesystems and two different files get the same `qid.path`, at which point the client's cache confuses them. QEMU's `-virtfs` therefore ships a `multidevs` option with three settings ([QEMU invocation docs][qemu-invoke]): `remap` (the default — rewrite inode numbers to avoid collisions), `forbid` (deny access below the first device), and `warn` (log once and proceed, with "may cause misbehaviors" as the documented consequence).

That is [thesis 1][concepts] — every binary format eventually reimplements a database, badly — showing up in a _protocol_ rather than a format. `qid.path` is a foreign key maintained by hand across a boundary the protocol cannot see, with no referential integrity, and the fix is a userspace remapping table that a real database would call a surrogate-key generator.

### Trust

Authentication is in the protocol and is deliberately _not specified_ by it. `Tauth` establishes an `afid`; the client and server then `Tread` and `Twrite` that fid to exchange _"authentication information not defined explicitly by 9P"_, and the completed `afid` is presented in `Tattach` ([`intro(5)`][p9p-intro]). Every subsequent fid derived from that attach carries the attached user's identity. Authentication is a file. It is the most complete instance of the design philosophy in the whole system, and it means the protocol never needs a version bump when the auth mechanism changes.

Sandboxing is namespace construction plus one irrevocable bit. Building a restricted world is `rfork(RFCNAMEG)` followed by mounting only what the child should see; `RFNOMNT` then forbids further mounts _and_ the `#` escape hatch ([`fork(2)`][p9-fork2]). That is `pledge`/`unveil`/`Landlock` fifteen years early, with the important difference that the _positive_ half — "here is the set of things you may name" — is the primitive rather than the exception list. The [threat model page][threat] should read `RFNOMNT` as prior art for capability dropping.

What is missing is anything resembling integrity. There is no signing, no measurement, no attestation, and no content hash anywhere in 9P. `Tstat` returns permissions, times, and names. A client that mounts a server trusts it completely, and a server that accepts an attach trusts the `uname` to the extent its own auth protocol made it trustworthy. The absence is consistent — there is no artifact to sign — but it means every property [embedded provenance][prov] cares about must be supplied by a layer 9P does not know exists.

---

## A namespace and a relational surface answer the same question

This is the comparison the page exists to make. Both designs start from the same complaint — _the thing I want to interrogate has no uniform interface, only a pile of one-off tools_ — and both answer with a single interface that every resource must implement. They then diverge completely.

| Question                                  | Namespace (9P)                                                      | Relational surface (osquery / Steampipe / SELF)                                                    |
| ----------------------------------------- | ------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| The uniform interface is…                 | a path, plus `open`/`read`/`write`/`stat`                           | a table, plus SQL                                                                                  |
| Number of operations                      | **13**                                                              | one — `SELECT` — with unbounded expressions inside it                                              |
| Who plans the work                        | the client, in a loop it writes itself                              | the engine, from statistics and cost estimates                                                     |
| Joins                                     | absent; correlate by hand in the client                             | native, and the reason the interface was chosen                                                    |
| Aggregation, `GROUP BY`, window functions | absent; a shell pipeline, single-pass                               | native                                                                                             |
| Transitive / recursive queries            | a hand-written traversal                                            | recursive CTEs (available, [ergonomically hostile][rel]) or Datalog ([code as a database][codedb]) |
| Transactions                              | absent                                                              | native (SELF's whole [mutability][self] claim rests on this)                                       |
| Streaming                                 | native — `Tread` blocks on a synthesized file until an event occurs | awkward; requires cursors, `LIMIT`, or an event-table subsystem                                    |
| Remote access                             | in the protocol from day one; `import`, `cpu`, `exportfs`           | bolted on — HTTP (Datasette), gRPC (Steampipe), Thrift (osquery extensions)                        |
| Composition with the existing toolchain   | **total** — `cat`, `grep`, `awk`, pipes, redirection, shell scripts | **none** — the output of a `SELECT` is not a file, and a table is not a stream                     |
| Per-consumer views                        | native and unprivileged (`bind`, `mount`, `rfork`)                  | schema grants (Steampipe), or nothing                                                              |
| Naming, protection, permissions           | inherited from the filesystem, free                                 | reinvented per system                                                                              |
| Cost of an unanticipated question         | **write a program**                                                 | **write a `SELECT`**                                                                               |

The last row is the whole trade, and the two rows above it are the price.

**A namespace gives you composition; it does not give you a query engine.** Every tool that already reads bytes from a path works, unchanged, on every resource in the system, including remote ones — `grep 'mouse bug fix' 1995/*/sys/src/cmd/8½/file.c` searches the backup filesystem with `grep`, and `import helix /proc; ps` lists a remote machine's processes with `ps`. Nothing was written for either. But the moment the question involves two trees at once, the composition stops helping: the shell can pipe, and cannot join.

**A relational surface gives you a query engine; it does not give you composition.** `SELECT p.name FROM processes p JOIN listening_ports l ON p.pid = l.pid` is one line, planned, filtered, and pushed down. But it is not a byte stream, so nothing downstream of it speaks its output without a serializer, and nothing upstream of it can be substituted per-process the way a `bind` can.

### The sharpest point: who had to rebuild the tooling

This is the asymmetry that survives every other objection.

**osquery and Datasette had to rebuild the toolchain for their interface.** osquery ships `osqueryi` (a shell), a scheduler, a differential engine that stores previous result sets and diffs them, a watchdog to kill queries, a denylist for queries the watchdog killed, a publish/subscribe event layer because on-demand generation is lossy, a schema-browser website, and a spec DSL compiler that turns 287 `.table` files into C++ — all catalogued on [the relational surfaces page][rel]. Datasette ships an HTTP server, a JSON API with its own pagination token format, a `__INTERNAL__` catalog database that reimplements `sqlite_schema` across files, an interrupt handler that terminates queries every 1,000 VM instructions, and a plugin system. None of that existed; all of it had to be built, because SQL-over-a-live-system is not something any pre-existing tool spoke.

**Plan 9 had to rebuild nothing, because its interface was already the one every tool spoke.** `ps` is a reformatter over `/proc/*/status`. `ns` is a reformatter over `/proc/$pid/ns`. The backup filesystem needed no browser because `grep` and `ls` browse it. A network gateway is `import helix /net`. A profiler is a file server placed between a process and its namespace. The _entire_ Plan 9 command set is, in the paper's own framing, mostly "new programs for old jobs" — which is to say the jobs did not change.

That asymmetry is [thesis 3][concepts] — _the container is a tax_ — generalised past containers to interfaces. **An interface nothing else speaks levies a tooling tax proportional to how much tooling you want.** The relational systems pay it in code; Plan 9 avoided it by choosing the interface every tool already had. And the counter-charge is equally real: Plan 9 avoided the tax by choosing an interface that _cannot express the queries the relational systems were built to answer_. It is not that Plan 9 solved the problem more cheaply. It answered a smaller question, and got the tooling for free as a consequence of the answer being small.

The two positions are not reconcilable inside one interface, and the systems that tried both — `sqlelf` over ELF, Steampipe over APIs — resolve it by making the _query engine_ the universal layer instead of the byte stream, which is [thesis 5][concepts] again: portability migrating out of the format and into the access layer.

---

## The 9P afterlife: where it is load-bearing today

The interesting evidence about which parts of the model survived is in what shipped, and the answer is uncomfortable for the "smallness is the argument" thesis: **the protocol survived and the namespace mostly did not, and the protocol survived only by roughly tripling in size.**

### Linux adopted the mechanisms and refused the uniformity

Linux has bind mounts (`mount --bind`, since 2.4), mount namespaces (`CLONE_NEWNS`, [`mount_namespaces(7)`][mountns]), `/proc`, `/sys`, `OverlayFS` for unions, and a full 9P client (`fs/9p` + `net/9p`, merged for 2.6.14 in [`b8cf945b`][v9fs-merge]). Every individual Plan 9 primitive is present. What is absent is the property that made them worth having: **uniformity**. The network stack is `socket(2)` and `setsockopt`, not `/net/tcp/0/ctl`. The window system is a Unix-domain socket speaking Wayland or X11, not files in `/dev`. Process control is `ptrace(2)` and signals, not `echo stop > ctl`. `/proc` is the surviving fragment, exactly as the source outline for this catalog says, and even it is a fragment: `/proc/$pid/mem` is readable, but debugging still goes through `ptrace`.

Two differences are worth stating precisely, because they show what "adopted the mechanism, not the model" costs.

**Privilege.** In Plan 9, `bind` and `mount` are unprivileged operations available to every process; that is the entire basis of "a user builds a private computing environment". On Linux, creating a mount namespace requires `CAP_SYS_ADMIN`, and an unprivileged process can only get there by first entering a user namespace ([`mount_namespaces(7)`][mountns], [`user_namespaces(7)`][userns]) — which is why the incantation is `unshare -Umr`, and why containers needed a decade of hardening around it. A first-class construction in one system is a privileged operation plus a security boundary in the other.

**Propagation.** Plan 9's mount table is a flat list of channel pairs; a namespace is either shared (`rfork` without `RFNAMEG`) or copied. Linux needed _shared subtrees_ — `MS_SHARED`, `MS_PRIVATE`, `MS_SLAVE`, `MS_UNBINDABLE`, plus peer groups and propagation trees — because mounts must sometimes appear in namespaces that did not create them ([`mount_namespaces(7)`][mountns]). That machinery has no Plan 9 counterpart, and it exists because Linux namespaces are used for _isolation_ while Plan 9's were used for _composition_.

**Introspection.** Both systems can be asked what a process sees. Plan 9 answers with `/proc/$pid/ns`, whose contents are `bind` and `mount` lines. Linux answers with `/proc/$pid/mountinfo`, a fixed-format table:

```
22 30 0:6 / /dev rw,nosuid shared:13 - devtmpfs devtmpfs rw,size=3174060k,mode=755
```

and `/proc/$pid/ns/*`, a directory of symlinks to opaque identifiers (`mnt -> mnt:[4026531832]`). The Plan 9 answer is a program that rebuilds the thing; the Linux answer is a record you must parse and a handle you may `setns(2)` into. The Linux design is strictly more capable — you can _enter_ a namespace, which Plan 9 cannot do — and strictly less autological.

### 9P as a hypervisor transport: this is where it actually runs

The protocol found a niche the namespace did not: moving a filesystem across a VM boundary, where the transport is a ring buffer and the two sides do not share a kernel.

**WSL.** Microsoft's own architecture documentation is unambiguous ([`doc/docs/technical-documentation/plan9.md`][wsl-p9doc]):

> _"Plan9 is a Linux process that hosts a plan9 filesystem server for WSL1 and WSL2 distributions. … From Windows, a special redirector driver (`p9rdr.sys`) registers both `\\wsl$` and `\\wsl.localhost`. When either of those paths are accessed, `p9rdr.sys` calls `wslservice.exe` to list the available distributions for a given Windows user."_

And in the other direction, `/mnt/c` is a 9P mount of a server running on the Windows side ([`drvfs.md`][wsl-drvfs]) — the documentation for which links to plan9port's `intro(9p)` man page as its protocol reference. Two Plan 9 ideas appear together in that file: 9P for the transport, and _mount namespaces_ to separate elevated from non-elevated views of the Windows drives, which is `bind` in a different accent.

The implementation is in-tree at [`src/linux/plan9/`][wsl-p9dir], and its message enumeration is the honest record of what the protocol became ([`p9defs.h`][wsl-p9defs]):

| Dialect    | Request types | Added                                                                                                                                                                                                                       |
| ---------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `9P2000`   | **13**        | the original                                                                                                                                                                                                                |
| `9P2000.L` | **32**        | `Tstatfs`, `Tlopen`, `Tlcreate`, `Tsymlink`, `Tmknod`, `Trename`, `Treadlink`, `Tgetattr`, `Tsetattr`, `Txattrwalk`, `Txattrcreate`, `Treaddir`, `Tfsync`, `Tlock`, `Tgetlock`, `Tlink`, `Tmkdir`, `Trenameat`, `Tunlinkat` |
| `9P2000.W` | **35**        | `Taccess`, `Twreaddir`, `Twopen` — _"a currently unofficial extension to 9P2000.L which includes some messages used by the Windows Plan 9 redirector for improved functionality and performance"_                           |

The Linux client carries the same set — 34 `P9_T*` constants in [`include/net/9p/9p.h`][k-9p-h], two of which (`P9_TLERROR`, documented as "not used", and `P9_TERROR`) are not real requests. And the size story matches: `fs/9p` plus `net/9p` is **13,152 lines** of C, against 704 lines for Plan 9's entire wire codec. POSIX semantics — `xattr`, `flock`, `statfs`, `readlink`, `mknod`, `renameat`, `unlinkat` — cost nineteen new messages and roughly twenty times the code. **The smallness was a property of Plan 9's file semantics, not of the protocol.**

**QEMU / virtio-9p.** QEMU's `-virtfs` is documented as _"actually just a convenience shortcut for its generalized form `-fsdev -device virtio-9p-pci`"_ ([QEMU invocation docs][qemu-invoke]), with four `security_model` values (`passthrough`, `mapped-xattr`, `mapped-file`, `none`) that exist entirely because a 9P server backed by a POSIX directory must decide whose credentials to use and where to keep the attributes the host filesystem cannot represent. `mapped-file` stores them in a hidden `.virtfs_metadata` directory and is documented to "not interact with other unix tools" — an [out-of-band index][concepts] with the usual failure mode. Guest-side, the mount is `mount -t 9p -o trans=virtio <mount_tag> /mnt/9`, with tags discoverable through `/sys/bus/virtio/drivers/9pnet_virtio/` ([`9p.rst`][k9p]).

**Container file sharing.** Docker Desktop's WSL 2 backend inherits WSL's 9P path for anything bind-mounted out of the Windows filesystem, and Docker's guidance is to avoid it: _"Performance is much higher when files are bind-mounted from the Linux filesystem, rather than accessed from the Windows host filesystem"_ ([Docker Desktop WSL 2 best practices][docker-wsl]). The documentation does not name the protocol, so treat the attribution as inference from WSL's architecture rather than as Docker's own claim.

### The verdict on survival

The direction of travel is the finding. WSL's own code falls back from `virtiofs` to Plan 9 rather than the reverse ([`drvfs.cpp`][wsl-drvfs-cpp]: _"Remove the successful bind before `MountVirtioFs` falls back to Plan 9"_), and the `virtio-9p` transport is gated behind a config key that WSL's loader actively disables ([`WslCoreConfig.cpp`][wsl-config]). Docker Desktop removed the legacy `osxfs` sharing outright in 4.80.0 (2026-06-29), migrating remaining users to VirtioFS ([release notes][docker-rn]). **The 9P transport is being replaced, in production, by a FUSE-over-virtio design with a shared-memory window** — which is to say, by something that can `mmap`, and whose per-operation cost is not a round trip capped by `msize`.

That is [thesis 4][concepts] deciding an argument. The part of the model that survived thirty years is not the small message set; it is `/proc`, bind mounts, and the observation that a per-process view of the world is worth having. The protocol survived where nothing better existed and is losing ground now that something does.

---

## Strengths

- **One interface, thirteen operations, and every existing tool speaks it.** `grep` over a backup filesystem, `ps` over a remote machine's `/proc`, `cat` as a debugger front-end. No tool was written for any of these; they compose because the interface is the one they already had.
- **Per-process namespaces are unprivileged and cheap.** `rfork(RFNAMEG)` plus a few `bind`s is a complete sandbox, a debugging environment, or a window's private `/dev` — with no capability, no daemon, and no configuration file.
- **Union directories eliminate a whole category of configuration.** `/bin` as `/$cputype/bin` before `/rc/bin` before the user's own directory makes `$PATH` unnecessary, and the same mechanism gives every architecture the same command names.
- **Remoting is in the protocol, not around it.** `import`, `cpu`, and `exportfs` are ordinary programs; the protocol was designed for a network on day one, and there is no local/remote distinction anywhere in the client API.
- **Authentication is a file.** `Tauth` establishes an `afid` and then gets out of the way, so the auth mechanism can change without a protocol revision.
- **The implementation is small enough to read.** 704 lines of wire codec, 1,198 lines of mount driver, 1,796 lines of channel/namespace code, a 13-pointer server interface, and a 168-line reference file server.
- **The namespace describes itself in the language that builds it.** `/proc/$pid/ns` emits `bind`/`mount`/`cd` lines; `ns(1)` reformats them into a runnable script. Introspection required no new mechanism, only one more file.
- **Sandboxing is positive rather than negative.** `RFCNAMEG` starts from nothing and adds; `RFNOMNT` makes the result irrevocable. Fifteen years before `pledge`, `unveil`, and Landlock.

## Weaknesses

- **No joins, no aggregation, no transitive queries, no transactions.** Every question spanning two files is a program the client writes, executes as a nested loop, and cannot have planned for it. This is the whole cost of the design and it is not recoverable inside the protocol.
- **No schema, anywhere.** Nothing says that `/net/tcp/0/ctl` accepts `connect addr!port`. Meaning is convention plus a manual page, which is [thesis 2][concepts]'s prediction of accretion, confirmed.
- **`Twalk` is a round trip per path resolution, capped at 16 elements.** Combined with a negotiated `msize` — 128 KiB on Linux, **64 KiB** in WSL — this is the entire performance story of every production deployment, and the reason Docker tells users to keep their source trees on the other side of the boundary.
- **No caching in the protocol.** `qid.version` is the whole coherence mechanism. Every client that needed more invented its own, and Linux's `cache=loose` carries the warning that it "does not necessarily validate cached values on the server."
- **No `mmap`, and therefore a fight with demand paging.** Linux needed a dedicated `cache=mmap` mode to make it possible at all; the base mode is documented as "mmap disabled". [Thesis 4][concepts] applies in full.
- **`qid.path` is an unenforced primary key.** Real servers derive it from inode numbers, which collide across devices, which is why QEMU ships `multidevs=remap|forbid|warn` and documents the third option as possibly causing misbehaviour.
- **Closure is zero and non-negotiable.** A namespace is a graph of pointers to live servers. Nothing can be archived, signed, verified, or handed to someone else; `/proc/$pid/ns` reconstructs "in principle" and its own manual page lists the cases where it is wrong.
- **The smallness did not survive POSIX.** 13 requests became 32 in `9P2000.L` and 35 in Microsoft's `9P2000.W`; the Linux implementation is 13,152 lines against Plan 9's 704-line codec.
- **The uniformity did not survive adoption.** Linux took bind mounts, mount namespaces, `/proc`, and `/sys` — every mechanism — and kept `socket`, `ioctl`, `ptrace`, and a display-server protocol. The mechanisms without the uniformity deliver a fraction of the value, because the payoff was always compositional.

---

## Key design decisions and trade-offs

| Decision                                                                       | Rationale                                                                                                    | Trade-off                                                                                                               |
| ------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| Every resource is a file tree, not an object or a table                        | Files come "prepackaged" with naming, protection, remoting, and a universe of tools that already read bytes  | No joins, no aggregation, no query planning; every non-trivial question becomes a client-side program                   |
| Thirteen fixed messages; explicitly _not_ an extensible protocol               | A closed set can be implemented completely by every server and understood completely by every client         | Every semantic that does not fit becomes a text convention inside a file, invisible to the protocol                     |
| Statefulness via client-chosen `fid`s                                          | A fid is a cheap cursor; walking to a subdirectory does not re-resolve the path from the root                | Servers must track per-connection state; a lost connection loses every fid, and there is no resumption story            |
| `Twalk` is elementwise, single-path, `MAXWELEM = 16`                           | Keeps servers trivial to write — `walk1` is one function returning one `Qid`                                 | One round trip per ≤16 elements; the dominant cost of every VM-boundary deployment thirty years later                   |
| 64-bit offsets on `Tread`/`Twrite`, no block granularity                       | Byte-level access without a page cache in the protocol; distinguishes 9P from NFS and RFS                    | Nothing to `mmap`; demand paging requires a client-invented cache mode                                                  |
| No caching semantics; `qid.version` only                                       | The central file server's memory is the shared cache, reducing total memory across the network               | Every client reimplemented caching; Linux's `loose` mode is documented as not validating against the server             |
| Namespaces are per-process and unprivileged                                    | "A user builds a private computing environment and recreates it wherever desired"                            | Linux could not copy this — `CLONE_NEWNS` needs `CAP_SYS_ADMIN`, and unprivileged use needs a user namespace first      |
| Union directories with `MCREATE` on one member                                 | Makes `$PATH` unnecessary; lets a private directory shadow public ones while only it accepts new files       | Took several iterations to settle; lookup cost is linear in union depth, and read concatenates rather than merges       |
| Authentication delegated to reads and writes on an `afid`                      | The auth mechanism can change without a protocol revision                                                    | 9P specifies nothing about it, so interoperability requires out-of-band agreement                                       |
| `qid.path` "unique among all files in the hierarchy", unenforced               | Cheap identity; lets a server use whatever it already has                                                    | Inode-derived paths collide across devices; QEMU needs `multidevs`, and one of its settings is "may cause misbehaviors" |
| `/proc` is "only a view of a process, not a representation"                    | Refusing `cp /bin/date /proc/clone/mem` keeps the server's job describable in terms of answering 9P requests | Process creation, network addressing, and shared memory stay outside the model — the metaphor has a documented boundary |
| Namespace introspection added as a file (`/proc/$pid/ns`) emitting its own DSL | The only mechanism available was the one the system already had                                              | Best-effort — the manual documents that renames invalidate it, and nothing is stored, so nothing is authoritative       |
| `RFNOMNT` as an irrevocable capability drop                                    | Positive sandboxing: build the world, then forbid additions                                                  | All-or-nothing; there is no partial revocation and no per-path policy the way Landlock has                              |

---

## Sources

- [`sys/doc/9.ms` — _Plan 9 from Bell Labs_, Pike, Presotto, Dorward, Flandrena, Thompson, Trickey, Winterbottom; _Computing Systems_ 8(3), Summer 1995][p9-9ms] — the three principles, the mount table, `/net/tcp`, `cpu`/`import`, the "9P multiplexer" claim, and the discussion of what was left out
- [`sys/doc/names.ms` — _The Use of Name Spaces in Plan 9_, Pike, Presotto, Thompson, Trickey, Winterbottom; _Operating Systems Review_ 27(2), April 1993][p9-names] — `bind`/`mount`/`rfork` semantics, `8½` as a file server, `iostats`, `cat /proc/*/status`, and the "Position" section on what does not map to files
- [`intro(5)` (plan9port `intro(9p)`) — the complete 9P2000 message set, `fid`/`qid`/`tag` semantics, permissions, `DMDIR`/`DMAPPEND`/`DMEXCL`][p9p-intro] · [`walk(5)`][9f-walk] · [`version(5)`][9f-version]
- [`sys/include/fcall.h` — the message-type enumeration and `MAXWELEM`][p9-fcall] · [`convS2M.c`][p9-convs2m] / [`convM2S.c`][p9-convm2s] — the 704-line wire codec
- [`sys/src/9/port/chan.c` — namespace and channel implementation][p9-chan] · [`devmnt.c` — the mount driver, the system's only RPC mechanism][p9-devmnt] · [`devproc.c` — `Qns`, the namespace-as-a-file][p9-devproc]
- [`bind(2)` — `bind`/`mount`/`unmount`, `MREPL`/`MBEFORE`/`MAFTER`/`MCREATE`/`MCACHE`][p9-bind2] · [`fork(2)` — `RFNAMEG`, `RFCNAMEG`, `RFNOMNT`][p9-fork2] · [`srv(3)` — the file-descriptor bulletin board][p9-srv3] · [`exportfs(4)`][p9-exportfs] · [`ns(1)`][p9-ns1] · [`namespace(6)` — the namespace description file format][p9-ns6]
- [`sys/doc/release4.ms` — the Fourth Edition release notes, April 2002: "9P has been redesigned to address a number of shortcomings"][p9-rel4]
- [9front `sys/src/9/port/devdtracy.c` — DTrace as a file server][9f-dtracy]
- [plan9port `include/9p.h` — the `Srv` dispatch table][p9p-9ph] · [`src/lib9p/ramfs.c` — a complete 9P server in 168 lines][p9p-ramfs]
- [`Documentation/filesystems/9p.rst` — transports, `cache=` bitmask, `version=` dialects, virtio mount tags][k9p] · [`include/net/9p/9p.h` — the 34 `P9_T*` constants][k-9p-h] · [`include/net/9p/client.h` — `DEFAULT_MSIZE`][k-client-h] · [the `v9fs` merge commit for 2.6.14][v9fs-merge]
- [`mount_namespaces(7)` — `CLONE_NEWNS`, shared subtrees, `/proc/pid/mountinfo`][mountns] · [`user_namespaces(7)`][userns] · [`mount(2)` — `MS_BIND`][mount2]
- [microsoft/WSL `doc/docs/technical-documentation/plan9.md` — "Plan9 is a Linux process that hosts a plan9 filesystem server"][wsl-p9doc] · [`drvfs.md` — mount namespaces for elevated vs non-elevated Windows drives][wsl-drvfs] · [`src/linux/plan9/p9defs.h` — `9P2000.L` and the unofficial `9P2000.W`][wsl-p9defs] · [`src/linux/init/drvfs.cpp` — the virtiofs-to-Plan 9 fallback][wsl-drvfs-cpp] · [`WSLCVirtualMachine.cpp` — the `cache=mmap` mount string][wsl-vm] · [`lxinitshared.h` — `msize` = 65,536][wsl-lxinit]
- [QEMU invocation manual — `-fsdev`, `-virtfs`, `security_model`, `multidevs`][qemu-invoke] · [Docker Desktop WSL 2 best practices][docker-wsl] · [Docker Desktop release notes — `osxfs` removal in 4.80.0][docker-rn]
- Related in this tree: [concepts][concepts] · [relational surfaces over non-relational things][rel] · [single-level store][sls] · [code as a database][codedb] · [`sqlelf`][sqlelf] · [SELF / selfdb][self] · [`binfmt_misc`][binfmt] · [dynamic linking][ld] · [parser differentials][diff] · [image-based systems][image] · [range-request access][range] · [Nix store closures][nix] · [embedded provenance][prov] · [threat model][threat] · [comparison][comparison] · [open questions][open]

<!-- References -->

[p9-repo]: https://github.com/0intro/plan9
[9f-repo]: https://github.com/9front/9front
[p9p-repo]: https://github.com/9fans/plan9port
[wsl-repo]: https://github.com/microsoft/WSL
[p9-9ms]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/doc/9.ms
[p9-names]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/doc/names.ms
[p9-fcall]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/include/fcall.h
[p9-convs2m]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/src/libc/9sys/convS2M.c
[p9-convm2s]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/src/libc/9sys/convM2S.c
[p9-chan]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/src/9/port/chan.c
[p9-devmnt]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/src/9/port/devmnt.c
[p9-devproc]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/src/9/port/devproc.c
[p9-bind2]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/man/2/bind
[p9-fork2]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/man/2/fork
[p9-srv3]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/man/3/srv
[p9-exportfs]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/man/4/exportfs
[p9-ns1]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/man/1/ns
[p9-ns6]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/man/6/namespace
[p9-rel4]: https://github.com/0intro/plan9/blob/0aab9506bfc2acb5203a411b917cea62cf3eeb91/sys/doc/release4.ms
[9f-walk]: https://github.com/9front/9front/blob/50aefa0743c8cfd83fdc7f568d24e1bba8b9848e/sys/man/5/walk
[9f-version]: https://github.com/9front/9front/blob/50aefa0743c8cfd83fdc7f568d24e1bba8b9848e/sys/man/5/version
[9f-dtracy]: https://github.com/9front/9front/blob/50aefa0743c8cfd83fdc7f568d24e1bba8b9848e/sys/src/9/port/devdtracy.c
[p9p-intro]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/man/man9/0intro.9p
[p9p-9ph]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/include/9p.h
[p9p-ramfs]: https://github.com/9fans/plan9port/blob/b6564bd96ca189c69e28797738dad56f91eb5967/src/lib9p/ramfs.c
[k9p]: https://docs.kernel.org/filesystems/9p.html
[k-9p-h]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/net/9p/9p.h?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[k-client-h]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/include/net/9p/client.h?id=e43ffb69e0438cddd72aaa30898b4dc446f664f8
[v9fs-merge]: https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=b8cf945b3166c4394386f162a527c9950f396ce2
[mountns]: https://man7.org/linux/man-pages/man7/mount_namespaces.7.html
[userns]: https://man7.org/linux/man-pages/man7/user_namespaces.7.html
[mount2]: https://man7.org/linux/man-pages/man2/mount.2.html
[wsl-p9doc]: https://github.com/microsoft/WSL/blob/8af1856f86f09aa099de169932ef95f7a88466c8/doc/docs/technical-documentation/plan9.md
[wsl-drvfs]: https://github.com/microsoft/WSL/blob/8af1856f86f09aa099de169932ef95f7a88466c8/doc/docs/technical-documentation/drvfs.md
[wsl-p9defs]: https://github.com/microsoft/WSL/blob/8af1856f86f09aa099de169932ef95f7a88466c8/src/linux/plan9/p9defs.h
[wsl-p9dir]: https://github.com/microsoft/WSL/tree/8af1856f86f09aa099de169932ef95f7a88466c8/src/linux/plan9
[wsl-drvfs-cpp]: https://github.com/microsoft/WSL/blob/8af1856f86f09aa099de169932ef95f7a88466c8/src/linux/init/drvfs.cpp
[wsl-vm]: https://github.com/microsoft/WSL/blob/8af1856f86f09aa099de169932ef95f7a88466c8/src/windows/wslcsession/WSLCVirtualMachine.cpp
[wsl-config]: https://github.com/microsoft/WSL/blob/8af1856f86f09aa099de169932ef95f7a88466c8/src/windows/common/WslCoreConfig.cpp
[wsl-lxinit]: https://github.com/microsoft/WSL/blob/8af1856f86f09aa099de169932ef95f7a88466c8/src/shared/inc/lxinitshared.h
[qemu-invoke]: https://www.qemu.org/docs/master/system/invocation.html
[docker-wsl]: https://docs.docker.com/desktop/features/wsl/best-practices/
[docker-rn]: https://docs.docker.com/desktop/release-notes/
[concepts]: ./concepts.md
[rel]: ./relational-system-surfaces.md
[sls]: ./single-level-store.md
[codedb]: ./code-as-database.md
[sqlelf]: ./sqlelf.md
[self]: ./self-selfdb/index.md
[ape]: ./cosmopolitan-ape/index.md
[zip]: ./zip-parasitism.md
[binfmt]: ./binfmt-misc.md
[ld]: ./dynamic-linking.md
[diff]: ./parser-differentials.md
[image]: ./image-based-systems.md
[range]: ./range-request-access.md
[nix]: ./nix-store-closures.md
[prov]: ./embedded-provenance.md
[threat]: ./threat-model.md
[comparison]: ./comparison.md
[open]: ./open-questions.md
[pkg]: ../application-packaging/index.md
