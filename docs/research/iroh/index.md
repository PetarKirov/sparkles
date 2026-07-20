# Iroh: Peer-to-Peer QUIC Networking & Content-Addressed Data

A source-grounded survey of [iroh][repo-iroh]'s Rust implementation — n0's stack for
authenticated peer-to-peer QUIC connectivity and content-addressed data transfer — read at
workspace **v1.0.1** (commit [`22cac742ca`][repo-iroh]) to inform a clean-room native **D**
reimplementation running on [`sparkles:event-horizon`][eh-spec] (single-threaded,
completion-first `io_uring`/kqueue/IOCP, fibers + algebraic effects). Each subsystem was read
against its pinned tree, cited to real `path:line`s, and written up as an independent deep-dive;
this page is the map that ties them together.

This survey answers eight questions:

1. **What is a peer, and how does it prove who it is?** — every endpoint is a single Ed25519
   keypair whose 32-byte public key _is_ its [`EndpointId`][identity], authenticated in an
   [RFC 7250][rfc7250] raw-public-key [TLS 1.3][rfc8446] handshake carried in QUIC `CRYPTO`
   frames — no PKI, no X.509. See [Identity & Cryptography][identity] (shared vocabulary in
   [Concepts][concepts]).
2. **How does every iroh value become bytes?** — exactly one application codec ([`postcard`][postcard]),
   base32-wrapped tickets, and an [ALPN][rfc7301] registry. See [Wire Formats & Serialization][wire].
3. **What carries the connection, and what must a port rebuild?** — [`noq`][repo-noq], n0's
   sans-io fork of [`quinn`][quinn] extended with QUIC Multipath, QUIC Address Discovery, and an
   in-QUIC NAT-traversal protocol. See [QUIC Transport (`noq`)][quic]; the app-facing
   `connect`/`accept` + protocol-router shell is [Endpoint & Protocol Router][endpoint].
4. **How does one logical connection ride many changing network paths?** — the multipath
   [Socket][socket] (the module formerly called `magicsock`) that fans QUIC datagrams across
   direct, IPv6, and relay carriers under one `noq::AsyncUdpSocket`.
5. **How do two NATed peers get a direct path, and what happens when they cannot?** —
   QUIC-native simultaneous-open [NAT Traversal & Address Discovery][nat] (the `DISCO` UDP
   side-protocol and STUN are **gone**); the always-reachable [Relay][relay] is rendezvous and
   fallback; [Net Report][net-report] measures the local vantage point via `netwatch` /
   `portmapper`.
6. **How do you reach a peer knowing only its key?** — [Address Lookup][discovery]: [BEP-44][bep44]-signed
   records published and resolved over [pkarr][pkarr] relays and the DNS.
7. **How is application data moved, verified, synced, and broadcast?** — content-addressed
   [Blobs][blobs] over [BLAKE3 verified streaming][bao-tree], multi-writer [Document Sync][docs-sync],
   and epidemic [Gossip][gossip].
8. **What concurrency runs all of this, and how does it collapse onto a single-threaded loop?**
   — a complete [Tokio Concurrency Inventory][concurrency] feeding the [D Architecture
   Migration][d-arch] onto [`sparkles:event-horizon`][eh-spec].

> [!NOTE]
> **Scope.** This is the master index for the iroh research tree. Each row below links to a
> deep-dive that was written and fact-checked independently against its pinned source tree;
> where this index summarizes a subsystem, the **deep-dive is the source of truth**. The
> workspace is pinned at iroh **v1.0.1** (`22cac742ca`); companion crates at [`iroh-blobs`][repo-blobs]
> 0.103.0, [`iroh-docs`][repo-docs] 0.101.0, [`iroh-gossip`][repo-gossip] 0.101.0, [`noq`][repo-noq]
> 1.0.1 (`noq-v1.0.1`), [`bao-tree`][repo-bao] 0.16.0, [`iroh-util`][repo-util] 0.6.0, and
> [`irpc`][repo-irpc] 0.17.0. **iroh 1.0 is a major restructure of the 0.x API** — `magicsock` →
> the [socket][socket] layer, "discovery" → `address_lookup`, `NodeId` → `EndpointId`, and the
> `DISCO` UDP side-protocol + STUN replaced by QUIC-native NAT traversal + QUIC Address Discovery
> inside [`noq-proto`][quic]. `NodeAddr`-era folklore does not compile; treat pre-1.0 material with
> suspicion.

