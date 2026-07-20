# NAT Traversal & Address Discovery

iroh 1.0 punches through NATs entirely inside QUIC: three cooperating draft extensions — QUIC Address Discovery (the STUN replacement), QUIC Multipath, and n0's own NAT-traversal protocol (QNT) — coordinate a simultaneous-open `PATH_CHALLENGE`/`PATH_RESPONSE` exchange over the encrypted connection, with no DISCO side-protocol and no STUN packets on the wire.

| Field               | Value                                                                                                                                                                                                                                                  |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Crate(s)            | `noq-proto` (sans-io QNT/QAD/MP core), `noq` (async façade), `iroh` (the `RemoteStateActor` driver), `iroh-relay` (QAD server)                                                                                                                         |
| Version             | `noq-v1.0.1` (HEAD `340e9c7`, 2026-06-29); iroh `v1.0.1` (commit `22cac742ca`, 2026-07-03)                                                                                                                                                             |
| Repository          | [`n0-computer/noq`][noq-readme] · [`n0-computer/iroh`][iroh-repo]                                                                                                                                                                                      |
| Documentation       | [docs.rs/noq-proto][docs-noq-proto] · [docs.rs/iroh][docs-iroh]                                                                                                                                                                                        |
| ALPN(s)             | `/iroh-qad/0` (relay QAD server, [`ALPN_QUIC_ADDR_DISC`][relay-quic]); QNT itself has **no** distinct ALPN — it rides the normal iroh application connection                                                                                           |
| Approx. size (LoC)  | noq-proto QNT/QAD core ≈ 1,150 (`n0_nat_traversal.rs` 1,075 + `address_discovery.rs` 73), plus multipath additions in `frame.rs`/`paths.rs`/`connection/mod.rs`; iroh driver ≈ 1,530 (`remote_state.rs`)                                               |
| Category            | Connectivity                                                                                                                                                                                                                                           |
| Upstream spec/draft | [`draft-seemann-quic-nat-traversal-02`][draft-qnt] (QNT inspiration), [`draft-ietf-quic-multipath`][draft-multipath] (MP), [`draft-seemann-quic-address-discovery`][draft-qad] (QAD); [RFC 9000][rfc9000] §8.1 (amplification), §8.2 (path validation) |

> [!NOTE]
> This page covers the **NAT-traversal semantics**: the extensions, the frames, the round/probe/backoff
> state machine, and iroh's hole-punch orchestration. The QUIC dataplane those frames ride on — packet
> building, per-path CID machinery, congestion control, path scheduling — is [QUIC Transport (`noq`)][quic-transport].
> How punched paths are _chosen and consumed_ is [The Multipath Socket][socket]; where _candidate addresses_
> come from is [Address Lookup][discovery] and [Net Report][net-report]; the relay fallback is [The Relay Protocol][relay].

---

## Overview

### What it solves

Two iroh endpoints, each behind a NAT, want a direct UDP path between them. Neither can simply
`connect` to the other's advertised address: the NAT has no mapping for an unsolicited inbound packet,
and neither peer reliably knows its own _reflexive_ (post-NAT) address. The classic fix is
**simultaneous open** — both peers send to each other's reflexive address at the same time, so each
NAT sees the outbound packet as "the reply I was expecting" and installs a mapping. Coordinating that
requires (1) each peer learning its own reflexive address, (2) the peers exchanging those addresses,
and (3) both firing probes at the right moment.

iroh 0.x solved this with **DISCO**, a bespoke UDP side-protocol of magic ping/pong packets alongside
the QUIC traffic, plus **STUN** against relay servers to learn reflexive addresses. iroh 1.0 deletes
both. Everything now happens _inside_ the QUIC connection, expressed as QUIC frames on the encrypted
1-RTT dataplane:

- **Reflexive-address discovery** is [QUIC Address Discovery (QAD)][sec-qad]: the peer at the other end
  of a connection tells you the source address it observes for you, in an `OBSERVED_ADDRESS` frame.
  Against dedicated relay QAD servers (ALPN `/iroh-qad/0`) this fully replaces STUN.
- **Path punching** is n0's **NAT-traversal (QNT)** extension: `ADD_ADDRESS`/`REMOVE_ADDRESS`/`REACH_OUT`
  frames advertise candidate addresses, and off-path `PATH_CHALLENGE`/`PATH_RESPONSE` frames are the
  actual probes both peers fire simultaneously.
- **The punched hole becomes a path** via **QUIC Multipath (MP)**: a successful probe opens a new
  multipath _path_ on the validated 4-tuple, independently validated, congestion-controlled, and
  abandonable, that the connection can migrate onto or use in parallel with the relayed path.

The decisive architectural property is that **QNT lives inside the QUIC state machine**, not beside it.
A native D port cannot bolt hole-punching onto an off-the-shelf QUIC library: it must own a QUIC stack
that supports multipath, custom frames, and custom transport parameters. This is the single largest
reimplementation cost in the whole iroh port.

### Design philosophy

QNT is deliberately _n0's own_ protocol, not a faithful implementation of any IETF draft. From the
transport-parameter definition ([`transport_parameters.rs:731-732`][tparams]):

> _"inspired by https://www.ietf.org/archive/id/draft-seemann-quic-nat-traversal-02.html,
> simplified to n0's own protocol."_

The simplification shows up everywhere: fixed client/server roles instead of role negotiation, a
whimsical private transport-parameter id (`0x3d7f91120401`) and frame-id block (`0x3d7f90…0x3d7f94`)
rather than IETF-assigned codepoints, and a hand-tuned retry schedule. The design's second pillar is
that the protocol _engine_ is **sans-io**: `ClientState`/`ServerState` are plain value-mutating structs
whose methods return "frames to send" and "next timer deadline". No tasks, channels, locks, or timers
live inside `noq-proto`; the only "timer" is a `ConnTimer::NatTraversalProbeRetry` entry the driver is
told to arm ([`timer.rs`][timer]). That shape maps cleanly onto a single fiber owning a connection.

The third pillar is a candid amplification trade-off. The comment on the probe budget spells out the
tension between reliability, NAT behaviour, and abusing innocent third parties
([`n0_nat_traversal.rs:19-30`][nat]):

> _"Maximum number of times we send a NAT probe to the same remote address in a round. This is a
> trade-off between several factors: - Probe packets could be lost. This allows recovery. - We may
> need two probes to reach the NAT firewall to get through. - We may be sending probes to innocent
> bystanders on the internet. - A round never "finishes": probing of remotes only stops when: 1. A new
> round is started. 2. A probe was successful. 3. This number of attempts is exhausted. … With this we
> send probes for up to 4s by default."_

---

## How it works

### The three cooperating extensions

