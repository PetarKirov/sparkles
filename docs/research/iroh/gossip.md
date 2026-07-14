# Epidemic Broadcast (`iroh-gossip`)

Topic-scoped epidemic broadcast: a [HyParView][hyparview] partial-view membership protocol keeps a small set of live bidirectional neighbors per 32-byte topic, and a [Plumtree][plumtree] eager/lazy-push layer self-optimizes those neighbors into a low-redundancy broadcast spanning tree — the whole protocol expressed as a pure, IO-less state machine driven over per-peer [noq][quic-transport] QUIC connections.

| Field               | Value                                                                                                                                                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate(s)            | [`iroh-gossip`][gossip-repo] (`proto/` pure state machine + `net/` tokio actor + irpc-based `api`)                                                                                                                                                |
| Version             | `iroh-gossip` 0.101.0 (git tag `v0.101.0`, commit `2ce78af`) · against `iroh` 1.0.1 (`22cac742`), `irpc` 0.17.0, `postcard` 1, `blake3` 1.8, `rand` 0.10.1, `indexmap` 2, `n0-future` 0.3                                                         |
| Repository          | [`n0-computer/iroh-gossip`][gossip-repo]                                                                                                                                                                                                          |
| Documentation       | [docs.rs/iroh-gossip][gossip-docs]                                                                                                                                                                                                                |
| ALPN(s)             | `b"/iroh-gossip/1"` ([`net.rs`][g-net], line 45) — overridable per instance via `Builder::alpn` ([`net.rs`][g-net], lines 172–181)                                                                                                                |
| Approx. size (LoC)  | ~8,000 across `src/` (~6,900 excluding the 1,140-line discrete-event simulator); the pure `proto/` state machine is ~3,300 lines, the `net/` actor ~2,600; the two densest modules are `net.rs` (1,977) and `proto/plumtree.rs` (910)             |
| Category            | Protocols                                                                                                                                                                                                                                         |
| Upstream spec/draft | HyParView — Leitão, Pereira, Rodrigues, [_HyParView: a membership protocol for reliable gossip-based broadcast_][hyparview] (DSN 2007); Plumtree — Leitão, Pereira, Rodrigues, [_Epidemic Broadcast Trees_][plumtree] (SRDS 2007). No IETF draft. |

---

## Overview

### What it solves

`iroh-gossip` provides **reliable one-to-many broadcast inside a swarm** without a central coordinator, in the presence of churn (nodes joining and failing) and without every node maintaining a connection to every other node. Two classic problems are solved separately and composed:

- **Membership** — how does a node learn about, and stay connected to, a useful subset of the swarm as peers come and go? Solved by [HyParView][hyparview]: each node keeps a small `active_view` (size 5) of peers it holds live bidirectional connections to, plus a larger `passive_view` (size 30) address book it draws from to heal the active view after a failure. Random walks (`ForwardJoin`, `Shuffle`) diffuse membership across the swarm.
- **Broadcast** — how does a message reach every member cheaply, i.e. without the O(n²) flooding of pushing every payload to every neighbor? Solved by [Plumtree][plumtree]: each active neighbor is either _eager_ (receives full payloads) or _lazy_ (receives only a `blake3` message-id announcement, `IHave`). The eager set forms a spanning tree that carries payloads once per edge; the lazy set is a redundant backstop that repairs gaps and continually re-optimizes the tree toward lowest latency.

Everything is scoped by a `TopicId` — a 32-byte identifier that names an independent swarm and broadcast domain. Joining N topics means N parallel membership + broadcast state machines and up to N unidirectional streams per peer connection. The default per-message ceiling is **4096 bytes** (`DEFAULT_MAX_MESSAGE_SIZE`, [`proto.rs`][g-proto], line 68), so gossip is a _control-plane_ / small-payload transport: [`iroh-docs`][docs-sync] rides on it to fan out `SyncReport`/`Op::Put` change notifications, and bulk content moves through [`iroh-blobs`][index] instead.