**Last reviewed:** July 6, 2026

---

## Master Catalog

One row per subsystem, grouped by [layer](#by-layer). **ALPN / role** gives the wire-bearing
[ALPN][rfc7301] string where the subsystem owns one, otherwise its function. Versions are the
pinned tags read; per-`path:line` provenance lives in each deep-dive's `Sources` block.

### Foundations

| Subsystem                                | Crate(s)                                | Version                                  | ALPN / role                            | What it does                                                                                     | Link                    |
| ---------------------------------------- | --------------------------------------- | ---------------------------------------- | -------------------------------------- | ------------------------------------------------------------------------------------------------ | ----------------------- |
| **[Identity & Cryptography][identity]**  | `iroh-base`, `iroh` (`tls/*`)           | iroh 1.0.1 (`22cac742ca`)                | none — raw-public-key TLS 1.3 identity | Ed25519 keypair = `EndpointId`; RFC 7250 handshake; BLAKE3 auxiliary MACs; no PKI, no ECDH       | [Deep-dive →][identity] |
| **[Wire Formats & Serialization][wire]** | `iroh-tickets`, `iroh-base`, `postcard` | `iroh-tickets` 1.0.0 / `iroh-base` 1.0.1 | owns the ALPN registry                 | one non-self-describing `postcard` codec, base32 tickets, five base codecs, per-protocol framing | [Deep-dive →][wire]     |
| **[QUIC Transport (`noq`)][quic]**       | `noq`, `noq-proto`, `noq-udp`           | `noq-v1.0.1` (`340e9c7`)                 | none — transport is ALPN-agnostic      | sans-io QUIC v1 state machine + Multipath + Address Discovery + in-QUIC NAT traversal (≈48k LoC) | [Deep-dive →][quic]     |

### Connectivity

| Subsystem                                             | Crate(s)                                        | Version                                              | ALPN / role                                              | What it does                                                                                             | Link                      |
| ----------------------------------------------------- | ----------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- | ------------------------- |
| **[Endpoint & Protocol Router][endpoint]**            | `iroh` (`endpoint`, `protocol`, `runtime`)      | iroh 1.0.1 (`22cac742ca`)                            | app-chosen (e.g. `b"iroh-example/echo/0"`)               | cheaply-clonable `Endpoint` over `noq`; `Router` multiplexes inbound connections onto `ProtocolHandler`s | [Deep-dive →][endpoint]   |
| **[The Multipath Socket][socket]**                    | `iroh` (`socket`, ex-`magicsock`)               | iroh 1.0.1 (`22cac742ca`)                            | none — sits below QUIC/TLS                               | one `AsyncUdpSocket` over IP + relay + custom carriers; synthetic-IPv6 mapped addrs; path selection      | [Deep-dive →][socket]     |
| **[NAT Traversal & Address Discovery][nat]**          | `noq-proto`, `noq`, `iroh`, `iroh-relay`        | `noq-v1.0.1` / iroh 1.0.1                            | `/iroh-qad/0` (QAD server); QNT rides the app connection | simultaneous-open `ADD_ADDRESS`/`REACH_OUT`/`REMOVE_ADDRESS` over the encrypted 1-RTT dataplane          | [Deep-dive →][nat]        |
| **[The Relay Protocol][relay]**                       | `iroh-relay`, `iroh` (relay transport)          | iroh-relay 1.0.1                                     | WS subprotocol `iroh-relay-v2`; QAD ALPN `/iroh-qad/0`   | authenticated WebSocket packet-forwarder keyed on `EndpointId` + a bare QAD QUIC endpoint (port 7842)    | [Deep-dive →][relay]      |
| **[Address Lookup (Discovery)][discovery]**           | `iroh`, `iroh-dns`, `iroh-dns-server`           | iroh 1.0.1 / `iroh-dns` 1.0.1                        | none — DNS + pkarr HTTP(S)                               | `EndpointId` → dialable addresses via BEP-44-signed DNS packets over pkarr relays and the DNS            | [Deep-dive →][discovery]  |
| **[Net Report, Watching & Port Mapping][net-report]** | `iroh` (`net_report`), `netwatch`, `portmapper` | iroh 1.0.1 / `netwatch` 0.19.1 / `portmapper` 0.19.1 | `/iroh-qad/0` probe; HTTPS fallback                      | measures UDP reachability, public address, NAT type, home relay; interface watching + UPnP/PCP/NAT-PMP   | [Deep-dive →][net-report] |

### Protocols

| Subsystem                                              | Crate(s)                                      | Version               | ALPN / role                                 | What it does                                                                                                  | Link                     |
| ------------------------------------------------------ | --------------------------------------------- | --------------------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------- | ------------------------ |
| **[Blobs: Content-Addressed Transfer][blobs]**         | `iroh-blobs`, `iroh-util`, `irpc`, `bao-tree` | `iroh-blobs` 0.103.0  | `/iroh-bytes/4`                             | request/response BLAKE3 verified-stream transfer; crash-consistent store; resumable multi-provider downloader | [Deep-dive →][blobs]     |
| **[BLAKE3 Verified Streaming (`bao-tree`)][bao-tree]** | `bao-tree`                                    | `bao-tree` 0.16.0     | n/a — a codec, not a wire protocol          | exposes BLAKE3's internal Merkle tree as an incrementally-verifiable stream (16 KiB chunk groups)             | [Deep-dive →][bao-tree]  |
| **[Document Sync (`iroh-docs`)][docs-sync]**           | `iroh-docs`                                   | `iroh-docs` 0.101.0   | `/iroh-sync/1`                              | multi-writer eventually-consistent KV store; recursive range-fingerprint set reconciliation                   | [Deep-dive →][docs-sync] |
| **[Epidemic Broadcast (`iroh-gossip`)][gossip]**       | `iroh-gossip`                                 | `iroh-gossip` 0.101.0 | `/iroh-gossip/1` (per-instance overridable) | HyParView partial-view membership + Plumtree eager/lazy-push broadcast tree, as an IO-less state machine      | [Deep-dive →][gossip]    |

### D migration

| Subsystem                                      | Crate(s)                               | Version                         | ALPN / role                      | What it does                                                                                                              | Link                       |
| ---------------------------------------------- | -------------------------------------- | ------------------------------- | -------------------------------- | ------------------------------------------------------------------------------------------------------------------------- | -------------------------- |
| **[Tokio Concurrency Inventory][concurrency]** | `n0-future`, `n0-watcher`, `irpc`, all | workspace 1.0.1 (`irpc` 0.17.0) | none — process-internal plumbing | census of every task, channel, lock, `select!` loop, `spawn_blocking`, timer; protocol-inherent vs `Send + Sync` artifact | [Deep-dive →][concurrency] |

> [!NOTE]
> Two catalog entries are cross-cutting rather than subsystems: [Concepts & Vocabulary][concepts]
> (the shared glossary every page references) and [D Architecture Migration][d-arch] (the capstone
> that maps the whole stack onto [event-horizon][eh-spec]). Both are in [Quick Navigation](#quick-navigation),
> not the Master Catalog.

---

## Taxonomy

Three re-cuts of the same fourteen subsystems, one axis each. Every row links back to a deep-dive.

### By layer

The catalog's grouping: where a subsystem sits from the identity root up to the runtime that
drives it. Higher layers depend on lower ones.

| Layer            | Concern                                                              | Subsystems                                                                                                                          |
| ---------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| **Foundations**  | Identity, bytes, and the transport state machine everything rides    | [Identity & Cryptography][identity], [Wire Formats][wire], [QUIC Transport][quic]                                                   |
| **Connectivity** | Getting an authenticated QUIC path to a peer, wherever it is         | [Endpoint][endpoint], [Socket][socket], [NAT Traversal][nat], [Relay][relay], [Address Lookup][discovery], [Net Report][net-report] |
| **Protocols**    | Application services built on top of a connection                    | [Blobs][blobs], [`bao-tree`][bao-tree], [Document Sync][docs-sync], [Gossip][gossip]                                                |
| **D migration**  | Porting artifacts — the concurrency census and the architecture plan | [Concurrency Inventory][concurrency], [D Architecture Migration][d-arch]                                                            |

### By network role

The same set cut by _what job it does on the wire_ rather than where it sits in the stack.

| Role                    | Question it answers                                            | Subsystems                                                                                                    |
| ----------------------- | -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **Identity & encoding** | Who is this peer, and how do its values serialize?             | [Identity & Cryptography][identity], [Wire Formats][wire]                                                     |
| **Transport**           | How is an authenticated, multiplexed byte pipe established?    | [QUIC Transport][quic], [Endpoint][endpoint]                                                                  |
| **Connectivity / NAT**  | How do we _reach_ a peer, and stay reached as the net changes? | [Socket][socket], [NAT Traversal][nat], [Relay][relay], [Address Lookup][discovery], [Net Report][net-report] |
| **Data protocols**      | What application semantics ride the connection?                | [Blobs][blobs], [`bao-tree`][bao-tree], [Document Sync][docs-sync], [Gossip][gossip]                          |
| **Runtime**             | What schedules all of the above?                               | [Concurrency Inventory][concurrency]                                                                          |

### By port difficulty

The axis that matters most for the D reimplementation: how a subsystem should be _acquired_. A
subsystem can appear in more than one class — [Socket][socket], for instance, is both policy to
re-implement and raw OS surface to bind.

| Class                         | What the port does                                                                                                                                   | Subsystems                                                                                                                                                                                                                   |
| ----------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Reuse a sans-io core**      | The logic is already a pure `(state, event) → effects` machine with no OS or runtime coupling; re-derive the state machine and drive it from a fiber | [QUIC Transport][quic] (`noq-proto`), [Gossip][gossip] (`proto/`), [Document Sync][docs-sync] (range reconciler), [`bao-tree`][bao-tree], [Wire Formats][wire] (`postcard`)                                                  |
| **Reimplement policy / glue** | Moderate protocol and policy logic over a sans-io core; no exotic OS or crypto surface                                                               | [Endpoint][endpoint], [Socket][socket] (routing fabric), [NAT Traversal][nat] (orchestration), [Relay][relay], [Address Lookup][discovery], [Blobs][blobs] (protocol/store/downloader), [Concurrency substrate][concurrency] |
| **Needs an OS binding**       | Must bind raw per-OS surfaces the language runtime does not provide                                                                                  | [Net Report][net-report] (`netwatch` netlink/`AF_ROUTE`/`/proc/net/route`/IP Helper/`getifaddrs`; `portmapper` UPnP/PCP/NAT-PMP), [Socket][socket] (UDP send/recv, GSO/GRO, rebind)                                          |
| **Needs a crypto primitive**  | Depends on cryptographic primitives that must be spec-exact and constant-time                                                                        | [Identity & Cryptography][identity] (Ed25519, TLS 1.3 raw-public-key, BLAKE3 `keyed_hash`/`derive_key`), [`bao-tree`][bao-tree] & [Blobs][blobs] (BLAKE3), [Relay][relay] (TLS keying-material export, [RFC 5705][rfc5705])  |

> [!NOTE]
> The single largest _reuse-a-sans-io-core_ item, [`noq-proto`][quic], is ≈48k lines of protocol
> logic — deterministic and portable, but the dominant effort of the whole port. Its own crate root flags
> it as of interest to anyone who wants "a different event loop than the one tokio provides" —
> precisely event-horizon's brief. See [QUIC Transport § Mapping to event-horizon][quic].

---

## Milestones: the 0.x → 1.0 restructure

iroh 1.0 is not an increment; it deletes whole subsystems and QUIC-natively absorbs their jobs. The
table below is the evolution the survey documents, subsystem by subsystem.

> [!NOTE]
> The pinned trees carry no dated changelog of the 0.x release line, and this survey trusts only the
> pinned sources — so only the **1.0-era tag dates are absolute**: [`noq`][repo-noq] `noq-v1.0.1`
> released **2026-06-29** (`340e9c7`); iroh [`v1.0.1`][repo-iroh] committed **2026-07-03**
> (`22cac742ca`). The "iroh 0.x" column describes the _prior architecture_ each deep-dive contrasts
> against, not a dated release; treat the ordering as logical, not chronological.

| Capability                  | iroh 0.x                                                                                          | iroh 1.0                                                                                                                             | Surveyed in                                |
| --------------------------- | ------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------ |
| NAT-traversal signalling    | **DISCO** — a bespoke UDP ping/pong side-protocol using NaCl `crypto_box` (node key → Curve25519) | **QUIC-native (QNT)** — `ADD_ADDRESS`/`REACH_OUT`/`REMOVE_ADDRESS` frames on the encrypted 1-RTT dataplane                           | [NAT Traversal][nat], [Identity][identity] |
| Reflexive-address discovery | **STUN** against relay servers                                                                    | **QUIC Address Discovery** (`/iroh-qad/0`) on the main endpoint — no STUN code remains                                               | [Net Report][net-report], [Relay][relay]   |
| Connectivity module         | `magicsock` (`MagicSock`)                                                                         | `socket` (`Socket`, `pub(crate)`)                                                                                                    | [Socket][socket]                           |
| Path model                  | Duplicate each datagram onto UDP **and** relay; DISCO ping/pong picks a winner                    | Relay and every direct address are **concurrent QUIC multipath paths** on one connection; switching = flipping a path's `PathStatus` | [Socket][socket], [QUIC][quic]             |
| QUIC library                | [`quinn`][quinn]                                                                                  | [`noq`][repo-noq] fork — adds Multipath, Address Discovery, in-QUIC NAT traversal                                                    | [QUIC Transport][quic]                     |
| Identity vocabulary         | `NodeId` / `NodeAddr` / `NodeTicket`                                                              | `EndpointId` / `EndpointAddr` / `EndpointTicket` — old `node…` tickets are unparseable                                               | [Identity][identity], [Wire][wire]         |
| Address directory           | `discovery` (`Discovery` / `DiscoveryItem`)                                                       | `address_lookup` (`AddressLookup` / `Item`); pkarr/DNS-centric                                                                       | [Address Lookup][discovery]                |
| Relay wire format           | DERP-era bespoke framing / magic strings                                                          | Binary WebSocket subprotocol `iroh-relay-v2` (v1 legacy); the `Health` frame is removed in v2                                        | [Relay][relay]                             |
| Blobs store contract        | A `Store` / `Map` trait hierarchy                                                                 | "Whatever handles the `Command` enum" over [`irpc`][repo-irpc]                                                                       | [Blobs][blobs]                             |
| Blobs downloader            | Dial queues, retry backoff, request dedup baked in                                                | ~550-line re-planning orchestrator + a generic `ConnectionPool`; those concerns pushed to consumers                                  | [Blobs][blobs]                             |
| Blobs transfer ALPN         | `/iroh-bytes/4`                                                                                   | `/iroh-bytes/4` — **unchanged** across the rename (a deliberate interop-stability point)                                             | [Blobs][blobs]                             |
| Gossip ALPN                 | `/iroh-gossip/0`                                                                                  | `/iroh-gossip/1`, now per-instance overridable via `Builder::alpn`                                                                   | [Gossip][gossip]                           |

---

## Quick Navigation

### Suggested reading paths

- **"I want the connectivity story."** [QUIC Transport][quic] → [Endpoint][endpoint] → [Socket][socket]
  → [NAT Traversal][nat] → [Relay][relay] → [Address Lookup][discovery] → [Net Report][net-report].
- **"I want the identity & byte layer."** [Concepts][concepts] → [Identity & Cryptography][identity]
  → [Wire Formats][wire].
- **"I want the data protocols."** [Blobs][blobs] → [`bao-tree`][bao-tree] → [Document Sync][docs-sync]
  → [Gossip][gossip].
- **"I want a minimal interop MVP."** The smallest byte-compatible target is an echo/`dumbpipe`
  peer — one ALPN, no store, no docs/gossip: [Identity][identity] → [Wire Formats][wire] →
  [Endpoint][endpoint] → [QUIC Transport][quic] → [Socket][socket] → [Relay][relay] →
  [NAT Traversal][nat].
- **"I'm designing the D port."** [Concurrency Inventory][concurrency] (what actually runs) →
  [D Architecture Migration][d-arch] (the plan) → the four sans-io cores you can port directly
  ([QUIC][quic], [Gossip][gossip], [Document Sync][docs-sync], [`bao-tree`][bao-tree]) → the
  [event-horizon spec][eh-spec] and the [async-io tree][async-io] — especially [Tokio][tokio] (the
  model being replaced) and [Glommio][glommio] / [monoio][monoio] (the thread-per-core,
  share-nothing stance event-horizon adopts).

### Overview & synthesis

- **[Concepts & Vocabulary][concepts]** — the shared glossary: `EndpointId`, `EndpointAddr`,
  tickets, ALPN, path, relay, the 0.x → 1.0 rename map every page relies on.
- **[Tokio Concurrency Inventory][concurrency]** — the exhaustive census of tasks, channels, locks,
  `select!` loops, and blocking work, classified protocol-inherent vs `Send + Sync` artifact.
- **[D Architecture Migration][d-arch]** — the capstone: Rust constructs beside proposed D
  equivalents on [event-horizon][eh-spec], the bottlenecks (CPU-bound BLAKE3 on the loop thread, the
  missing cross-fiber channel primitive), and the sans-io reuse strategy.

### Cross-tree

- **[event-horizon spec][eh-spec]** — the D runtime the port targets: completion-first loop, fibers,
  `Scope`/`race`/`JoinHandle` structured concurrency, capability effects, `IoResult!`/`Outcome!`.
- **[async-io survey][async-io]** — the prior-art runtime survey; [Tokio][tokio], [Glommio][glommio],
  and [monoio][monoio] are the directly-relevant deep-dives.
- **[algebraic-effects corpus][ae-index]** — the effect-handler background behind event-horizon's
  capability layer.

---

## Sources

Each deep-dive carries its own primary-source citations to exact `path:line`s in the pinned trees;
this index's classifications derive from them. The pinned upstream artifacts are:

- **iroh workspace** (`iroh`, `iroh-base`, `iroh-tickets`, `iroh-relay`, `iroh-dns`,
  `iroh-dns-server`) — [`n0-computer/iroh`][repo-iroh] at `22cac742ca` · [docs.rs/iroh][docs-iroh].
- **Transport** — [`n0-computer/noq`][repo-noq] at `noq-v1.0.1` (`noq`, `noq-proto`, `noq-udp`) ·
  [docs.rs/noq][docs-noq]; a fork of [`quinn`][quinn].
- **Data protocols** — [`iroh-blobs`][repo-blobs] 0.103.0 · [docs.rs/iroh-blobs][docs-blobs];
  [`bao-tree`][repo-bao] 0.16.0 · [docs.rs/bao-tree][docs-bao]; [`iroh-docs`][repo-docs] 0.101.0 ·
  [docs.rs/iroh-docs][docs-docs]; [`iroh-gossip`][repo-gossip] 0.101.0 · [docs.rs/iroh-gossip][docs-gossip].
- **Runtime & RPC** — [`irpc`][repo-irpc] 0.17.0 · [docs.rs/irpc][docs-irpc]; [`iroh-util`][repo-util]
  0.6.0 (`connection_pool`); `n0-future` / `n0-watcher`.
- **Connectivity sensing** — [`n0-computer/net-tools`][repo-nettools] (`netwatch` 0.19.1,
  `portmapper` 0.19.1).
- **Protocol drafts** — QUIC Multipath ([`draft-ietf-quic-multipath`][draft-multipath]), QUIC
  NAT-traversal ([`draft-seemann-quic-nat-traversal`][draft-qnt]), QUIC Address Discovery
  ([`draft-seemann-quic-address-discovery`][draft-qad]); [QUIC v1 (RFC 9000)][rfc9000],
  [TLS 1.3 (RFC 8446)][rfc8446]; [BLAKE3][blake3].

<!-- References -->

<!-- Deep-dives & synthesis (siblings) -->

[concepts]: ./concepts.md
[identity]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[quic]: ./quic-transport.md
[endpoint]: ./endpoint.md
[socket]: ./socket.md
[nat]: ./nat-traversal.md
[relay]: ./relay.md
[discovery]: ./discovery.md
[net-report]: ./net-report.md
[blobs]: ./blobs.md
[bao-tree]: ./bao-tree.md
[docs-sync]: ./docs-sync.md
[gossip]: ./gossip.md
[concurrency]: ./concurrency.md
[d-arch]: ./d-architecture-migration.md

<!-- Cross-tree -->

[eh-spec]: ../../specs/event-horizon/SPEC.md
[async-io]: ../async-io/index.md
[tokio]: ../async-io/tokio.md
[glommio]: ../async-io/glommio.md
[monoio]: ../async-io/monoio.md
[ae-index]: ../algebraic-effects/index.md

<!-- Upstream repositories -->

[repo-iroh]: https://github.com/n0-computer/iroh/tree/22cac742ca5e84da4542681e14b2d23b74c8330e
[repo-noq]: https://github.com/n0-computer/noq/tree/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd
[repo-blobs]: https://github.com/n0-computer/iroh-blobs/tree/e82cbdcbdac9a78033174aad55e3199b2cf4c0dc
[repo-docs]: https://github.com/n0-computer/iroh-docs/tree/091e8cac47bbc49cdb84b0bfed227cc163b61dfe
[repo-gossip]: https://github.com/n0-computer/iroh-gossip/tree/2ce78afe09d89d41d123f28eac19bdc831609cc8
[repo-bao]: https://github.com/n0-computer/bao-tree/tree/0d2e29163a52654ebf231e09ae87e4e207e21382
[repo-util]: https://github.com/n0-computer/iroh-util/tree/2b5447abf79bc0d7c02c202f2cc21f44f42d39fa
[repo-irpc]: https://github.com/n0-computer/irpc/tree/0ed2b235d5c797b54d8263ecb3b0247272d055f9
[repo-nettools]: https://github.com/n0-computer/net-tools

<!-- docs.rs -->

[docs-iroh]: https://docs.rs/iroh/1.0.1
[docs-noq]: https://docs.rs/noq/1.0.1
[docs-blobs]: https://docs.rs/iroh-blobs/0.103.0
[docs-docs]: https://docs.rs/iroh-docs/0.101.0
[docs-gossip]: https://docs.rs/iroh-gossip/0.101.0
[docs-bao]: https://docs.rs/bao-tree/0.16.0
[docs-irpc]: https://docs.rs/irpc/0.17.0

<!-- External specs & prior art -->

[quinn]: https://github.com/quinn-rs/quinn
[postcard]: https://docs.rs/postcard/latest/postcard/
[pkarr]: https://github.com/pubky/pkarr
[bep44]: https://www.bittorrent.org/beps/bep_0044.html
[blake3]: https://github.com/BLAKE3-team/BLAKE3
[draft-multipath]: https://datatracker.ietf.org/doc/draft-ietf-quic-multipath/
[draft-qnt]: https://datatracker.ietf.org/doc/draft-seemann-quic-nat-traversal/
[draft-qad]: https://datatracker.ietf.org/doc/draft-seemann-quic-address-discovery/
[rfc9000]: https://www.rfc-editor.org/rfc/rfc9000
[rfc8446]: https://www.rfc-editor.org/rfc/rfc8446
[rfc7250]: https://www.rfc-editor.org/rfc/rfc7250
[rfc7301]: https://www.rfc-editor.org/rfc/rfc7301
[rfc5705]: https://www.rfc-editor.org/rfc/rfc5705