All three extensions are negotiated in the TLS handshake via QUIC transport parameters, and they
compose with a strict dependency: **QNT requires MP**. Setting the QNT limit auto-enables multipath
if it is not already on ([`config/transport.rs:452-457`][cfg-transport]):

```rust
// noq-proto/src/config/transport.rs:452-457
pub fn max_remote_nat_traversal_addresses(&mut self, max_addresses: u8) -> &mut Self {
    self.max_remote_nat_traversal_addresses = NonZeroU8::new(max_addresses);
    if max_addresses != 0 && self.max_concurrent_multipath_paths.is_none() {
        self.max_concurrent_multipath_paths(8);   // MP auto-enabled, capped at 8 paths
    }
    self
}
```

The negotiation is wired in `handle_peer_params` ([`connection/mod.rs:6693-6713`][conn-proto]): QNT
state is created **only if both peers sent the `N0NatTraversal` parameter AND multipath negotiated**.
The two limit values cross over — `max_local_addresses` (how many _we_ may advertise) is the value the
_remote_ sent, and `max_remote_addresses` (how many the remote may advertise to us) is the value _we_
sent. If QNT is requested but MP is missing, it logs and stays disabled.

### Negotiation: transport parameters

Each transport parameter is `varint(id) | varint(len) | value` in the handshake
([`transport_parameters.rs`][tparams]):

| Parameter             | Id (varint)      | Value                                                                 | Cite                                                                          |
| --------------------- | ---------------- | --------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| QAD `ObservedAddr`    | `0x9f81a176`     | `varint(role)`, role ∈ {`0`=send-only, `1`=receive-only, `2`=both}    | [`transport_parameters.rs:726`][tparams], [`address_discovery.rs:64-73`][qad] |
| MP `InitialMaxPathId` | `0x3e`           | `varint(path_id)` = max `PathId` this endpoint allows                 | [`transport_parameters.rs:729`][tparams]                                      |
| QNT `N0NatTraversal`  | `0x3d7f91120401` | fixed length `1`, one raw `u8` = `max_remote_nat_traversal_addresses` | [`transport_parameters.rs:733`][tparams]                                      |

The QNT parameter is encoded specially — `varint(id) | 0x01 | u8(max)` — a literal length byte `1`
followed by a raw `u8` rather than a varint. Decoding rejects `0` (the value is a `NonZeroU8`) and any
length other than `1` as `Malformed`. MP is "on" only if _both_ sides send `InitialMaxPathId`; the
effective ceiling is `min(local, remote)` ([`connection/mod.rs:6680-6691`][conn-proto]).
`max_concurrent_multipath_paths(n)` maps to `initial_max_path_id = n - 1` — a _count_ of paths, so N
paths means max id N−1. Changing a QAD role or the QNT max between a 0-RTT resumption and the live
connection is a `PROTOCOL_VIOLATION` ([`transport_parameters.rs:217-218`][tparams]).

iroh configures **8** concurrent multipath paths ([`MAX_MULTIPATH_PATHS`][iroh-socket]) and **32**
QNT addresses ([`MAX_QNT_ADDRESSES`][iroh-socket]), applied through the
[`QuicTransportConfigBuilder`][iroh-quic].

### QUIC Address Discovery: learning your reflexive address {#sec-qad}

QAD replaces STUN. A peer with QAD `send` whose peer has `receive`
([`Role::should_report`][qad], `address_discovery.rs:59-63`) attaches an `OBSERVED_ADDRESS` frame
reporting the source `SocketAddr` it sees for the peer. Emission is scheduled on
`PathData.pending.observed_address`, set whenever a path is created, migrated, or a
`PATH_CHALLENGE`/`PATH_RESPONSE` is sent ([`connection/mod.rs:6204-6231`][conn-proto]), and each report
carries a monotonic per-connection `next_observed_addr_seq_no`. On receipt, the report is validated
(must be negotiated, must be in the Data space), `PathData::update_observed_addr_report` keeps only the
highest-seq report per path, and a changed address emits `PathEvent::ObservedAddr{id, addr}`
([`paths.rs:613-638`][paths]).

iroh consumes QAD two ways:

1. **Dedicated relay QAD probes.** iroh opens connections to relay QAD servers with ALPN
   `/iroh-qad/0` ([`iroh-relay/src/quic.rs:10`][relay-quic]), tuned with a low `initial_rtt` of
   111 ms, purely to learn direct addresses for [net_report][net-report]. The QAD close code is
   `QUIC_ADDR_DISC_CLOSE_CODE = 1`.
2. **In-band on every connection.** Every regular iroh connection feeds
   `observed_external_addr` ([`noq/src/connection.rs:1643-1649`][conn-async]).

These reflexive addresses become the local candidate set that QNT advertises.

### QNT candidate exchange

Roles are **fixed by the QUIC client/server side, not by who is behind NAT**
([`n0_nat_traversal.rs:144-165`][nat]). The QUIC **client** runs `ClientState`; the QUIC **server**
runs `ServerState`. The role never flips.

- **The server advertises** its candidates to the client via `ADD_ADDRESS` frames (each with a
  monotonic `seq_no`) and withdraws them via `REMOVE_ADDRESS`. The client stores them keyed by `seq_no`
  in `ClientState::remote_addresses`, surfacing `Event::AddressAdded`/`AddressRemoved` to the
  application.
- **The client advertises** its own candidates to the server, but **only when it starts a round**, via
  `REACH_OUT` frames carrying the round number. The server does not persist client addresses outside a
  round.

Both sides feed local addresses with `add_nat_traversal_address`/`remove_nat_traversal_address`
([`connection/mod.rs:7101-7125`][conn-proto]); for the client these populate `local_addresses` (used
later in `REACH_OUT`), while for the server each returns an `ADD_ADDRESS` frame to queue.

### A NAT-traversal round: the hole-punch itself

A **round** is one coordinated burst of probing, always **started by the client** via
`initiate_nat_traversal_round` ([`n0_nat_traversal.rs:456-506`][nat],
[`connection/mod.rs:7155-7181`][conn-proto]):

1. Increment `round`, reset `attempt = 0`, clear `sent_challenges` and `pending_probes`.
2. For every known remote (server) candidate, enqueue a probe (`pending_probes`) and set its
   `ProbeState::Active(MAX_NAT_PROBE_ATTEMPTS - 1)`. IPv6 candidates on an IPv4-only socket are skipped
   (`Active(0)`).
3. Build `REACH_OUT` frames from the client's `local_addresses` (all carrying the new `round`) and
   queue them.
4. Arm the `NatTraversalProbeRetry` conn-timer at `now + retry_delay`.

When the server receives a `REACH_OUT` with a **higher** round
([`n0_nat_traversal.rs:789-822`][nat]), it adopts the new round, clears its per-round state, records
the client's address in `remotes`, enqueues a probe back to it, and arms **its own**
`NatTraversalProbeRetry` timer. **Both peers now probe each other simultaneously** — the
simultaneous-open that punches both NATs.