The crate is strictly layered ([`README.md`][g-readme]): `proto/` is a **pure state machine with no I/O**, and `net/` is a tokio actor that runs that state machine over iroh QUIC connections. This separation is the single most important fact for a D port — see [Mapping to event-horizon](#mapping-to-event-horizon).

### Design philosophy

The crate root states the architecture in its first line ([`proto.rs`][g-proto], line 1):

> "Implementation of the iroh-gossip protocol, as an IO-less state machine"

The membership and broadcast layers are documented as faithful implementations of the two Leitão et al. papers, and the self-optimizing property of the broadcast tree is called out explicitly ([`proto.rs`][g-proto], lines 39–43):

> "When requesting a message from a currently-lazy peer, this peer is also upgraded to be an eager peer from that moment on. This strategy self-optimizes the messaging graph by latency. Note however that this optimization will work best if the messaging paths are stable, i.e. if it's always the same peer that broadcasts. If not, the relative message redundancy will grow and the ideal messaging graph might change frequently."

The design consequence that matters most: **all protocol logic is a deterministic function of injected events, an injected clock, and an injected RNG** — no wall-clock reads, no sockets, no allocation of I/O. Time enters only as a `now: Instant` argument; timers are emitted as _data_ (`OutEvent::ScheduleTimer`) and fired back as _data_ (`InEvent::TimerExpired`); randomness is a generic `Rng` parameter ([`state.rs`][g-state], lines 78–86, 154–162). This is precisely the [sans-io][async-io] discipline the [event-horizon][eh-spec] runtime is built to drive, and it is documented as an intentional goal on the `State` type ([`state.rs`][g-state], lines 147–148):

> "The implementation works as an IO-less state machine. The implementer injects events through [`Self::handle`], which returns an iterator of [`OutEvent`]s to be processed."

---

## How it works

### The two-layer stack, per topic

For each joined `TopicId` there is one `topic::State<PI, R>` composed of two sub-machines ([`topic.rs`][g-topic], lines 206–213):

- `swarm: hyparview::State<PI, RG>` — the membership layer, holding `active_view` and `passive_view` as `IndexSet<PI>` (an insertion-ordered set that supports O(1) random pick-by-index and swap-remove) plus `pending_neighbor_requests`, `peer_data`, and `alive_disconnect_peers` ([`hyparview.rs`][g-hyparview], lines 229–253).
- `gossip: plumtree::State<PI>` — the broadcast layer, holding `eager_push_peers` and `lazy_push_peers` as `BTreeSet<PI>`, a `lazy_push_queue`, a `missing_messages` map, and two time-bounded caches ([`plumtree.rs`][g-plumtree], lines 349–383).

The protocol is generic over the peer identity via a trait ([`proto.rs`][g-proto], lines 85–89):

```rust
// iroh-gossip/src/proto.rs:85-89 (verbatim)
pub trait PeerIdentity: Hash + Eq + Ord + Copy + fmt::Debug + Serialize + DeserializeOwned {}
```

In the iroh instantiation `PI = PublicKey` (the ed25519 verifying key that _is_ the `EndpointId`, [`iroh-base` `key.rs`][iroh-key], line 70). Addresses never enter `proto/`: a peer's transport coordinates travel as an opaque `PeerData(Bytes)` ([`proto.rs`][g-proto], lines 95–97) carried on membership messages, which the net layer decodes into an `AddrInfo`.

### The sans-io interface

The entire protocol is one function. `proto::State::handle` takes an input event, the current instant, and an optional metrics sink, and returns a _lazy iterator of output events_ the caller must execute ([`state.rs`][g-state], lines 233–238):

```rust
// iroh-gossip/src/proto/state.rs:233-238 (verbatim)
pub fn handle(
    &mut self,
    event: InEvent<PI>,
    now: Instant,
    metrics: Option<&Metrics>,
) -> impl Iterator<Item = OutEvent<PI>> + '_ + use<'_, PI, R> {
```

The input and output alphabets are small and closed ([`topic.rs`][g-topic], lines 21–47):

```rust
// iroh-gossip/src/proto/topic.rs:21-47 (verbatim, doc comments trimmed)
pub enum InEvent<PI> {
    RecvMessage(PI, Message<PI>),   // a frame arrived from the network
    Command(Command<PI>),           // Join(Vec<PI>) | Broadcast(Bytes, Scope) | Quit
    TimerExpired(Timer<PI>),        // a previously-scheduled timer fired
    PeerDisconnected(PI),           // transport-level connection dropped
    UpdatePeerData(PeerData),       // our own address info changed
}
pub enum OutEvent<PI> {
    SendMessage(PI, Message<PI>),   // transmit a frame to a peer
    EmitEvent(Event<PI>),           // deliver an app event (NeighborUp/Down, Received)
    ScheduleTimer(Duration, Timer<PI>), // runtime must fire TimerExpired after Duration
    DisconnectPeer(PI),             // close the transport connection to a peer
    PeerData(PI, PeerData),         // learned new address info for a peer
}
```

`Timer<PI>` is likewise pure data — a `TopicId` plus a `topic::Timer` that is one of the swarm timers (`DoShuffle`, `PendingNeighborRequest(PI)`) or the gossip timers (`SendGraft(MessageId)`, `DispatchLazyPush`, `EvictCache`) ([`state.rs`][g-state], lines 76–86; [`hyparview.rs`][g-hyparview], lines 62–65; [`plumtree.rs`][g-plumtree], lines 68–80). The runtime owns nothing but a timer queue and a set of connections; the protocol owns all the logic.

### HyParView membership state machine

A node keeps every peer in an implicit lifecycle relative to itself: _unknown_ → _passive_ (address-book only) → _pending-neighbor_ (a `Neighbor` request is outstanding) → _active_ (a live bidirectional connection). The `Join`/`ForwardJoin` random walk seeds membership; `Shuffle` walks keep the passive view fresh; failures trigger refill from the passive view. The full transition table ([`hyparview.rs`][g-hyparview]):

| #   | Trigger                                           | Transition / actions                                                                                                                                                                                                                               | Cite             |
| --- | ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- |
| 1   | `Command::Join(peer)`                             | send `Join(me_data)` to the bootstrap peer                                                                                                                                                                                                         | lines 322–327    |
| 2   | recv `Join(data)`                                 | force-add the joiner to the active view at `High` priority (evicting a random active peer if full — the evictee first gets a `ShuffleReply` then `Disconnect{alive:true}`); fan out `ForwardJoin{ttl: ARWL=6}` to every _other_ active peer        | 380–401, 694–726 |
| 3   | recv `ForwardJoin`                                | already active → renew via `Neighbor(High)`; `ttl==0` or `active_view.len() ≤ 1` → send `Neighbor(High)` to the joiner (paper deviation, below); `ttl == PRWL=3` → insert into passive view; else forward `ttl−1` to a random active peer ≠ sender | 403–448          |
| 4   | recv `Neighbor{priority}`                         | clear the pending flag; `High` always accepted (random eviction if full); `Low` accepted only if a slot is free, else reply `ShuffleReply` + `Disconnect{alive:true}`                                                                              | 450–460, 694–726 |
| 5   | recv `Shuffle`                                    | ttl expired or `active_view.len() ≤ 1` → absorb the sampled nodes into the passive view and reply `ShuffleReply` (same node count) directly to `origin`; else forward `ttl−1` to a random active peer ∉ {`origin`, sender}                         | 486–504          |
| 6   | recv `ShuffleReply`                               | absorb nodes into passive view; `refill_active_from_passive`                                                                                                                                                                                       | 523–528          |
| 7   | recv `Disconnect{alive}`                          | if active: remove (emit `NeighborDown`, keep in passive iff `alive`, mark `alive_disconnect_peers`) then refill; if passive and `alive`: mark `alive_disconnect`                                                                                   | 330–343, 639–680 |
| 8   | `PeerDisconnected` (transport)                    | if active: remove with reason `ConnectionClosed` (keep passive iff previously marked alive); else drop from passive + `peer_data` unless marked alive                                                                                              | 346–354          |
| 9   | timer `DoShuffle` (**every 60 s**)                | send `Shuffle{origin: me, nodes: 3 active + 4 passive + me, ttl: 6}` to one random active peer; re-arm                                                                                                                                             | 530–562          |
| 10  | timer `PendingNeighborRequest(peer)` (**500 ms**) | if still pending: **delete the candidate from the passive view** and try the next one                                                                                                                                                              | 632–637          |
| 11  | `Command::Quit`                                   | for each active peer: send a `ShuffleReply` (up to 7 nodes) then `Disconnect{alive:false}` + `DisconnectPeer`                                                                                                                                      | 356–378          |
| 12  | any message from a _non-active_ peer              | after handling, immediately `DisconnectPeer(from)` — walk-relay connections are ephemeral (the author flags doubt in a `TODO`)                                                                                                                     | 315–319          |

The configuration is entirely defaulted from the paper, with two "wild guess" timers ([`hyparview.rs`][g-hyparview], lines 197–221):

| Parameter                                                  | Default  | Source       |
| ---------------------------------------------------------- | -------- | ------------ |
| `active_view_capacity`                                     | 5        | paper p9     |
| `passive_view_capacity`                                    | 30       | paper p9     |
| `active_random_walk_length` (ARWL)                         | `Ttl(6)` | paper p9     |
| `passive_random_walk_length` (PRWL)                        | `Ttl(3)` | paper p9     |
| `shuffle_random_walk_length`                               | `Ttl(6)` | paper p9     |
| `shuffle_active_view_count` / `shuffle_passive_view_count` | 3 / 4    | paper p9     |
| `shuffle_interval`                                         | 60 s     | "Wild guess" |
| `neighbor_request_timeout`                                 | 500 ms   | "Wild guess" |

One deliberate divergence from the paper is called out in the code ([`hyparview.rs`][g-hyparview], lines 414–417):

> "Modification from paper: Instead of adding the peer directly to our active view, we only send the Neighbor message. We will add the peer to our active view once we receive a reply from our neighbor. This prevents us adding unreachable peers to our active view."

Another is a courtesy that is _not_ in the paper: every voluntary disconnect (eviction, low-priority denial, `Quit`) is preceded by a free `ShuffleReply` so the other side does not starve for peers ([`hyparview.rs`][g-hyparview], lines 363–366):

> "Before disconnecting, send a `ShuffleReply` with some of our nodes to prevent the other node from running out of connections. This is especially relevant if the other node just joined the swarm."

### Plumtree broadcast state machine

Plumtree operates on two independent axes. On the **peer axis**, every active neighbor is either eager or lazy (`add_eager`/`add_lazy` are mutually-exclusive moves, [`plumtree.rs`][g-plumtree], lines 691–700). On the **message axis**, a message id moves _unknown_ → _missing_ (an `IHave` was seen but the payload is not here yet) → _received_ (the id is cached for `message_id_retention`, the payload for `message_cache_retention`). A `MessageId` is `blake3(content)` — the content-address _is_ the id ([`plumtree.rs`][g-plumtree], lines 27–38). The full transition table:

| #   | Trigger                                                | Transition / actions                                                                                                                                                                                                                                                                                   | Cite             |
| --- | ------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------- |
| 1   | `Broadcast(data, Swarm)`                               | `id = blake3(data)`; record id (90 s) + cache payload (30 s); eager-push `Gossip{id, content, round 0}`; queue `IHave{id, round}` for lazy peers                                                                                                                                                       | lines 467–487    |
| 2   | recv `Gossip`, valid id, **duplicate**                 | demote sender to lazy; send `Prune`                                                                                                                                                                                                                                                                    | 504–506          |
| 3   | recv `Gossip`, valid id, **new** (Swarm)               | record id; `round+1`; cache payload; eager-push + lazy-push to _other_ peers; **tree optimization**: if a prior `IHave` for this id arrived with a round ≥ `optimization_threshold`(7) hops lower, `Graft` the IHave sender (→eager) and `Prune` the Gossip sender (→lazy); emit `Received` to the app | 509–544, 552–582 |
| 4   | recv `Gossip`, **invalid id** (`id ≠ blake3(content)`) | drop and `warn!` — a spoofed message id                                                                                                                                                                                                                                                                | 491–500          |
| 5   | recv `Prune`                                           | demote sender to lazy                                                                                                                                                                                                                                                                                  | 584–586          |
| 6   | recv `IHave(vec)`                                      | for each unseen id: push `(sender, round)` onto `missing_messages`; if no timer is armed for it, arm `SendGraft(id)` at **graft_timeout_1 = 80 ms**                                                                                                                                                    | 597–614          |
| 7   | timer `SendGraft(id)`                                  | if still missing: pop the first announcer, promote it to eager, send `Graft{id: Some(id), round}`; re-arm at **graft_timeout_2 = 40 ms** to fall through to the next announcer                                                                                                                         | 617–646          |
| 8   | recv `Graft{id?}`                                      | promote sender to eager; if `id` is set and the payload is still cached (≤30 s) reply with the `Gossip`, else debug-log a silent miss                                                                                                                                                                  | 649–661          |
| 9   | `NeighborUp` (from HyParView)                          | add to eager                                                                                                                                                                                                                                                                                           | 664–666          |
| 10  | `NeighborDown`                                         | drop from both eager and lazy; scrub the peer from `missing_messages`                                                                                                                                                                                                                                  | 672–679          |
| 11  | timer `DispatchLazyPush` (**5 ms**, armed on demand)   | drain `lazy_push_queue`, send chunked `IHave` batches                                                                                                                                                                                                                                                  | 447–461, 728–734 |
| 12  | timer `EvictCache` (**1 s**, self-re-arming)           | expire the payload cache (30 s) and id cache (90 s)                                                                                                                                                                                                                                                    | 681–688          |

The gossip parameters ([`plumtree.rs`][g-plumtree], lines 306–327):

| Parameter                                              | Default    |
| ------------------------------------------------------ | ---------- |
| `graft_timeout_1` (arm on `IHave`)                     | 80 ms      |
| `graft_timeout_2` (re-arm after `Graft`)               | 40 ms      |
| `dispatch_timeout` (lazy-push flush)                   | 5 ms       |
| `optimization_threshold`                               | `Round(7)` |
| `message_cache_retention` (payloads for Graft replies) | 30 s       |
| `message_id_retention` (dedup ids)                     | 90 s       |
| `cache_evict_interval`                                 | 1 s        |

A `Scope::Neighbors` broadcast (`DeliveryScope::Neighbors`) bypasses caching, rounds, `IHave`, and forwarding entirely — it is a direct eager-push that is delivered once but never relayed ([`plumtree.rs`][g-plumtree], lines 469–487, 509–544). It is the "tell my current neighbors, don't flood the swarm" primitive.

### Composition and multi-topic multiplexing

`topic::State::handle` demultiplexes a per-topic `InEvent` into the two sub-machines and — crucially — **forwards HyParView's `NeighborUp`/`NeighborDown` outputs straight into Plumtree's inputs within the same call**, so a new active neighbor becomes an eager peer immediately ([`topic.rs`][g-topic], lines 258–328). A `PeerDisconnected` is delivered to _both_ layers.

Above the topics, `proto::State` is a thin router ([`state.rs`][g-state], lines 154–162, 233–301): it holds `states: HashMap<TopicId, topic::State>` and `peer_topics: HashMap<PI, HashSet<TopicId>>`, routes topic-tagged events to the matching topic state, creates a topic state lazily on `Command::Join` (seeding a fresh child RNG from the parent), drops it after `Command::Quit`, and fans `PeerDisconnected`/`UpdatePeerData` to every topic. The one subtlety is that a `topic::OutEvent::DisconnectPeer` is filtered through `peer_topics` so that a single shared QUIC connection is only closed at the transport level when no other topic still needs the peer — although the filter's `list.remove(&topic) || list.is_empty()` logic looks incorrect (it tears the connection down whenever the topic _was_ present, regardless of other topics), and `peer_topics` is only populated on _received_ messages, never on sends ([`state.rs`][g-state], lines 319–328; treat as an upstream bug to verify — see [Weaknesses](#weaknesses)).

### The net layer: one actor, per-peer connections, per-topic streams

`net.rs` runs a single `Actor` task that owns `proto::State<PublicKey, StdRng>` outright — no locks, sole mutator ([`net.rs`][g-net], lines 206–213). The actor's `run` loop is a biased 9-arm `tokio::select!` ([`net.rs`][g-net], lines 383–479) over: the local control channel (shutdown / new inbound connection), the irpc request channel, the app command streams, our-own-address updates, dial completions, inbound protocol events, the timer queue, and the two `JoinSet`s reaping connection and subscriber tasks.

Transport shape: **one QUIC connection per remote peer**, shared across all topics. Within a connection, each `(topic, direction)` gets its own **unidirectional** stream. A send stream begins with exactly one `StreamHeader { topic_id }` frame ([`net/util.rs`][g-netutil], lines 58–89), after which frames carry only `topic::Message` — the topic id is not repeated per frame. A topic's stream is `finish()`ed after its `Disconnect` message ([`net/util.rs`][g-netutil], lines 295–307). Each connection runs `connection_loop = tokio::join!(send_loop, recv_loop)` as a task in a `JoinSet` ([`net.rs`][g-net], lines 545–561):

- The **send loop** lazily opens one uni stream per topic on first use, writes the header, then writes length-prefixed postcard frames pulled from a per-connection `mpsc` ([`net/util.rs`][g-netutil], lines 198–311).
- The **recv loop** accepts uni streams, reads each header, then reads frames from all streams concurrently via a `FuturesUnordered`, forwarding `InEvent::RecvMessage(peer, msg)` into the actor's `in_event` channel ([`net/util.rs`][g-netutil], lines 91–158).

Per-peer connection state is a two-state machine ([`net.rs`][g-net], lines 759–769):

```rust
// iroh-gossip/src/net.rs:759-769 (verbatim, doc comments trimmed)
enum PeerState {
    Pending {
        queue: Vec<ProtoMessage>,     // buffered until a dial completes
    },
    Active {
        active_send_tx: mpsc::Sender<ProtoMessage>,  // into this conn's send loop
        active_conn_id: ConnId,
        other_conns: Vec<ConnId>,     // superseded but still draining
    },
}
```

Duplicate connections are _kept, not rejected_: a second connection to the same peer becomes the new sender while the old one drains ([`net.rs`][g-net], lines 790–796):

> "We already have an active connection. We keep the old connection intact, but only use the new connection for sending from now on."

Dial-side, a `Dialer` spawns `endpoint.connect(endpoint_id, alpn)` per peer under a `CancellationToken`; a dial failure for a non-active peer injects `PeerDisconnected` so the membership machine can try another candidate ([`net.rs`][g-net], lines 435–444, 993–1070). Learned `PeerData` is decoded into `AddrInfo { relay_url, direct_addresses }` and fed into a `GossipAddressLookup` registered with the iroh endpoint, so a peer known only through gossip resolves through iroh's normal [address-lookup][discovery] machinery — entries expire after 5 minutes, evicted every 30 s ([`net.rs`][g-net], lines 188–195; [`net/address_lookup.rs`][g-addrlookup], lines 25–40).

The app surface (`api.rs`, built on [irpc][irpc] so the same API works in-process or over an RPC connection): `subscribe(topic, bootstrap)` yields a `GossipTopic = GossipSender + GossipReceiver`. The sender exposes `Broadcast`, `BroadcastNeighbors`, and `JoinPeers`; the receiver is a stream of `Event::{NeighborUp, NeighborDown, Received(Message), Lagged}`, tracks a client-side neighbor set, and `joined()` awaits the first `NeighborUp` ([`api.rs`][g-api], lines 170–330).

---

## Analysis

### Wire format & framing

Every byte on the wire is [`postcard`][postcard] inside a QUIC unidirectional stream; the topic id is factored out into the one-shot stream header rather than repeated per frame. The complete surface, cross-referenced from [wire-serialization][wire]:

- **ALPN**: `b"/iroh-gossip/1"` ([`net.rs`][g-net], line 45), overridable per instance so private swarms can namespace themselves; all peers of a network must agree.
- **Stream header**: one `StreamHeader { topic_id: [u8;32] }` per `(connection, topic, direction)` ([`net/util.rs`][g-netutil], lines 58–89), then a sequence of `topic::Message<PI>` frames.
- **Frame**: a 4-byte **big-endian `u32`** length prefix (`read_u32`/`write_u32`, [`net/util.rs`][g-netutil], lines 359, 390) followed by the postcard body. This matches [`iroh-docs`][docs-sync] framing but differs from QUIC varints and from blobs' framing — a third length dialect in the stack ([wire-serialization][wire]).
- **Size limits**: `DEFAULT_MAX_MESSAGE_SIZE = 4096`, hard floor `MIN_MAX_MESSAGE_SIZE = 512` ([`proto.rs`][g-proto], lines 68–71). The checks are asymmetric: read rejects `size > max` ([`net/util.rs`][g-netutil], lines 364–366) but write rejects `len >= max` ([`net/util.rs`][g-netutil], lines 383–385) — a one-byte discrepancy worth reproducing consciously or fixing.
- **Message enums** (postcard uses a `varint(u32)` discriminant in declaration order):
  - outer `topic::Message`: `Swarm = 0`, `Gossip = 1` ([`topic.rs`][g-topic], lines 92–97).
  - `hyparview::Message`: `Join = 0`, `ForwardJoin = 1`, `Shuffle = 2`, `ShuffleReply = 3`, `Neighbor = 4`, `Disconnect = 5` ([`hyparview.rs`][g-hyparview], lines 69–88). `Priority::High = 0`, `Low = 1`. `Disconnect` still carries an obsolete `_respond: bool` "kept in the struct to maintain wire compatibility".
  - `plumtree::Message`: `Gossip = 0`, `Prune = 1`, `Graft = 2`, `IHave = 3` ([`plumtree.rs`][g-plumtree], lines 137–149). `DeliveryScope::Swarm(Round) = 0`, `Neighbors = 1`.
  - Field encodings: `[u8;32]` is 32 raw bytes with no prefix; `Bytes`/`Vec` is a varint length + elements; `u16` (`Ttl`, `Round`) is a varint (≤ 3 bytes); `Option` is `0x00`/`0x01` + value; `bool` is one byte. So a `Prune` frame is `01 01` (`Gossip` outer tag, `Prune` inner tag) inside a 4-byte length prefix.
- **Max broadcast payload**: `max_message_size − postcard_header_size()`. `postcard_header_size()` is computed as the serialized size of `{topic: [u8;32], Gossip(Prune)}` minus one, i.e. `32 + 1 + 1 − 1 = 33` bytes ([`state.rs`][g-state], lines 48–58) — so the usable payload is `4096 − 33 = 4063` bytes at the default. This still reserves the 32-byte topic even though frames no longer carry it (a conservative holdover from the pre-stream-header framing).
- **`IHave` batching**: on the dispatch timer, queued `IHave`s are chunked at `chunk_len = (max_message_size − 1 − 2) / IHave::POSTCARD_MAX_SIZE` per `Message::IHave` frame, where `IHave::POSTCARD_MAX_SIZE = 32 (id) + 3 (round varint) = 35` — i.e. **116 `IHave`s per frame** at the 4096 default ([`plumtree.rs`][g-plumtree], lines 447–457).
- **`PeerData`** (iroh instantiation): postcard of `AddrInfo { relay_url: Option<RelayUrl>, direct_addresses: BTreeSet<SocketAddr> }`; empty bytes decode to default ([`net.rs`][g-net], lines 903–930).

### Cryptography & identity

**There is no cryptography inside the gossip protocol.** Gossip payloads are _unsigned_ and carry no author identity — the only integrity check is that a received `Gossip`'s claimed id equals `blake3(content)`, which detects a corrupted/spoofed _id_ but not a forged _message_ ([`plumtree.rs`][g-plumtree], lines 491–500). Peer authenticity is _per-hop only_: it comes entirely from the QUIC/TLS connection, whose peer identity is the ed25519 `EndpointId` (see [identity-crypto][identity-crypto] and [quic-transport][quic-transport]). The receiver knows only the previous hop, never the origin — the `Received` event's `delivered_from` field is documented as "not the peer that originally broadcasted the message, but the peer before us in the gossiping path" ([`plumtree.rs`][g-plumtree], lines 93–95).

The absence is itself the finding: any swarm member can inject a message that every other member will relay and deliver, attributed to no one. The only content-addressing property is the `MessageId = blake3(content)` used for dedup and `Graft` lookups. Applications that need authenticated broadcast must sign payloads themselves and treat gossip as an untrusted transport — which is exactly what [`iroh-docs`][docs-sync] does (its `Op::Put` carries a doubly-ed25519-signed `SignedEntry`, verified above the gossip layer).

### State machines & lifecycle

Three tiers of lifecycle, and — the key property — the innermost two are **fully sans-io** ([`proto.rs`][g-proto], line 1). The single entry point `proto::State::handle(InEvent, now, metrics) -> Iterator<OutEvent>` samples no clock (`now` is injected), performs no I/O, and draws randomness from an injected `Rng`; timers are `OutEvent::ScheduleTimer(Duration, Timer)` data that the runtime must return as `InEvent::TimerExpired(Timer)` ([`state.rs`][g-state], lines 76–86). Both the shuffle timer and the plumtree `EvictCache` timer _self-bootstrap_ on the first `handle()` call of any kind — the machines assume at least one input event before any timer exists ([`hyparview.rs`][g-hyparview], lines 291–298; [`plumtree.rs`][g-plumtree], lines 406–410).

- **Per-topic** (membership × broadcast): the HyParView and Plumtree tables above. A single `handle` call can walk a peer from unknown to eager and schedule several timers.
- **Multi-topic** (`state.rs`): topic state created on `Command::Join`, destroyed after `Command::Quit`; shared connections survive per-topic disconnects via the `peer_topics` filter (modulo the suspected bug).
- **Net-layer `PeerState`** (`net.rs`): `Pending{queue}` → `Active{send_tx, conn_id, other_conns}` on the first completed dial or accepted inbound connection ([`net.rs`][g-net], lines 525–561, 771–810). A second connection replaces the sender and parks the old id in `other_conns`; when the _active_ connection task finishes, the actor injects `PeerDisconnected` and closes the connection with code 0, reason `b"close from disconnect"` ([`net.rs`][g-net], lines 564–593). An `OutEvent::DisconnectPeer` drops the whole peer entry, whose dropped send channel triggers a graceful stream finish ([`net.rs`][g-net], lines 732–736).

Because the protocol layer is a deterministic function, the crate ships a discrete-event simulator (`proto/sim.rs`, 1,140 lines) that runs thousands of nodes on a virtual clock and asserts convergence — symmetric active views (`check_synchronicity`) and round statistics (single-sender at 100 peers: last-delivery-hop `ldh < 15`, relative-message-redundancy `rmr < 0.2`, [`tests/sim.rs`][g-testsim]). That simulator is directly reusable as a conformance oracle for a port (see below).

### Dependencies & coupling

| Crate                                                                                   | Depth                                                                                                                                            | Port implication                                                                                         |
| --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| [`postcard`][postcard]                                                                  | load-bearing (all frames, `PeerData`, `serialized_size`, `MaxSize` derive for `IHave` chunking)                                                  | reimplement postcard varint/enum/struct/`Option`/`Vec`/`[u8;N]` encoding in D — small and self-contained |
| [`blake3`][blake3]                                                                      | load-bearing (`MessageId = blake3(content)`, spoof check)                                                                                        | need blake3 in D (ImportC C binding or native) — same dependency as [blobs][index]/[bao-tree][index]     |
| [`indexmap`][indexmap] (`IndexSet<PI>`)                                                 | load-bearing semantics: O(1) random pick-by-index and swap-remove; iteration order affects `ForwardJoin` fan-out                                 | any array-backed set works; swap-remove order-perturbation is acceptable (selection is already random)   |
| `rand` (`StdRng`)                                                                       | uniform index pick + Fisher–Yates shuffle; seeded `ChaCha` in tests/sim                                                                          | any uniform RNG, kept injectable for deterministic simulation                                            |
| [`iroh`][iroh-key]                                                                      | API surface: `Endpoint`/`Connection`, `open_uni`/`accept_uni`, `finish`/`stopped`/`closed`, `close_reason`, the `AddressLookup` trait, `Watcher` | maps to the D port's [endpoint][endpoint] subsystem                                                      |
| [`irpc`][irpc]                                                                          | API plumbing only (a bidi-streaming `Join` RPC; in-process path + optional `noq` remote path)                                                    | replace with native API calls; the RPC veneer is optional                                                |
| `futures-concurrency` (`StreamGroup`)                                                   | mux of per-subscription command streams with stable keys                                                                                         | replace with per-subscription fiber or a polled list                                                     |
| `tokio` (`sync`, `io-util` only)                                                        | channels + `read_u32`/`write_u32` framing                                                                                                        | event-horizon channels/streams; note the BE-`u32` frame prefix                                           |
| `tokio-util` (`CancellationToken`)                                                      | dial cancellation                                                                                                                                | maps to `CancelContext`                                                                                  |
| `bytes`                                                                                 | zero-copy payload sharing (`Bytes` cloned into caches, events, and N send queues)                                                                | a ref-counted immutable buffer is essential — naive copies multiply a payload by its fan-out             |
| `n0-future`, `iroh-metrics`, `n0-error`, `derive_more`, `serde`, `hex`, `data-encoding` | shallow plumbing                                                                                                                                 | trivial                                                                                                  |

The protocol core depends on _nothing from iroh_ — `proto/` is generic over `PeerIdentity` and knows only opaque `PeerData`. All the iroh coupling (`EndpointId`, address lookup, QUIC streams) lives in `net/`. That clean cut is what makes `proto/` portable in isolation.

### Concurrency & I/O model

The whole crate's concurrency budget is: **1 actor task + 1 task per QUIC connection + 1 task per subscriber + 1 task per in-flight dial + 1 address-eviction task.** There is no `spawn_blocking` and no thread pool (blake3 over ≤4 KiB payloads runs inline). The primitives ([concurrency][concurrency] carries the workspace-wide inventory):

| Primitive                                                          | Cap                           | Purpose                                                                                                         |
| ------------------------------------------------------------------ | ----------------------------- | --------------------------------------------------------------------------------------------------------------- |
| main actor task (`AbortOnDropHandle`)                              | —                             | sole owner of `proto::State`, `peers`, `topics`, timers, dialer — no locks ([`net.rs`][g-net], lines 206–213)   |
| actor `tokio::select!` (biased, 9 arms)                            | —                             | the single park point multiplexing every channel/timer/JoinSet ([`net.rs`][g-net], lines 383–479)               |
| `mpsc` rpc / local / in_event                                      | 64 / 16 / **1024**            | irpc `Join`s / control / inbound `InEvent`s from all recv loops ([`net.rs`][g-net], lines 49–52)                |
| `mpsc` send (per connection)                                       | 64                            | outbound `ProtoMessage`s for one peer ([`net.rs`][g-net], line 526)                                             |
| `broadcast::Sender<ProtoEvent>` (per topic)                        | 256                           | fan-out of topic events to N subscribers; overflow → `Lagged` ([`net.rs`][g-net], lines 53–54, 822–831)         |
| irpc per-subscription channels                                     | commands 64 / events **2048** | app-facing publish/subscribe streams ([`api.rs`][g-api], lines 21–23)                                           |
| `JoinSet connection_tasks` / `topic_event_forwarders`              | —                             | one task per connection (`join!(send, recv)`) / per subscriber ([`net.rs`][g-net], lines 301–303, 545–561)      |
| `Dialer` (`JoinSet` + `CancellationToken` map)                     | —                             | one cancellable task per outbound dial ([`net.rs`][g-net], lines 993–1070)                                      |
| `Timers = TimerMap` (binary heap keyed by `Instant`, seq tiebreak) | —                             | all protocol timers; the actor drains everything `≤ now` per wakeup ([`net/util.rs`][g-netutil], lines 395–435) |
| `GossipAddressLookup`: `Arc<RwLock<BTreeMap>>` + evictor           | evict 30 s / retain 300 s     | learned peer addresses — **the only lock in the crate** ([`net/address_lookup.rs`][g-addrlookup], lines 25–89)  |

The `in_event` channel (cap 1024) is the backpressure valve: when it fills, all connection recv loops block awaiting the actor, so a slow actor exerts head-of-line blocking across peers — undocumented but structural. Subscriber fan-out uses a lag policy instead of blocking, so a slow _subscriber_ is dropped rather than stalling the loop ([`api.rs`][g-api], lines 393–396):

> "This is to prevent a single slow subscriber from blocking the dispatch loop. If a subscriber is lagging, it should be closed and re-opened."

### Mapping to event-horizon

Under [`sparkles:event-horizon`][eh-spec]'s default `single` topology — one loop, one thread, completion-first io*uring — this subsystem maps \_unusually* well, because its designers already did the hard separation for us. Six moves.

**1. `proto/` is a gift — port it verbatim as a pure D struct.** It is a genuine sans-io state machine (`handle(InEvent, now) -> OutEvent[]`, injected clock, injected RNG, timers-as-data). It needs no fibers, no I/O, no capabilities — just a value type and a caller-supplied output sink mirroring the Rust `IO<PI>` push trait. `PI` becomes a template parameter constrained like `PeerIdentity`:

```rust
// iroh-gossip/src/proto/state.rs:233-238 (verbatim) — the sans-io seam
pub fn handle(
    &mut self,
    event: InEvent<PI>,
    now: Instant,
    metrics: Option<&Metrics>,
) -> impl Iterator<Item = OutEvent<PI>> + '_ + use<'_, PI, R> {
```

```d
// proposed / sketch — a plain @safe value type; the caller owns the OutEvent sink
// (mirrors Rust's `IO<PI>` push trait) so `handle` never allocates a result vector.
// `now` is injected (MonoTime), `Rng` is injected, timers are data. No I/O here.
struct GossipState(PI, Rng)
if (isPeerIdentity!PI)
{
    HashMap!(TopicId, TopicState!(PI, Rng)) states;
    ConnsMap!PI peerTopics;
    Rng rng;

    // Attributes inferred: @safe, and @nogc/nothrow wherever the maps allow.
    void handle(Sink)(in InEvent!PI event, MonoTime now, ref Sink outbox)
        if (isOutEventSink!(Sink, PI));   // outbox.push(OutEvent!PI)
}
```

The determinism this buys is the same the Rust simulator exploits: drive `GossipState` from a `TestSched` + `TestClock` ([event-horizon][eh-spec] test doubles) and port `proto/sim.rs`'s `Network`/`TimedEventQueue` to get thousand-node convergence tests with zero real I/O. The timer heap (`TimerMap`, binary heap + insertion-order tiebreak) ports directly and is driven by a single in-ring `TIMEOUT` op re-armed to the earliest deadline — the actor only ever sleeps to `first()` and drains all expired timers on wake.

**2. The actor collapses into one fiber owning `proto::State`.** Under `single` topology there is nothing to lock: `Arc<Metrics>`, `Arc<Inner>`, and the `RwLock` in `GossipAddressLookup` all become plain fields. The biased 8-arm `select!` becomes the fiber's park point via [`race`][eh-spec]. But most of those arms are _channel receives_, and that collides head-on with event-horizon's recognized **O20 gap (no cross-fiber channel primitive)**. The cleanest D shape sidesteps the biggest channel entirely: the `in_event` `mpsc` (cap 1024) exists in Rust only to hand `&mut proto::State` exclusivity across recv loops — which single-threaded D ownership grants for free. A connection recv fiber can call a method on the gossip-state object _directly_ instead of sending an `InEvent` through a queue:

```rust
// iroh-gossip/src/net.rs:759-769 (verbatim) — per-peer connection state
enum PeerState {
    Pending { queue: Vec<ProtoMessage> },
    Active {
        active_send_tx: mpsc::Sender<ProtoMessage>,
        active_conn_id: ConnId,
        other_conns: Vec<ConnId>,
    },
}
```

```d
// proposed / sketch — no mpsc into a send loop; the peer entry holds the outbound
// stream handles directly and is mutated by the one owning fiber. `Buf` is the
// event-horizon move-only buffer handle; payloads are ref-counted, never copied
// per fan-out.
struct PeerState
{
    enum Kind { pending, active }
    Kind kind;
    SmallBuffer!(ProtoMessage, 8) queue;   // Pending: buffered until dial completes
    ConnId activeConnId;                    // Active: the current send stream owner
    SmallBuffer!(ConnId, 2) otherConns;     // superseded conns, still draining
    UniStreamMap streams;                   // one send stream per topic, lazily opened
}
```

Trade-off to preserve consciously: the 1024-deep `mpsc` _smooths bursts_. Direct calls remove that buffer, so a burst of inbound frames now runs `GossipState.handle` synchronously on the recv fiber. That is fine (handle is cheap and non-blocking), but there is no longer a place for the head-of-line backpressure the Rust design accepts — the port should decide backpressure explicitly (e.g. a bounded provided-buffer ring on the recv path).

**3. Per-connection tasks become a `Scope` with two child fibers.** `connection_loop = join!(send_loop, recv_loop)` maps to a [`Scope`][eh-spec] with two `fork`ed children joined at scope exit; the send loop's `finishing` `JoinSet` (awaiting `stream.stopped()` per topic, drained with a 5 s timeout) becomes `spawnDaemon`ed stopped-waiters plus a `withDeadline` drain on exit. The recv loop's `FuturesUnordered` over per-topic streams simplifies to one fiber per accepted uni stream, each calling back into the owning state. Scope exit-join is strictly stronger than tokio's `AbortOnDrop`, whose swallowed panics are a known hazard.

**4. `broadcast::Sender` per topic has no event-horizon equivalent (also O20).** Reimplement it as a per-topic list of bounded per-subscriber ring buffers with the documented lag policy: on overflow, drop the message and deliver a `Lagged` marker (Rust caps: actor-side broadcast 256, api-side events 2048). This is a small, self-contained primitive worth building once and reusing for [docs-sync][docs-sync]'s subscriber fan-out too.

**5. Address updates and dialing map to capability callbacks and forks.** The `endpoint.watch_addr().stream()` watcher (our own address changing → `UpdatePeerData`) has no watch primitive in event-horizon; model it as a coalescing 1-slot mailbox fed by the [socket][socket] subsystem, or a capability callback. The `Dialer` becomes a `fork` per dial inside the actor's scope with `CancellationToken` → `CancelContext`; the `next_conn()` "pending-forever-when-idle" trick disappears because a dial completion calls back into the owning state directly rather than being polled out of a `JoinSet`.

**6. No thread pool needed; drop-driven cleanup becomes explicit.** The crate never uses `spawn_blocking` — blake3 over ≤4 KiB payloads is fine inline on the loop thread, so the single-threaded model pays no CPU-offload penalty here (unlike [blobs][index], where blake3 over large content is a real concern). The one behavioral gap: tokio's topic GC is driven by _handle drops_ (`still_needed`, [`net.rs`][g-net], lines 833–839); D has no drop-on-await, so a subscriber closing must be an explicit event — model it via `onExit` RAII hooks on the subscriber's scope.

The net result: the pure `proto/` layer ports almost mechanically and gains a deterministic test harness for free; the `net/` layer shrinks (no `Arc`, no `Mutex`, one fewer channel) but forces the port to build two small missing primitives — a bounded SPSC/broadcast channel (O20) and a coalescing watch mailbox — that several other iroh subsystems also need. Those belong in the shared [D architecture migration][d-migration] plan, not in gossip alone.

---

## Strengths

- **A textbook sans-io core.** The entire protocol is `handle(InEvent, now) -> OutEvent[]` with injected time and randomness — no sockets, no clock reads, no allocation of I/O. This is the cleanest possible target for [event-horizon][eh-spec] and comes with a reusable discrete-event simulator as a conformance oracle.
- **Clean layer cut.** `proto/` depends on nothing from iroh (generic over `PeerIdentity`, opaque `PeerData`); all transport coupling is quarantined in `net/`. The core is portable in isolation.
- **Self-optimizing broadcast tree.** Plumtree's eager/lazy split converges to a low-redundancy spanning tree, and `Graft`-on-`IHave` continuously re-optimizes it toward lowest latency (`rmr < 0.2` at 100 peers in the crate's own tests).
- **Robust membership under churn.** HyParView's active/passive split with random-walk diffusion and passive-view refill gives auto-healing connectivity; the "wait for `Neighbor` reply before adding" deviation avoids poisoning the active view with unreachable peers.
- **Small, predictable footprint.** A 4096-byte default frame, one connection per peer shared across topics, a bounded timer heap, and a fixed handful of tasks — no unbounded growth, no thread pool.
- **Address-lookup integration, not addr-book stuffing.** Gossip registers its own `GossipAddressLookup` provider into the endpoint's [address-lookup][discovery] stack (5-minute retention), matching the iroh-1.0 discovery→address-lookup model rather than mutating a shared address book.

## Weaknesses

- **Unsigned messages.** No per-message signature or origin identity anywhere; only `blake3(content) == id` validation ([`plumtree.rs`][g-plumtree], lines 491–500). Any swarm member can inject a message the whole swarm relays and delivers, attributed to no one — authentication is the application's job.
- **Suspected cross-topic disconnect bug.** The shared-connection filter `list.remove(&topic) || list.is_empty()` ([`state.rs`][g-state], lines 319–328) tears down a peer's connection whenever _this_ topic used it, ignoring other topics; and `peer_topics` is populated only on received messages, never on sends. A port should implement the obvious intent (remove, then check empty) and verify upstream. Tests never exercise two topics sharing one connection.
- **Aggressive passive-view eviction.** A low-priority `Neighbor` candidate that misses the 500 ms `PendingNeighborRequest` timeout is _deleted from the passive view_ ([`hyparview.rs`][g-hyparview], lines 632–637) — the paper's "consider failed and remove" applied even to a merely-slow peer.
- **Bounded dedup window.** `message_id_retention` is 90 s; a message re-broadcast after 90 s is re-delivered. Exactly-once delivery is the application's responsibility, which the code implies but never documents.
- **Head-of-line backpressure across peers.** When the actor's `in_event` channel (cap 1024) fills, _all_ connection recv loops block — an undocumented structural coupling between unrelated peers.
- **Silent `Graft` misses and untested overflow.** A `Graft` whose payload has already been evicted (>30 s) fails silently with only a debug log ([`plumtree.rs`][g-plumtree], lines 649–661); `Round::next` is an unchecked `self.0 + 1` ([`plumtree.rs`][g-plumtree], lines 129–133), so behavior at 65535 hops is untested (unlike `Ttl`, which saturates). The simulator models latency and connection kills but _no packet loss_, so loss behavior at the proto layer is unexercised.
- **`Bytes` cloning fan-out.** A broadcast payload is cloned into the payload cache and into every eager-push send ([`plumtree.rs`][g-plumtree], lines 703–714); without a ref-counted buffer, a 4 KiB payload at fan-out 5 is memcpy'd six times.