Each probe is an **off-path** `PATH_CHALLENGE` sent to the candidate address
([`send_nat_traversal_path_challenge`][conn-proto], `connection/mod.rs:2076-2130`):

- pull `next_probe_addr()` from `pending_probes`;
- require an existing **validated** path to hang the probe on, plus an active remote CID for that path;
- write `PATH_CHALLENGE(random u64 token)` into a fresh datagram destined to the _probe_ address (not
  the path's normal remote), and record `mark_probe_sent(remote, token)` so `sent_challenges[token] = remote`.

Two details are load-bearing. First, the probe is **not padded to 1200 bytes**, so a successful
response validates only the _address_, not the full path MTU ([`n0_nat_traversal.rs:288-291`][nat]):

> _"Returns true if it was a response to one of the NAT traversal probes and a path needs to be opened.
> Note that the NAT probes are not padded to 1200 bytes so only the address is validated, but not the
> entire path."_

Second, the off-path challenge is sent from `src_ip: None` and is **not congestion-controlled**
(off-path packets bypass the path's congestion window). These unpadded, uncontrolled datagrams _are_
the holes being punched.

When a probe reaches the peer, the peer sees a `PATH_CHALLENGE` on an unknown 4-tuple and queues an
off-path `PATH_RESPONSE` ([`paths.rs:846-884`][paths]), sent back **padded to `MIN_INITIAL_SIZE` (1200)**
via `send_off_path_path_response`. If the responder is _also_ a QNT client, it piggybacks its own
fresh `PATH_CHALLENGE` on that response to accelerate mutual validation
([`connection/mod.rs:2036-2039`][conn-proto]):

> _"If we are a client doing NAT traversal, always include a PATH_CHALLENGE with any off-path
> PATH_RESPONSE. No need to schedule any retries for this, if NAT traversal is taking place then this
> remote already is being probed with retries, this only speeds up a successful traversal."_

When _our_ probe's `PATH_RESPONSE` returns, `State::handle_path_response`
([`n0_nat_traversal.rs:610-659`][nat]) matches the token in `sent_challenges` against the source. On a
match it removes the challenge, marks the remote `ProbeState::Succeeded`, and — **on the client only** —
pushes the validated `FourTuple` onto `paths_to_be_opened`. The server just records success; multipath
rules forbid servers from opening paths ([`connection/mod.rs:570-572`][conn-proto]). The client then
drains `paths_to_be_opened` in `open_nat_traversed_paths` ([`connection/mod.rs:5676-5719`][conn-proto]),
calling `open_path_ensure(path, PathStatus::Backup)`. Path opening can be blocked on
`RemoteCidsExhausted` or `MaxPathIdReached`; those entries are re-queued and retried whenever new CIDs
or a higher `MAX_PATH_ID` arrive.

### Retry and backoff

A round never terminates on its own; probing a remote stops only when (1) a new round starts, (2) that
probe succeeds, or (3) `MAX_NAT_PROBE_ATTEMPTS = 9` is exhausted ([`n0_nat_traversal.rs:32`][nat]).
Each `NatTraversalProbeRetry` firing calls `queue_retries` (decrement remaining, re-enqueue probes),
then re-arms via `retry_delay` ([`connection/mod.rs:2471-2485`][conn-proto]).

`retry_delay` ([`n0_nat_traversal.rs:306-343`][nat]) is a capped exponential backoff scaled to
`TransportConfig::initial_rtt` (default **333 ms**, [`config/transport.rs:564`][cfg-transport]):

- `base = initial_rtt / 10` → 33.3 ms for the default;
- the interval before attempt `a` is the _increment_ of the exponential, `base · 2^(a-1)`, capped at
  `MAX_INTERVAL = 2 s` (`MAX_BACKOFF_EXPONENT = 8`);
- the observed sequence from the tests is `33.3, 66.6, 133.2, 266.4, 532.8, 1065.6, 2000 (cap)` ms
  ([`n0_nat_traversal.rs:1005-1008`][nat]) — "up to 4s by default";
- it returns `None` (arm no timer) once no remote has retries remaining.

### The punched path's multipath lifecycle

Once opened, the punched 4-tuple is an ordinary multipath path ([`paths.rs`][paths]). Even though the
QNT probe already validated the _address_, the new `PathId` still undergoes a **full on-path RFC 9000
§8.2 validation** before iroh sees it as usable: `ensure_path` marks it `pending_challenge`, the first
on-path `PATH_CHALLENGE` flips its `OpenStatus` from `Pending` to `Sent` and arms
`AbandonFromValidation` at `now + 3 × (pto_base + max_ack_delay)`, and a matching on-path
`PATH_RESPONSE` sets `validated = true`, emits `PathEvent::Established`, and seeds the initial RTT
([`connection/mod.rs:5604-5655`][conn-proto]). Path status is `Available` or `Backup`; the iroh driver
promotes the selected path to `Available` and leaves the rest `Backup`. A path is abandoned
(`PATH_ABANDON` frame) on idle timeout, validation failure, network change, remote abandon, or
application close; abandoning the last path arms a `NoAvailablePath` grace timer (3×PTO) and, if no
replacement opens, closes the connection with `NO_VIABLE_PATH`
([`connection/mod.rs:652-667`][conn-proto]). Full path lifecycle, scheduling and CID plumbing:
[QUIC Transport][quic-transport].

### The iroh driver: `RemoteStateActor`

`iroh/src/socket/remote_map/remote_state.rs` is the tokio actor that turns raw QNT/path primitives
into iroh's "one endpoint, possibly several connections and paths, pick the best" model. Per remote
`EndpointId` there is one `RemoteStateActor` driving a biased `tokio::select!` loop
([`remote_state.rs:272-332`][remote-state]) over: its inbox, per-connection `path_events` and
`nat_traversal_updates` streams, connection-close notifications, local direct-address changes,
scheduled hole-punch/path-open timers, address-lookup results, and a periodic `UPGRADE_INTERVAL`
(60 s) check.

Hole-punch orchestration is deliberately economical about _which_ connection punches
([`remote_state.rs:508-511`][remote-state]):

> _"Holepunching happens on the Connection with the lowest ConnId which is a client. - Both endpoints
> may initiate holepunching if both have a client connection. - Any opened paths are opened on all
> other connections without holepunching."_

- `update_qnt_candidates` diffs the current direct-address set against the connection's advertised QNT
  addresses and calls `add`/`remove_nat_traversal_address`, keeping noq's advertised set in sync.
- `trigger_holepunching` picks the lowest-`ConnId` client connection; if candidates are unchanged since
  the last attempt and it was recent, it defers via a `scheduled_holepunch` timer
  (`HOLEPUNCH_ATTEMPTS_INTERVAL = 5 s`); otherwise it calls `do_holepunching`.
- `do_holepunching` calls `conn.initiate_nat_traversal_round()`, records a `HolepunchAttempt`, and on
  `Multipath`/`NotEnoughAddresses` errors reschedules in 100 ms.
- Successful paths surface as `PathEvent::Established`; the actor registers the path, replays it onto
  all other connections (`open_path_on_all_conns`), and re-runs its biased-RTT `select_path`.

Re-hole-punch triggers: remote-candidate updates, local-address updates, a major network change, and
the periodic `check_connections` when no IP path is "good enough" (`GOOD_ENOUGH_LATENCY = 10 ms`).

The relevant iroh constants ([`iroh/src/socket.rs`][iroh-socket], [`remote_state.rs`][remote-state]):

| Constant                      | Value   | Role                                                       |
| ----------------------------- | ------- | ---------------------------------------------------------- |
| `MAX_MULTIPATH_PATHS`         | `8`     | concurrent multipath paths                                 |
| `MAX_QNT_ADDRESSES`           | `32`    | advertised QNT candidate addresses                         |
| `HEARTBEAT_INTERVAL`          | `5 s`   | multipath keep-alive ping                                  |
| `PATH_MAX_IDLE_TIMEOUT`       | `15 s`  | direct-path idle timeout (3× heartbeat)                    |
| `RELAY_PATH_MAX_IDLE_TIMEOUT` | `30 s`  | relayed-path idle timeout                                  |
| `HOLEPUNCH_ATTEMPTS_INTERVAL` | `5 s`   | min gap between hole-punch attempts (unchanged candidates) |
| `GOOD_ENOUGH_LATENCY`         | `10 ms` | below which a path is not upgraded                         |
| `UPGRADE_INTERVAL`            | `60 s`  | periodic path-upgrade check                                |
| `ACTOR_MAX_IDLE_TIMEOUT`      | `60 s`  | per-remote actor idle shutdown                             |

---

## Analysis

### Wire format & framing

All integers are QUIC varints unless a fixed width is stated; IPs are raw network-order bytes (4 or
16), ports are `u16` big-endian. There is no `postcard`/serde here — frames are hand-encoded via the
`Encodable`/`Decodable` traits ([`frame.rs`][frame]). See [Wire Formats & Serialization][wire] for how
this differs from iroh's `postcard` types.

A distinctive choice: **the address family is encoded in the frame type id**, not a discriminator byte.
`OBSERVED_ADDRESS`, `ADD_ADDRESS`, and `REACH_OUT` each have separate v4/v6 ids, and the decoder is told
`is_ipv6` from the id itself ([`frame.rs:1665-1692`][frame]).

| Frame                   | Type id (varint)                  | Body                                        | Cite                        |
| ----------------------- | --------------------------------- | ------------------------------------------- | --------------------------- |
| `PATH_CHALLENGE`        | `0x1a`                            | `u64` token (fixed 8 bytes)                 | [`frame.rs:81`][frame]      |
| `PATH_RESPONSE`         | `0x1b`                            | `u64` token                                 | [`frame.rs:83`][frame]      |
| `OBSERVED_ADDRESS`      | `0x9f81a6` (v4) / `0x9f81a7` (v6) | `varint(seq_no)` ‖ `ip(4/16)` ‖ `u16(port)` | [`frame.rs:100-103`][frame] |
| `ADD_ADDRESS`           | `0x3d7f90` (v4) / `0x3d7f91` (v6) | `varint(seq_no)` ‖ `ip` ‖ `u16(port)`       | [`frame.rs:126-129`][frame] |
| `REACH_OUT`             | `0x3d7f92` (v4) / `0x3d7f93` (v6) | `varint(round)` ‖ `ip` ‖ `u16(port)`        | [`frame.rs:130-133`][frame] |
| `REMOVE_ADDRESS`        | `0x3d7f94`                        | `varint(seq_no)`                            | [`frame.rs:134-135`][frame] |
| `PATH_ABANDON`          | `0x3e75`                          | `varint(path_id)` ‖ `error_code`            | [`frame.rs:109-110`][frame] |
| `PATH_STATUS_BACKUP`    | `0x3e76`                          | `varint(path_id)` ‖ `varint(status_seq_no)` | [`frame.rs:111-112`][frame] |
| `PATH_STATUS_AVAILABLE` | `0x3e77`                          | `varint(path_id)` ‖ `varint(status_seq_no)` | [`frame.rs:113-114`][frame] |
| `MAX_PATH_ID`           | `0x3e7a`                          | `varint(path_id)`                           | [`frame.rs:119-120`][frame] |
| `PATHS_BLOCKED`         | `0x3e7b`                          | `varint(path_id)`                           | [`frame.rs:121-122`][frame] |
| `PATH_CIDS_BLOCKED`     | `0x3e7c`                          | `varint(path_id)` ‖ `varint(count)`         | [`frame.rs:123`][frame]     |

QNT and QAD frames ride the normal packet dataplane, ordered inside `populate_packet` after the ACK and
`PATH_CHALLENGE`/`PATH_RESPONSE` frames but before `CRYPTO`/stream data
([`connection/mod.rs:6061-6540`][conn-proto]); the exact frame order and coalescing rules are in
[QUIC Transport][quic-transport]. The off-path probe datagram carries just the `PATH_CHALLENGE`
(unpadded); the off-path response carries the `PATH_RESPONSE` padded to 1200.

### Cryptography & identity

QNT introduces **no cryptography of its own** — this is a finding, and a sharp contrast to iroh 0.x's
DISCO, which had its own key exchange and authenticated magic packets. Every QNT and QAD frame is a
frame in the QUIC **Data (1-RTT) space**, protected by the connection's AEAD keys: they are encrypted
and authenticated by the same TLS 1.3 session that authenticates the peer's [EndpointId][identity-crypto].
An off-path `PATH_CHALLENGE` is a full QUIC short-header packet, sealed with the connection keys and
sent to a new candidate 4-tuple; there is no unauthenticated side-channel to spoof. Because noq is
multipath, the **`PathId` is mixed into the AEAD nonce** (via mainline rustls 0.23's
`encrypt_in_place_for_path`), so a packet on one path cannot be replayed as another path's — see
[QUIC Transport § crypto][quic-transport]. The `PATH_CHALLENGE` token itself is a random `u64` drawn
from the connection's RNG, and validation is by token match plus source-4-tuple.

Address validation and amplification is the security envelope hole-punching operates inside. QUIC's
§8.1 rule — until a peer's address is validated, a server may send it at most **3× the bytes it has
received** — is enforced _per path_ (`total_recvd · 3 < total_sent`, [`paths.rs:407-408`][paths]),
which matters precisely because hole-punching creates many unvalidated paths at once. The
unpadded-probe / padded-response asymmetry is the deliberate amplification trade-off in miniature: the
prober spends a small packet, and the responder's 1200-byte reply is bounded by that path's 3× budget.

The connection-establishment token machinery (Retry tokens, `NEW_TOKEN` validation tokens) is adjacent
but largely **dormant in stock iroh 1.0.1**. iroh depends on noq with `default-features = false` and
without the `bloom` feature, so `BloomTokenLog` is not even compiled and `ValidationTokenConfig::default()`
degrades to `NoneTokenLog` with `sent: 0` ([`config/mod.rs:519-531`][cfg-mod]): default iroh servers
send **zero** `NEW_TOKEN` frames and treat any received validation token as absent. The **Retry** half
is always live (a noq server may answer an Initial with a Retry packet under load; iroh's router exposes
it via `IncomingFilterOutcome::Retry`), binding the client's exact `ip:port` and valid for 15 s. iroh
freshly randomizes its token AEAD key (`RustlsTokenKey`) at every `Endpoint::bind`, so tokens never
survive a process restart. The reuse rule that matters for a port is anti-replay: a `TokenLog` "MUST
ensure that replay of tokens is prevented or limited" ([`token.rs:21-23`][token], quoting RFC 9000
§8.1.4), and `take` on the client store "must never be returned twice, as doing so can be used to
de-anonymize a client's traffic" ([`token.rs:87-89`][token]). Full token lifecycle:
[QUIC Transport][quic-transport].

### State machines & lifecycle

Seven state machines interlock. Three are the QNT core; the rest are the multipath and iroh-driver
lifecycles that a punched path flows through.

**SM-1 — QNT `State` (per connection).** `NotNegotiated` → `ClientSide(ClientState)` or
`ServerSide(ServerState)` on `handle_peer_params` if both transport parameters and MP are present; the
side is terminal and never flips ([`n0_nat_traversal.rs:144-165`][nat]).

**SM-2 — `ProbeState` per remote candidate.** `Active(n)` counts down remaining retries;
`queue_retries` decrements and re-enqueues; a matching `PATH_RESPONSE` moves it to `Succeeded`;
`Active(0)` stops probing that remote. `retry_delay` returns `None` once no remote has retries left.

**SM-3 — round progression (client).** `round` is monotonic (`saturating_add`); a new round cancels the
previous by clearing `sent_challenges`/`pending_probes`, so late `PATH_RESPONSE`s no-op. The server
tracks the client's `round`, ignores `REACH_OUT` for older rounds, and `PendingReachOutFrames` auto-drops
frames from stale rounds ([`spaces.rs:802-830`][spaces]).

**SM-4 — `OpenStatus` per path.** `Pending` → `Sent` (first on-path `PATH_CHALLENGE`; arms
`AbandonFromValidation` 3×PTO) → `Informed` (first matching on-path `PATH_RESPONSE`; emits
`Established`) ([`spaces.rs:498`][spaces], [`connection/mod.rs:5604-5655`][conn-proto]).

**SM-5/6 — path validation and lifecycle.** RFC 9000 §8.2 validation with `PathValidationFailed`,
`PathChallengeLost`, and `AbandonFromValidation` timers; then `Established → … → Abandoned{reason} →
(3×PTO drain) → Discarded`. Abandon reasons: `ApplicationClosed`, `ValidationFailed`, `TimedOut`,
`UnusableAfterNetworkChange`, `RemoteAbandoned` ([`paths.rs:1093-1112`][paths]). Detailed in
[QUIC Transport][quic-transport].

**SM-7 — iroh hole-punch scheduling.** Triggers (remote-candidate update, local-addr update, major
network change, `check_connections`) feed `trigger_holepunching`; a guard defers via
`scheduled_holepunch` (5 s) if candidates are unchanged and an attempt was recent; `do_holepunching`
reschedules on `Multipath`/`NotEnoughAddresses` in 100 ms; path-open blocked on CIDs re-queues via
`scheduled_open_path` (333 ms).

**Timing budget of one hole punch.** A default round fires the first probe immediately, then retries at
`33.3, 66.6, 133.2, 266.4, 532.8, 1065.6, 2000, 2000 ms` (9 attempts), spanning ≈4 s. If it fails, the
iroh driver waits `HOLEPUNCH_ATTEMPTS_INTERVAL = 5 s` before another round (unless candidates changed),
and rechecks path quality every `UPGRADE_INTERVAL = 60 s`. A successful probe then costs one more
on-path validation RTT (bounded by 3×PTO) before `Established`.

### Dependencies & coupling

| Dependency                                                                       | Depth                          | Notes for a D port                                                                                                                                                                                            |
| -------------------------------------------------------------------------------- | ------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `noq-proto` (the QUIC engine)                                                    | load-bearing                   | QNT/QAD/MP are _inside_ the QUIC state machine. Cannot bolt onto an off-the-shelf QUIC — must own a multipath QUIC stack with custom frames + transport parameters. The single biggest reimplementation cost. |
| `rustc_hash` (`FxHashMap`/`FxHashSet`)                                           | API-surface                    | Fast hash maps keyed on `VarInt`/`IpPort`/`u64`; any D map works.                                                                                                                                             |
| `bytes` (`Buf`/`BufMut`)                                                         | API-surface                    | Frame encode/decode; a bounded D writer over [`SmallBuffer`][eh-spec] suffices.                                                                                                                               |
| `tokio::sync::{broadcast, watch, mpsc, oneshot}`                                 | load-bearing (noq/iroh layers) | _These are_ the concurrency model; a port must redesign them (see below).                                                                                                                                     |
| `n0_future`/`tokio_stream` (`MergeUnbounded`, `FuturesUnordered`, `MaybeFuture`) | load-bearing                   | The actor's select-over-many-streams pattern; needs a fiber redesign.                                                                                                                                         |
| `iroh_base` (`EndpointId`, `TransportAddr`, `RelayUrl`)                          | load-bearing                   | Addressing types the driver keys on — see [Identity & Cryptography][identity-crypto].                                                                                                                         |
| [Address Lookup][discovery] / [net_report][net-report]                           | load-bearing (adjacent)        | Feed candidate + reflexive addresses; co-driven with QNT.                                                                                                                                                     |

Algorithms a D port must reimplement with no library shortcut: QUIC multipath path management,
per-path validation, the QNT round/attempt/backoff machine, off-path challenge/response plumbing, and
the transport-parameter/frame codecs. All the 0.x folklore — STUN, DISCO, ping/pong side-channels — is
**gone**; do not port it.

### Concurrency & I/O model

QNT itself is **fully sans-io**: `State`/`ClientState`/`ServerState` are plain structs mutated
synchronously inside `Connection`'s poll methods. There are no tasks, channels, locks, or timers
_inside_ `noq-proto`; timing is expressed as `Instant` deadlines returned via the `TimerTable`, and the
only QNT timer is the `ConnTimer::NatTraversalProbeRetry` entry ([`timer.rs`][timer]), fired by whoever
drives `handle_timeout`.

The concurrency lives one and two layers up. The async `noq` crate exposes QNT via
`tokio::sync::broadcast` channels (cap 32) for `path_events` and `nat_traversal_updates`, a
`watch::Sender<Option<SocketAddr>>` for `observed_external_addr`, and a `FxHashMap<PathId, watch::Sender<…>>`
resolving each `OpenPath` future ([`noq/src/connection.rs`][conn-async]). iroh's `RemoteStateActor` is a
tokio task (spawned in a `JoinSet`) with an `mpsc::channel(16)` inbox, a biased `tokio::select!` loop,
`MergeUnbounded` over per-connection broadcast streams, `FuturesUnordered` for connection-close
notifications, and two `MaybeFuture<sleep_until>` deferral timers ([`remote_state.rs`][remote-state]).
There is **no** `Mutex`/`RwLock` on the QNT path beyond the connection's internal `lock_and_wake`
single-threaded ownership handoff, and **no** `spawn_blocking` anywhere in the subsystem. See the full
[Tokio Concurrency Inventory][concurrency] for how these primitives are counted across iroh.

One I/O requirement is unusual: QNT off-path probes must be sent to **arbitrary candidate destinations**
(not the connection's normal remote), and the `FourTuple` carries an optional `local_ip` for source-IP
control. That needs per-packet destination override and (for `local_ip`) `sendmsg` with `IP_PKTINFO`.

### Mapping to event-horizon

The QNT core is close to an ideal fit for a sans-io D port: `ClientState`/`ServerState` are
value-mutating structs whose methods return "frames to send" and "next deadline", the `retry_delay`
math is pure integer arithmetic on `Duration`, and there is no allocation on the hot path once the maps
are sized. Under [event-horizon][eh-spec]'s default `single` topology, one fiber owns the `Connection`
value outright; the six pump methods become plain method calls, and the whole `TimerTable` collapses
(as the noq async wrapper already proves) to **one** in-ring `TIMEOUT` op re-armed to `timers.peek()`,
with `handle_timeout(now)` after each wake.

**The proto state ports 1:1 into `@nogc` D structs.** The Rust `ClientState`
([`n0_nat_traversal.rs:346`][nat]) alongside a proposed D shape:

```rust
// noq-proto/src/n0_nat_traversal.rs:346 (trimmed)
pub(crate) struct ClientState {
    max_remote_addresses: usize,
    max_local_addresses: usize,
    remote_addresses: FxHashMap<VarInt, (CanonicalIpPort, ProbeState)>,
    local_addresses: FxHashSet<CanonicalIpPort>,
    round: VarInt,
    attempt: u8,
    sent_challenges: FxHashMap<u64, IpPort>,
    pending_probes: FxHashSet<IpPort>,
    paths_to_be_opened: Vec<FourTuple>,
}
```

```d
// proposed / sketch — a plain value type owned by the connection fiber.
// Path counts are <= 8 (MAX_MULTIPATH_PATHS) and addresses <= 32
// (MAX_QNT_ADDRESSES), so fixed-capacity SmallBuffers beat hashmaps and
// keep the whole struct @nogc.
struct ClientState
{
    size_t maxRemoteAddresses;
    size_t maxLocalAddresses;
    SmallBuffer!(RemoteCandidate, 32) remoteAddresses;   // keyed by seqNo, linear scan
    SmallBuffer!(CanonicalIpPort, 32) localAddresses;
    VarInt round;
    ubyte attempt;
    SmallBuffer!(SentChallenge, 32) sentChallenges;      // token -> IpPort
    SmallBuffer!(IpPort, 32) pendingProbes;
    SmallBuffer!(FourTuple, 8) pathsToBeOpened;          // validated, awaiting openPath
}

struct RemoteCandidate { VarInt seqNo; CanonicalIpPort addr; ProbeState probe; }
struct SentChallenge   { ulong token; IpPort remote; }
```

**The retry schedule is `@safe pure nothrow @nogc` verbatim** — pure `Duration` arithmetic, ideal for
a [`TestClock`][eh-spec]-driven deterministic test that walks the backoff without any real time:

```d
// proposed / sketch — mirrors n0_nat_traversal.rs:306-343.
// Returns the delay before the given 1-based attempt, or none() to stop.
enum Duration MAX_INTERVAL = 2.seconds;
enum ubyte MAX_BACKOFF_EXPONENT = 8;

Nullable!Duration retryDelay(Duration initialRtt, ubyte attempt) @safe pure nothrow @nogc
{
    if (attempt == 0) return typeof(return).init;           // nothing to probe -> stop
    const base = initialRtt / 10;                           // 33.3 ms at the 333 ms default
    const exp = cast(uint) min(attempt - 1, MAX_BACKOFF_EXPONENT);
    const interval = base * (1UL << exp);                   // base * 2^(attempt-1)
    return nullable(interval < MAX_INTERVAL ? interval : MAX_INTERVAL);
}
```

The `NatTraversalProbeRetry` timer becomes an in-ring `TIMEOUT` op or a `withDeadline` cancel scope on
the connection fiber: the fiber sleeps until the deadline, then calls `queueRetries` and re-arms.
Panics-as-invariants (`path_data()` panics on an unknown `PathId`, state transitions assert legality)
map to `assert`/contract `in`-clauses, **not** `Expected` — these are defects (`Cause: die`), not
retryable errors.

**What has no event-horizon equivalent and needs new design:**

- **`tokio::sync::broadcast(32)` (`path_events`, `nat_traversal_updates`) and `watch` cells** — the
  cross-fiber channel gap ([open-issue O20][eh-spec]). Under `single` topology, everything runs on one
  loop, so the cleanest port replaces the broadcast with **direct method calls / a small single-threaded
  observer registry**: the connection fiber synchronously invokes the driver's handler instead of
  pushing to a channel. The `Lagged` back-pressure semantics (drop + report count) exist only because
  tokio has a cross-thread producer; a single-threaded port can drop the bounded buffer entirely. The
  `watch::Sender<Option<SocketAddr>>` for `observed_external_addr` becomes a single-value cell plus a
  `Waker`/notify list the reader awaits.
- **The `RemoteStateActor`'s `tokio::select!` over many merged streams** maps to **one fiber running a
  [`race`][eh-spec]/first-completion over its event sources** inside a [`Scope`][eh-spec]. Under
  single-thread ownership the actor can call directly into each connection's state instead of merging
  broadcast streams — there is no thread boundary to cross. `MaybeFuture<sleep_until>` → arm/disarm a
  deadline; `time::interval(UPGRADE_INTERVAL)` → a `repeat`/`Schedule` driver; the `JoinSet` of
  per-remote actors → one `Scope.fork` per `EndpointId`, joined at endpoint shutdown, with the actor
  idle-timeout expressed as a `withDeadline`. The `mpsc::channel(16)` inbox is the same O20 gap: for
  synchronous messages a capability-method call (endpoint fiber → remote-state handler) replaces the
  mailbox; only genuinely deferred work needs a queue.

```rust
// iroh: the actor loop (shape) — remote_state.rs:272-332
loop {
    tokio::select! { biased;
        msg = inbox.recv()          => { /* AddConnection, SendDatagram, NetworkChange, … */ }
        Some(ev) = path_events.next() => { /* Established -> register + replicate path */ }
        Some(ev) = addr_events.next() => { /* AddressAdded/Removed -> holepunch trigger */ }
        _ = &mut scheduled_holepunch  => { self.trigger_holepunching(); }
        _ = &mut scheduled_open_path  => { self.drain_pending_open_paths(); }
        _ = upgrade_interval.tick()   => { self.check_connections(); }
    }
}
```

```d
// proposed / sketch — one fiber owns the remote's state; no channels needed
// because every producer runs on the same loop under `single` topology.
void runRemote(ref Scope scope, ref RemoteState st) @safe
{
    scope.withDeadline(ACTOR_MAX_IDLE_TIMEOUT, {
        for (;;)
        {
            // race over the remote's event sources; the loser branches are cancelled.
            final switch (race(
                st.inbox.recv(),               // capability-method call, not mpsc
                st.nextPathEvent(),            // direct call into owned connections
                st.holepunchDeadline(),        // arm/disarm, replaces MaybeFuture
                st.upgradeTick()))             // Schedule.recurs(UPGRADE_INTERVAL)
            {
                case Inbox:      st.handleMessage(); break;
                case PathEvent:  st.registerAndReplicatePath(); break;
                case Holepunch:  st.triggerHolepunching(); break;
                case Upgrade:    st.checkConnections(); break;
            }
        }
    });
}
```

**Single-threaded implications.** No `Arc<Mutex<Connection>>` is needed: noq's `lock_and_wake` guard
exists only because tokio may poll the connection from arbitrary threads. Under `single` topology the
connection is owned by one fiber; the lock is zero code. But the **CPU cost stays on the loop thread** —
off-path probe construction, AEAD sealing of each probe packet, and path validation all run inline on
the single event-loop fiber, with no `spawn_blocking` escape hatch (event-horizon has no thread pool;
this is fine here because QNT is not CPU-heavy). The one genuine gap is **UDP off-path sends**: probes
need per-packet destination override, and `FourTuple.local_ip` needs source-IP control. Event-horizon's
`msghdr`-based `sendmsg`/`recvmsg` is [open-issue O19][eh-spec], so the NAT-probe path is a concrete
motivating case for closing it — the current tier-B verbs cannot express a per-datagram destination or
`IP_PKTINFO` source. The broader tokio → event-horizon translation is in
[D Architecture Migration][d-migration].

---

## Strengths

- **One security domain.** Hole-punching frames are ordinary QUIC frames on the encrypted, authenticated
  1-RTT dataplane — no separate DISCO keys, no unauthenticated magic packets, no STUN. An attacker
  cannot forge a `REACH_OUT` or `ADD_ADDRESS` without breaking the QUIC session.
- **Sans-io core.** `noq-proto`'s QNT engine is a pure state machine (no tasks, channels, locks, or
  timers), deterministically testable with injected time and RNG — an excellent fit for a single-fiber
  D port and `TestClock`-driven simulation.
- **A punched hole is a first-class path.** A successful probe yields a real multipath `PathId` with its
  own validation, congestion control, and idle timeout, that the connection can fail over to or run in
  parallel with the relayed path — not a bolted-on side-channel.
- **Reuses QUIC's amplification defenses.** Per-path 3× anti-amplification, the unpadded-probe /
  padded-response asymmetry, and existing address-validation machinery bound abuse without new
  protocol surface.
- **Economical orchestration.** iroh hole-punches on only the lowest-`ConnId` client connection and
  replicates opened paths onto the others without re-punching, keeping probe volume low.

## Weaknesses

- **QUIC is now load-bearing for connectivity.** Because QNT/QAD/MP live inside the QUIC state machine,
  a port cannot use an off-the-shelf QUIC library — it must reimplement a multipath QUIC stack with
  custom frames and transport parameters. This is the port's dominant cost.
- **Private, non-interoperable codepoints.** The QNT transport-parameter id (`0x3d7f91120401`) and frame
  ids (`0x3d7f90…`) are n0-private; QNT is "simplified to n0's own protocol", so there is no external
  spec to conform to — only the source is authoritative, and it can change between minor versions.
- **Amplification vs. speed is a live tension.** Unpadded probes validate only the address, and probes
  are sent to arbitrary candidate addresses (possibly "innocent bystanders on the internet"); the safety
  argument rests on the 9-attempt cap and per-path 3× limit rather than a proof.
- **Concurrency-heavy driver.** The iroh `RemoteStateActor` leans on `broadcast`/`watch`/`mpsc`/`JoinSet`
  and stream-merging combinators with no direct event-horizon equivalents — the redesign is real work,
  even though single-threading simplifies it.
- **Unbounded `paths_to_be_opened`.** There is an acknowledged `TODO` that validated-but-unopened paths
  are bounded only by the candidate-set size, with no time limit ([`n0_nat_traversal.rs:399`][nat]).
- **Server single-shot probes are not locally retried** to un-advertised client addresses — the peer is
  expected to keep retrying its challenges ([`n0_nat_traversal.rs:642-646`][nat]), so behaviour under
  correlated loss is subtle.

## Key design decisions and trade-offs

| Decision                                                              | Rationale                                                                               | Trade-off                                                                                               |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| NAT traversal entirely inside QUIC (no DISCO/STUN)                    | One authenticated/encrypted security domain; no side-protocol to secure separately      | QUIC becomes load-bearing for connectivity; a port must own a multipath QUIC stack                      |
| QAD (`OBSERVED_ADDRESS`) replaces STUN                                | Learn reflexive address from the peer/relay in-band; no separate STUN server or packets | Requires the peer/relay to support QAD; a dedicated `/iroh-qad/0` relay path is still needed            |
| QNT roles fixed by QUIC client/server side                            | No role negotiation; only the client opens paths (multipath rule)                       | Who's behind NAT is irrelevant to who initiates; both must still probe simultaneously                   |
| Both peers probe simultaneously (simultaneous open)                   | Punches both NATs at once; each NAT sees the outbound as an expected reply              | Needs coordinated timing (rounds); a lost `REACH_OUT` delays the whole round                            |
| Probe `PATH_CHALLENGE` unpadded; response padded to 1200              | Cheap probes; validate the address fast without paying full-MTU cost per attempt        | Only the address (not the path MTU) is validated; response is the amplification-bounded side            |
| Capped exponential backoff scaled to `initial_rtt` (≈4 s, 9 attempts) | Recovers from loss and NAT quirks without hammering bystanders                          | Fixed budget; very lossy or slow paths may exhaust attempts before punching                             |
| QNT auto-enables multipath (8 paths) when set                         | A punched hole must become a real path; MP is a hard prerequisite                       | Turning on QNT silently turns on MP with its CID/path overhead                                          |
| iroh punches only on the lowest-`ConnId` client connection            | Minimizes probe volume; opened paths are replicated to other connections                | A single connection's failure to punch blocks the shared result until re-triggered                      |
| Sans-io proto core, concurrency in the wrapper/driver                 | Deterministic, portable engine; async model is swappable                                | The wrapper's `broadcast`/`watch`/`mpsc`/`select!` layer is bespoke and must be re-designed per runtime |

---

## Sources

Primary source — `noq-proto` (QNT/QAD/MP core):

- [`noq-proto/src/n0_nat_traversal.rs`][nat] — the QNT sans-io state machine: `State`/`ClientState`/`ServerState`, `ProbeState`, rounds, `retry_delay`, `MAX_NAT_PROBE_ATTEMPTS`.
- [`noq-proto/src/address_discovery.rs`][qad] — QAD `Role` (send/receive) and its transport-parameter varint mapping.
- [`noq-proto/src/frame.rs`][frame] — `FrameType` id table and the `ObservedAddr`/`AddAddress`/`ReachOut`/`RemoveAddress`/`PathChallenge`/`PathResponse`/multipath frame structs.
- [`noq-proto/src/transport_parameters.rs`][tparams] — QAD/MP/QNT parameter ids and (de)serialization.
- [`noq-proto/src/config/transport.rs`][cfg-transport] — QNT/MP config knobs, MP auto-enable, default `initial_rtt`.
- [`noq-proto/src/config/mod.rs`][cfg-mod] — token/validation config defaults (`bloom`-gated).
- [`noq-proto/src/connection/mod.rs`][conn-proto] — the driver: `send_nat_traversal_path_challenge`, off-path sends, `open_nat_traversed_paths`, frame handling, `NatTraversalProbeRetry`.
- [`noq-proto/src/connection/paths.rs`][paths] — `PathData`, `PathStatus`, `PathEvent`, path validation, anti-amplification, off-path `PathResponses`.
- [`noq-proto/src/connection/spaces.rs`][spaces] — `OpenStatus`, `PendingReachOutFrames`, pending QNT frame sets.
- [`noq-proto/src/connection/timer.rs`][timer] — `ConnTimer::NatTraversalProbeRetry` and the `TimerTable`.
- [`noq-proto/src/token.rs`][token] — `TokenLog`/`TokenStore` traits, anti-replay contract (RFC 9000 §8.1.4).

Primary source — iroh & relay:

- [`iroh/src/socket/remote_map/remote_state.rs`][remote-state] — the `RemoteStateActor` hole-punch driver.
- [`iroh/src/endpoint/quic.rs`][iroh-quic] — `QuicTransportConfigBuilder` wiring QNT/QAD/MP defaults.
- [`iroh/src/socket.rs`][iroh-socket] — `MAX_MULTIPATH_PATHS`, `MAX_QNT_ADDRESSES`, timeouts.
- [`iroh/src/net_report.rs`][iroh-netreport] — QAD probe consumers.
- [`iroh-relay/src/quic.rs`][relay-quic] — the QAD server (`ALPN_QUIC_ADDR_DISC = "/iroh-qad/0"`).

Specs & drafts:

- [`draft-seemann-quic-nat-traversal`][draft-qnt] (QNT inspiration, `-02`), [`draft-ietf-quic-multipath`][draft-multipath], [`draft-seemann-quic-address-discovery`][draft-qad]; [RFC 9000][rfc9000] §8.1 (amplification), §8.2 (path validation); [RFC 9002][rfc9002] (loss/PTO).

Related pages: [Concepts & Vocabulary][concepts] · [QUIC Transport][quic-transport] · [The Multipath Socket][socket] · [The Relay Protocol][relay] · [Address Lookup][discovery] · [Net Report][net-report] · [Identity & Cryptography][identity-crypto] · [Wire Formats][wire] · [Endpoint & Protocol Router][endpoint] · [Tokio Concurrency Inventory][concurrency] · [D Architecture Migration][d-migration] · umbrella: [Iroh survey][index] · [event-horizon spec][eh-spec] · async-io: [Tokio][tokio], [Glommio][glommio].

<!-- References -->

[sec-qad]: #sec-qad
[nat]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/n0_nat_traversal.rs
[qad]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/address_discovery.rs
[frame]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/frame.rs
[tparams]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/transport_parameters.rs
[cfg-transport]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/config/transport.rs
[cfg-mod]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/config/mod.rs
[conn-proto]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/mod.rs
[paths]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/paths.rs
[spaces]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/spaces.rs
[timer]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/connection/timer.rs
[token]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/token.rs
[conn-async]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq/src/connection.rs
[remote-state]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs
[iroh-quic]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/quic.rs
[iroh-socket]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs
[iroh-netreport]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report.rs
[relay-quic]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/quic.rs
[noq-readme]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/README.md
[iroh-repo]: https://github.com/n0-computer/iroh/tree/22cac742ca5e84da4542681e14b2d23b74c8330e
[docs-noq-proto]: https://docs.rs/noq-proto/1.0.1/noq_proto/
[docs-iroh]: https://docs.rs/iroh/1.0.1/iroh/
[rfc9000]: https://www.rfc-editor.org/rfc/rfc9000.html
[rfc9002]: https://www.rfc-editor.org/rfc/rfc9002.html
[draft-multipath]: https://datatracker.ietf.org/doc/draft-ietf-quic-multipath/
[draft-qad]: https://datatracker.ietf.org/doc/draft-seemann-quic-address-discovery/
[draft-qnt]: https://datatracker.ietf.org/doc/draft-seemann-quic-nat-traversal/
[index]: ./index.md
[concepts]: ./concepts.md
[identity-crypto]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[quic-transport]: ./quic-transport.md
[endpoint]: ./endpoint.md
[socket]: ./socket.md
[relay]: ./relay.md
[discovery]: ./discovery.md
[net-report]: ./net-report.md
[concurrency]: ./concurrency.md
[d-migration]: ./d-architecture-migration.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[tokio]: ../async-io/tokio.md
[glommio]: ../async-io/glommio.md