## Key design decisions and trade-offs

| Decision                                                        | Rationale                                                                                                   | Trade-off                                                                                                                   |
| --------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| Sans-io state machine (`proto/`) + thin actor (`net/`)          | Protocol logic is deterministic, testable in a virtual-time simulator, and portable with no I/O coupling    | Two layers and an event-translation seam; the runtime must own the timer queue and re-inject `TimerExpired`                 |
| HyParView active(5)/passive(30) partial views + random walks    | Bounded connection count with auto-healing membership under churn; bidirectional-only active links          | Membership is eventually-consistent and probabilistic; parameters are paper defaults with "wild guess" timers               |
| Plumtree eager/lazy push with `Graft`-on-`IHave` optimization   | Payloads travel once per tree edge; the tree self-optimizes toward lowest latency; lazy set repairs gaps    | Redundancy grows when the broadcaster changes often; `Graft` recovery adds 80/40 ms latency tails                           |
| `MessageId = blake3(content)`, messages unsigned                | Content-addressed dedup and `Graft` lookup with no key management; integrity of the id is free              | No message authentication or origin identity; per-hop trust only, from QUIC/TLS                                             |
| One QUIC connection per peer, one uni stream per `(topic, dir)` | Connection reuse across topics; per-topic streams isolate flow control and let a topic finish independently | Topic id factored into a one-shot header — `postcard_header_size` still conservatively reserves 32 bytes it no longer sends |
| Keep duplicate connections (new sends, old drains)              | Deterministic simultaneous-connect handling without id-based tie-breaking                                   | Transient double connections and superseded-conn bookkeeping (`other_conns`)                                                |
| Single actor owns all state, no locks                           | `&mut` exclusivity via one task; a `1024`-deep `mpsc` smooths inbound bursts                                | Head-of-line blocking across peers when the inbox fills; a channel-per-everything structure to translate                    |
| Subscriber lag policy (drop + `Lagged`) instead of blocking     | A slow subscriber cannot stall the dispatch loop                                                            | Lossy delivery to lagging subscribers; the app must re-subscribe to catch up                                                |
| 4096-byte default frame (control-plane sizing)                  | Gossip is for small notifications; bulk data goes to [blobs][index]                                         | Unusable for large payloads; a broadcaster must chunk or delegate                                                           |

---

## Sources

- [`iroh-gossip/src/proto.rs`][g-proto] — crate docs (IO-less framing, HyParView/Plumtree overview), `PeerIdentity`, `PeerData`, size constants
- [`iroh-gossip/src/proto/state.rs`][g-state] — multi-topic router, the sans-io `handle` seam, `Timer`, `postcard_header_size`
- [`iroh-gossip/src/proto/topic.rs`][g-topic] — per-topic composition, `InEvent`/`OutEvent`/`Command`/`Timer`/`IO` interface
- [`iroh-gossip/src/proto/hyparview.rs`][g-hyparview] — membership state machine, `State`/`Message`/`Config`, paper deviations
- [`iroh-gossip/src/proto/plumtree.rs`][g-plumtree] — broadcast state machine, `Message`/`MessageId`/`Round`/caches, timers, tree optimization
- [`iroh-gossip/src/net.rs`][g-net] · [`net/util.rs`][g-netutil] · [`net/address_lookup.rs`][g-addrlookup] — ALPN, actor, `PeerState`, framing, address-lookup integration
- [`iroh-gossip/src/api.rs`][g-api] — irpc `subscribe`/`Broadcast` API, `GossipTopic`, subscriber lag policy
- [`iroh-base/src/key.rs`][iroh-key] — `PublicKey`/`EndpointId` (the concrete `PeerIdentity`)
- Leitão, Pereira, Rodrigues — [_HyParView_][hyparview] (DSN 2007) · [_Epidemic Broadcast Trees_][plumtree] (SRDS 2007)
- [postcard][postcard] · [blake3][blake3] · [indexmap][indexmap] · [irpc][irpc]
- Related pages: [Document Sync (iroh-docs)][docs-sync] · [QUIC Transport (noq)][quic-transport] · [Endpoint & Protocol Router][endpoint] · [Address Lookup (Discovery)][discovery] · [The Multipath Socket][socket] · [Identity & Cryptography][identity-crypto] · [Wire Formats & Serialization][wire] · [Tokio Concurrency Inventory][concurrency] · [D Architecture Migration][d-migration] · [Concepts][concepts] · [survey umbrella][index] · [async-io survey][async-io] · [Tokio (Rust)][tokio]

<!-- References -->

[index]: ./index.md
[concepts]: ./concepts.md
[identity-crypto]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[quic-transport]: ./quic-transport.md
[endpoint]: ./endpoint.md
[socket]: ./socket.md
[discovery]: ./discovery.md
[docs-sync]: ./docs-sync.md
[concurrency]: ./concurrency.md
[d-migration]: ./d-architecture-migration.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[async-io]: ../async-io/index.md
[tokio]: ../async-io/tokio.md
[gossip-repo]: https://github.com/n0-computer/iroh-gossip
[gossip-docs]: https://docs.rs/iroh-gossip/0.101.0/iroh_gossip/
[g-proto]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/proto.rs
[g-state]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/proto/state.rs
[g-topic]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/proto/topic.rs
[g-hyparview]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/proto/hyparview.rs
[g-plumtree]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/proto/plumtree.rs
[g-net]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/net.rs
[g-netutil]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/net/util.rs
[g-addrlookup]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/net/address_lookup.rs
[g-api]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/src/api.rs
[g-readme]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/README.md
[g-testsim]: https://github.com/n0-computer/iroh-gossip/blob/2ce78afe09d89d41d123f28eac19bdc831609cc8/tests/sim.rs
[iroh-key]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-base/src/key.rs#L70
[hyparview]: https://asc.di.fct.unl.pt/~jleitao/pdf/dsn07-leitao.pdf
[plumtree]: https://asc.di.fct.unl.pt/~jleitao/pdf/srds07-leitao.pdf
[postcard]: https://docs.rs/postcard/latest/postcard/
[blake3]: https://docs.rs/blake3/latest/blake3/
[indexmap]: https://docs.rs/indexmap/latest/indexmap/
[irpc]: https://docs.rs/irpc/0.17.0/irpc/
