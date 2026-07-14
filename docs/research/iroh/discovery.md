# Address Lookup (Discovery)

The subsystem that turns a bare [`EndpointId`][concepts] into dialable transport addresses — by publishing and resolving [BEP-44][bep44]-signed DNS packets over [pkarr] relays and the Domain Name System, so a peer can be reached knowing only its public key.

| Field               | Value                                                                                                                                                                           |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate(s)            | [`iroh`][repo] (`address_lookup` module), [`iroh-dns`][repo] (record + resolver), [`iroh-dns-server`][repo] (relay + authoritative DNS)                                         |
| Version             | `iroh` `v1.0.1` (commit `22cac742`); `iroh-dns` `1.0.1`; `iroh-dns-server` `1.0.1`                                                                                              |
| Repository          | [n0-computer/iroh][repo]                                                                                                                                                        |
| Documentation       | [docs.rs/iroh · `address_lookup`][docs-iroh] · [docs.rs/iroh-dns][docs-dns] · [docs.rs/iroh-dns-server][docs-dns-server]                                                        |
| ALPN(s)             | None — resolution rides DNS (UDP/TCP) and pkarr HTTP(S) `PUT`/`GET`, not an ALPN-negotiated QUIC protocol. Dialing the resolved address is [noq][quic]'s job, not this layer's. |
| Approx. size (LoC)  | client (`iroh/src/address_lookup*` + `iroh-dns/src`) ≈ 5,050; server (`iroh-dns-server/src`) ≈ 4,006                                                                            |
| Category            | Connectivity                                                                                                                                                                    |
| Upstream spec/draft | [pkarr]; BitTorrent [BEP-44][bep44] (mutable items); [RFC 1035][rfc1035] (DNS wire); [RFC 1464][rfc1464] (`key=value` TXT); [RFC 8484][rfc8484] (DoH); [z-base-32][zb32]        |

> [!NOTE]
> **Naming.** What iroh 0.x called _discovery_ is, in 1.0, **address lookup**
> (`iroh/src/address_lookup.rs`). `Discovery` → [`AddressLookup`][al-trait];
> `DiscoveryItem` → [`Item`][al-item]; `NodeId`/`NodeInfo`/`NodeData` →
> `EndpointId`/`EndpointInfo`/`EndpointData`. The DISCO UDP side-protocol and STUN of
> 0.x are gone (see [NAT Traversal][nat]); address lookup is now purely a
> _name → address_ directory, orthogonal to hole-punching.

---

## Overview

### What it solves

An iroh [`EndpointId`][concepts] is an ed25519 public key — a stable, self-certifying
name that says nothing about _where_ the endpoint is. To open a QUIC connection you
need transport addresses: a home [relay][relay] URL and/or direct `IP:port` candidates.
Address lookup is the directory that maps the key to those addresses, in both
directions:

- **Publish** — an endpoint signs its own current addressing info under its key and
  pushes it to a directory, so others can find it. Fire-and-forget, re-run whenever the
  addresses change.
- **Resolve** — given an `EndpointId`, fetch the latest signed record, verify it against
  the key, and feed the addresses into the dialer.

The design constraint is that the record must be **self-authenticating**: a resolver,
relay, or DNS cache is untrusted infrastructure that can store and serve the bytes but
must not be able to forge them. iroh solves this with [pkarr] — _Public-Key Addressable
Resource Records_ — where the payload is an ordinary DNS reply packet wrapped in an
ed25519 signature over a [BEP-44][bep44] mutable-item encoding. Any party can verify the
signature; only the key-holder can produce a newer one.

Two properties make it work as a directory rather than a broadcast: records are keyed
by the public key (so lookups are `O(1)` point queries, not scans), and each publish
carries a strictly-monotonic timestamp (so the newest record always wins and replays
are rejected). Everything else — DNS as a transport, pkarr relays as a bridge, an
in-tree authoritative server — is plumbing around that core.

Address lookup is deliberately **not** the dialer. It only enriches a peer's candidate
address set; which path actually connects is decided later by [noq][quic]'s multipath
QUIC and [NAT traversal][nat]. A `connect` by bare `EndpointId` therefore blocks only
until the _first_ usable address is known, not until every lookup service finishes
(see [How lookups race with dialing](#how-lookups-race-with-dialing)).

### Design philosophy

The [`AddressLookup`][al-trait] trait is intentionally minimal and asymmetric: publish
is a side-effecting best-effort call, resolve is a cancellable multi-result stream.
From the trait's own doc comment ([`address_lookup.rs:334`][al-trait]):

> _"Publishes the given [`EndpointData`] to the Address Lookup mechanism. This is fire
> and forget, since the [`Endpoint`] can not wait for successful publishing. If
> publishing is async, the implementation should start its own task."_

The record format is pkarr, chosen because it decouples the directory from any single
piece of infrastructure. The module documentation
([`address_lookup/pkarr.rs:9`][pk-mod]) lays out the three bridges — DHT, DNS resolver,
HTTP relay — and why iroh leans on the last two:

> _"Pkarr normally stores these records on the [Mainline DHT], but also provides two
> bridges that do not require clients to directly interact with the DHT: Resolvers are
> servers which expose the pkarr Resource Record under a domain name … Relays are servers
> which allow both publishing and looking up of the pkarr Resource Records using HTTP PUT
> and GET requests."_

Three consequences shape the API:

1. **Compose publishers and resolvers separately.** [`PkarrPublisher`][pk-pub]
   implements only `publish`; [`DnsAddressLookup`][al-dns] and [`PkarrResolver`][pk-res]
   implement only `resolve`. The `N0` preset wires a pkarr publisher next to a DNS
   resolver ([`endpoint/presets.rs:115`][presets]) — you publish over HTTP but resolve
   over cheap, cacheable DNS.
2. **Privacy by default.** The publisher's default [`AddrFilter`][al-filter] is
   `relay_only()`, so raw IP addresses are _not_ leaked to a public pkarr server unless
   the operator opts in ([`address_lookup/pkarr.rs:208`][pk-filter]): _"By default
   [`AddrFilter::relay_only`] is used. This avoids leaking IP addresses to the public
   pkarr server."_
3. **Reuse DNS wire format for everything.** The signed payload _is_ a DNS packet, TXT
   records use the [RFC 1464][rfc1464] `key=value` convention, and the same [`iroh-dns`][repo]
   codec serves both the pkarr blob and third-party DNS caches. There is no bespoke record
   schema.

pkarr is **vendored, not depended on**: iroh 1.0 reimplements the signed-packet format
in ~400 lines ([`iroh-dns/src/pkarr.rs`][dns-pkarr]) rather than pulling the upstream
`pkarr` crate, and its client-side mDNS and Mainline-DHT lookups have moved out of the
workspace into separate `iroh-mdns-address-lookup` / `iroh-mainline-address-lookup`
crates ([`address_lookup.rs:46`][al-trait]). What ships in-tree is the pkarr-over-HTTP
and DNS path, plus a server that is both.

---

## How it works

### The record: a pkarr signed packet

An endpoint's discoverable identity is packed into a **signed packet**: an ed25519
signature over a [BEP-44][bep44] mutable-item encoding of an RFC 1035 DNS reply packet.
The layout ([`iroh-dns/src/pkarr.rs:26`][dns-pkarr]) is fixed-prefix + variable DNS body:

```text
offset  size    field
0       32      ed25519 public key (raw bytes) = the EndpointId
32      64      ed25519 signature over the BEP-44 signable
96      8       timestamp, u64 big-endian, microseconds since UNIX epoch
104     ≤1000   DNS reply packet (RFC 1035 wire format, name-compressed)
```

The size constants are `MAX_DNS_PACKET_SIZE = 1000`, `HEADER_SIZE = 104`, and
`MAX_SIGNED_PACKET_SIZE = 1104` ([`pkarr.rs:17`][dns-pkarr]); a buffer shorter than
`HEADER_SIZE` is rejected `TooShort`, one over 1104 is `TooLarge`. The DNS packet is a
_reply_ with id `0` (`Packet::new_reply(0)`), answers only.

The **signable bytes** are the BEP-44 mutable-item bencode: the ASCII string
`"3:seqi{timestamp}e1:v{len}:"` followed by the raw DNS packet bytes
([`pkarr.rs:290`][dns-pkarr]). Crucially the BEP-44 `seq` field **is** the microsecond
timestamp — iroh carries no separate sequence number:

```rust
// iroh-dns/src/pkarr.rs:290 — signable()
fn signable(timestamp: u64, v: &[u8]) -> Vec<u8> {
    let mut signable = format!("3:seqi{}e1:v{}:", timestamp, v.len()).into_bytes();
    signable.extend(v);
    signable
}
```

### TXT records: the `_iroh` zone

Inside the DNS packet, addressing info lives in TXT records under the name
`_iroh.<z32-endpoint-id>` ([`iroh-dns/src/attrs.rs:19`][dns-attrs]); the serving DNS
server appends its origin so the fully-qualified name a resolver queries is
`_iroh.<z32-endpoint-id>.<origin-domain>`. `z32` is [z-base-32][zb32] with the alphabet
`ybndrfg8ejkmcpqxot1uwisza345h769` ([`iroh-base/src/key.rs:20`][base-key]); a 32-byte
key becomes a 52-char label.

Each TXT value is an [RFC 1464][rfc1464] `key=value` string; the keys are the
kebab-cased [`IrohAttr`][dns-attrs] variants `relay`, `addr`, and `user-data`:

```text
_iroh.<z32-endpoint-id>.<origin>.  IN TXT "relay=https://relay.example./"
_iroh.<z32-endpoint-id>.<origin>.  IN TXT "addr=213.208.157.87:60165"
_iroh.<z32-endpoint-id>.<origin>.  IN TXT "user-data=foobar"
```

Encoding an [`EndpointInfo`][dns-info] walks its ordered `Vec<TransportAddr>` and emits
one TXT record per address — `relay=<url>` for [`TransportAddr::Relay`][dns-info],
`addr=<socketaddr-or-custom>` for `Ip`/`Custom` — plus at most one `user-data`
([`endpoint_info.rs:486`][dns-info]). The address order is significant: it encodes
publish priority so higher-preference addresses land first when a record must be
truncated to fit the packet. Decoding is deliberately lenient — unparseable values are
silently dropped via `filter_map(... .ok())` — and the `endpoint_id` label is validated
to be label 2 of the queried name, so records for other names or record types in a
response are ignored.

`user-data` is capped at **245 bytes** ([`UserData::MAX_LENGTH`][dns-info]) — the DNS
character-string limit of 255 minus the `user-data=` prefix — and the first `user-data`
attribute wins.

### The `AddressLookup` trait and registry

The client contract is two optional methods ([`address_lookup.rs:333`][al-trait]):

```rust
// iroh/src/address_lookup.rs:333
pub trait AddressLookup: std::fmt::Debug + Send + Sync + 'static {
    fn publish(&self, _data: &EndpointData) {}
    fn resolve(&self, _endpoint_id: EndpointId) -> Option<BoxStream<Result<Item, Error>>> {
        None
    }
}
```

`publish` is fire-and-forget; `resolve` returns a **stream** (not a future) so a service
can emit multiple/updated results, and returning `None` means "this service does not
resolve." Dropping the stream must cancel pending work. A companion
`AddressLookupBuilder::into_address_lookup(self, &Endpoint)` lets a service grab the
endpoint's secret key, DNS resolver, and TLS config at bind time; every plain
`AddressLookup` gets a blanket no-op builder.

Services are held in an [`AddressLookupServices`][al-services] registry —
`Arc<RwLock<Vec<Box<dyn AddressLookup>>>>` plus the last-published `EndpointData` (so a
service added later is immediately primed with the current addresses) and an optional
global [`AddrFilter`][al-filter]. Its `resolve()` fans out to every service and merges
the per-service streams with `MergeBounded` (from `n0-future`). The merge policy is the
whole point of the subsystem's robustness ([`address_lookup.rs:540`][al-trait]):

> _"Errors from individual services are yielded inline as `Ok(Err(error))` and do not
> terminate the stream: a single failing service must not hide results from others still
> in flight."_

Concretely: an [`Item`][al-item] is yielded `Ok(Ok(item))` the moment any service
produces one; a per-service error is yielded inline as `Ok(Err(e))` _and_ buffered; only
if the merged stream ends having emitted zero items does it emit a terminal
`Err(AddressLookupFailed::NoResults { errors })`. With no services configured it emits a
single `Err(NoServiceConfigured)`. This is the fix for iroh issue #4125, where one
failing resolver used to truncate the merge (regression test at
[`address_lookup.rs:913`][al-trait]).

### How lookups race with dialing

`Endpoint::connect` does not block on lookups. It calls
`Socket::resolve_remote(EndpointAddr)`, which sends `ActorMessage::ResolveRemote` to the
[socket][socket] actor and **does not await the reply** — a hanging lookup for one peer
cannot serialize connects to others ([`socket.rs:1320`][socket-src], regression test
[`address_lookup.rs:960`][al-trait]). The socket forwards to the per-remote
`RemoteStateActor`, which:

1. Inserts any caller-supplied addresses (from the `EndpointAddr`) into its path map
   with provenance `Source::App`.
2. Registers the caller's reply-`oneshot` and calls `trigger_address_lookup` — a no-op
   if a path is already selected or a lookup is already running
   ([`remote_state.rs:866`][remote-src]).
3. Replies `Ok(())` **immediately** if any path is already known (caller-supplied
   addresses suffice) — the lookup continues in the background, adding more candidate
   paths ([`path_state.rs:161`][path-src]).

Each stream item's addresses are inserted with provenance
`Source::AddressLookup { name }`; inserting the _first_ path drains any parked
`connect` callers with `Ok(())`. Stream end or failure drains them with the error only
if the path map is still empty. `connect` then dials the resulting
`EndpointIdMappedAddr` via [noq][quic] multipath QUIC. The "race" between lookup results
and dialing is thus mediated entirely by the path map: **lookup results merely add
candidate paths; QUIC-native hole-punching and path selection ([NAT traversal][nat])
pick the winner.** Connecting by bare `EndpointId` blocks only until the first usable
address is known.

The per-remote actor has a 60 s idle timeout (`ACTOR_MAX_IDLE_TIMEOUT`,
[`remote_state.rs:73`][remote-src]), but pending resolve requests keep it alive.

### Publishing: `PkarrPublisher`

The socket calls `publish_my_addr()` whenever direct addresses change, the home relay
changes (or on initial bind), or user data changes ([`socket.rs:511`][socket-src]). It
assembles `EndpointData` from the current direct sockaddrs, home relay URL, and user
data, and skips the publish entirely when all three are empty. The only in-tree
publisher is [`PkarrPublisher`][pk-pub]: `publish` stores the filtered `EndpointInfo`
in an `n0_watcher::Watchable`, and a background `PublisherService::run` task watches it,
signs a fresh packet, and HTTP-`PUT`s it to the pkarr relay:

- republishes every `DEFAULT_REPUBLISH_INTERVAL` = **5 min** even when unchanged
  ([`pkarr.rs:146`][pk-const]);
- on error, retries after `Duration::from_secs(failed_attempts)` — linear 1 s, 2 s,
  3 s… backoff ([`pkarr.rs:387`][pk-pub]);
- default packet TTL is **30 s** (`DEFAULT_PKARR_TTL`), _explicitly documented as
  ignored_ by n0's own server ([`pkarr.rs:135`][pk-const]);
- each fresh packet takes a new strictly-monotonic timestamp, so a republish always
  supersedes the prior record.

The default `AddrFilter` is `relay_only()`, keeping IPs off the public relay.

### Resolving: two transports

1. **`DnsAddressLookup`** queries `_iroh.<z32>.<origin>` TXT via the endpoint's
   `DnsResolver`, using **staggered** lookups. Extra attempts fire at
   +200/300/600/1000/2000/3000 ms (`DNS_STAGGERING_MS`,
   [`address_lookup/dns.rs:22`][al-dns]), each with a 3 s `DNS_TIMEOUT`
   ([`iroh-dns/src/dns.rs:42`][dns-resolver]) so _"a lookup will finally abort after 6
   seconds."_ Each delay gets ±20% jitter (`MAX_JITTER_PERCENT`); first success wins,
   otherwise a `StaggeredError` summarizes every failure.
2. **`PkarrResolver`** HTTP-`GET`s `<relay>/<z32-key>` and verifies the returned signed
   packet against the queried key ([`address_lookup/pkarr.rs:619`][pk-res]).

Both produce a one-shot stream (`once_future`). The `N0` preset installs
`PkarrPublisher::n0_dns()` + `DnsAddressLookup::n0_dns()` (or `PkarrResolver` in wasm
browsers, where UDP DNS is unavailable) plus the default relay map
([`endpoint/presets.rs:115`][presets]).

### The client DNS resolver stack

`DnsResolver` wraps a swappable `Box<dyn Resolver>` in an `ArcSwap` guarded by a
`tokio::sync::Notify` ([`iroh-dns/src/dns.rs:251`][dns-resolver]). The default
implementation is **hickory-resolver 0.26**, configured from the host
(`/etc/resolv.conf`; JNI on Android; Google `8.8.8.8` fallback on failure), forcing
`LookupIpStrategy::Ipv4thenIpv6` and `negative_max_ttl = 0`, and stripping Windows'
dead site-local `fec0:0:0:ffff::1..3` nameservers. Every operation runs through
`Inner::op`, a biased `select!` racing the lookup future against a reset-notification
and a per-attempt timeout; on a network change, `reset()` compare-and-swaps in a
freshly built resolver and wakes in-flight ops to retry against it. Caching is delegated
entirely to hickory's record cache — **iroh adds no client-side cache for endpoint
records** — and the same `DnsResolver` is plumbed into `reqwest` for pkarr relay HTTP
requests ([`iroh/src/util.rs:10`][iroh-util]), so all name resolution in iroh flows
through one component.

### The server: `iroh-dns-server`

One process is both a **pkarr relay** and an **authoritative DNS server**
([`iroh-dns-server/src/lib.rs`][repo]). Its HTTP(S) frontend (axum) exposes:

- `PUT /pkarr/{z32-key}` — verify the packet signature against the key in the URL path,
  then upsert into the `ZoneStore`. Only `PUT` is rate-limited (tower-governor:
  `per_second(4)`, `burst_size(2)`, keyed by peer IP / `X-Forwarded-For`,
  [`http/rate_limiting.rs:61`][srv-rate]).
- `GET /pkarr/{z32-key}` — return the relay payload (`204` on PUT, `404` if unknown),
  `Content-Type: application/x-pkarr-signed-packet`.
- `GET|POST /dns-query` — DoH, both `application/dns-message` ([RFC 8484][rfc8484]) and
  Google-style `application/dns-json`.

The **relay payload** — the HTTP body for `PUT`/`GET` — is everything after the pubkey,
i.e. `<64 sig><8 ts><dns packet>`; the 32-byte key rides in the URL path, so it is not
re-sent in the body.

The store is a two-tier stack: an in-memory `ZoneCache` (LRU of **1,048,576** zones)
in front of a **redb** table `signed-packets-1` mapping the 32-byte pubkey to
`<8-byte last_seen><packet bytes>`, with a `update-time-1` multimap (timestamp → key)
as the eviction index ([`store/signed_packets.rs:20`][srv-store]). Writes go through a
dedicated actor on its own OS thread (redb IO is blocking), batching up to **65,536**
messages or **1 s** per write transaction; a second thread evicts packets older than
**7 days**, scanned every **10 s**. An upsert compares recency by `(timestamp, packet
bytes)` and rejects stale updates. Optionally the store falls back to the BitTorrent
[Mainline DHT] for unknown keys (5-minute cache), but mainline is **disabled** in the
shipped prod config.

The DNS frontend (hickory-server, UDP+TCP) serves a static SOA/NS authority per origin
and parses any other query as `<subdomain>.<z32-pubkey>.<origin>`, fetching that key's
zone and re-rooting the stored records by appending the origin
([`dns/node_zone_handler.rs:108`][srv-zone]). Because the pkarr packet stores names
relative to the bare z32 zone, the _same_ stored packet is served under every origin the
server is configured with — and an origin of `"."` makes it answer for any domain.

### What n0 runs

Production origin **`dns.iroh.link.`** and pkarr relay
**`https://dns.iroh.link/pkarr`** ([`iroh-dns/src/dns.rs:45`][dns-resolver],
[`address_lookup/pkarr.rs:127`][pk-const]); staging equivalents under
`staging-dns.iroh.link`, selected by the `IROH_FORCE_STAGING_RELAYS` env var. The n0
server _"does not interact with the Mainline DHT, so is a more central service."_
Default relays are `use1-1.relay.n0.iroh.link.` and its `usw1`/`euc1`/`aps1` siblings
([`iroh/src/defaults.rs:27`][iroh-defaults]).

---

## Analysis

### Wire format & framing

Three distinct wire representations, all grounded in DNS:

| Artifact           | Bytes / framing                                                               | Cite                              |
| ------------------ | ----------------------------------------------------------------------------- | --------------------------------- |
| Signed packet      | `<32 pubkey><64 sig><8 BE timestamp-µs><≤1000 B DNS reply>`, total ≤ 1104 B   | [`pkarr.rs:26`][dns-pkarr]        |
| BEP-44 signable    | ASCII `"3:seqi{ts}e1:v{len}:"` ++ raw DNS packet bytes; `seq` == timestamp    | [`pkarr.rs:290`][dns-pkarr]       |
| Relay HTTP payload | signed packet minus pubkey: `<64 sig><8 ts><dns packet>`; key in URL path     | [`http/pkarr.rs`][srv-http-pkarr] |
| TXT record         | RFC 1464 `key=value`, one record per address; `relay=`, `addr=`, `user-data=` | [`attrs.rs`][dns-attrs]           |
| DNS name           | `_iroh.<z32-endpoint-id>.<origin>`, z32 = 52-char label from a 32-byte key    | [`key.rs:20`][base-key]           |
| Server storage row | `<8 B BE last_seen-µs><≤1104 B signed packet>` in redb                        | [`signed_packets.rs`][srv-store]  |

The DNS packet uses [RFC 1035][rfc1035] name compression (via `simple-dns`), which the
1000-byte budget depends on. Multi-string TXT records are concatenated without separator
before parsing. Recency is total-ordered by `(timestamp, lexicographic packet bytes)`.
The [wire-serialization][wire] page covers the shared DNS/TXT codec and how tickets pack
the same `EndpointAddr` addresses.

| Constant                     | Value                       | Cite                               |
| ---------------------------- | --------------------------- | ---------------------------------- |
| `MAX_DNS_PACKET_SIZE`        | 1000 B                      | [`pkarr.rs:17`][dns-pkarr]         |
| `MAX_SIGNED_PACKET_SIZE`     | 1104 B                      | [`pkarr.rs:23`][dns-pkarr]         |
| `UserData::MAX_LENGTH`       | 245 B                       | [`endpoint_info.rs`][dns-info]     |
| `DNS_TIMEOUT` (per query)    | 3 s                         | [`dns.rs:42`][dns-resolver]        |
| `DNS_STAGGERING_MS`          | 200,300,600,1000,2000,3000  | [`dns.rs:22`][al-dns]              |
| jitter                       | ±20%                        | [`dns.rs`][dns-resolver]           |
| `DEFAULT_PKARR_TTL`          | 30 s (ignored by n0 server) | [`pkarr.rs:135`][pk-const]         |
| `DEFAULT_REPUBLISH_INTERVAL` | 5 min                       | [`pkarr.rs:146`][pk-const]         |
| server zone LRU              | 1,048,576 zones             | [`store.rs`][srv-store-idx]        |
| store eviction               | 7 days, scanned every 10 s  | [`signed_packets.rs`][srv-store]   |
| write batch                  | 65,536 msgs / 1 s           | [`signed_packets.rs`][srv-store]   |
| `PUT` rate limit             | 4/s, burst 2, per-IP        | [`rate_limiting.rs:61`][srv-rate]  |
| remote actor idle timeout    | 60 s                        | [`remote_state.rs:73`][remote-src] |

### Cryptography & identity

The only cryptographic operation is ed25519 sign/verify over the BEP-44 signable
(`ed25519-dalek`, via [`iroh-base`][base-key]). The signing key _is_ the
[`EndpointId`][identity], so the record is self-certifying: the 32-byte pubkey prefix
_is_ the name a resolver queried for, and verification is "does this signature match this
key over these bytes." A pkarr relay or DNS cache is untrusted storage — it can withhold
or replay but not forge. See [Identity & Cryptography][identity] for the key type, z32
encoding, and the shared ed25519 primitives.

Replay protection is the strictly-monotonic timestamp, which doubles as the BEP-44 `seq`.
Its documentation ([`pkarr.rs:325`][dns-pkarr]) states the guarantee:

> _"[`Timestamp::now`] is guaranteed to be strictly monotonic: it will never return the
> same value twice and will never go backward, even if the system clock is corrected by
> NTP."_

This is enforced process-globally via an `AtomicU64` CAS loop returning at least
`last + 1`, protecting against both NTP steps and two publishes within the same
microsecond (which BEP-44's strictly-increasing-`seq` rule would otherwise reject). TLS
enters only at the transport edges — pkarr `PUT`/`GET` over HTTPS (`rustls`) and DoH — and
is orthogonal to record authenticity, which the signature already guarantees end to end.

### State machines & lifecycle

Five distinct state machines, three client-side and two server-side:

1. **`PublisherService`** (pkarr publish loop, [`pkarr.rs:376`][pk-pub]). States
   _Idle-no-data_ → _Published_ (republish timer at +5 min) → _Backoff_ (timer at +`failed_attempts` s). A `Watchable` update triggers an immediate re-publish; `Ok`
   resets `failed_attempts` and arms the 5-min timer; `Err` increments it and arms the
   linear-backoff timer; a `Disconnected` watcher (all publisher clones dropped) exits
   the loop, and the whole task is abort-on-drop.
2. **Per-remote lookup** (inside `RemoteStateActor`, [`remote_state.rs:850`][remote-src]).
   States _NoLookup_ ⇄ _LookupRunning_. `ResolveRemote` with no selected path and no
   running stream starts the merged stream; each `Ok(item)` inserts addresses (possibly
   draining parked `connect` callers); terminal `Err`/end drains the rest and returns to
   _NoLookup_. A selected path makes future triggers no-ops; 60 s idle with no pending
   resolvers terminates the actor.
3. **`AddressLookupStream` merge** ([`address_lookup.rs:582`][al-trait]). States _Open_ →
   _Closed_. Emits `Ok(Ok)` (sets `did_emit`), `Ok(Err)` (buffers), and on inner
   exhaustion emits `Err(NoResults{errors})` iff `!did_emit`.
4. **`DnsResolver::op` retry loop** ([`dns.rs:311`][dns-resolver]). Per attempt races
   (biased) lookup-completes / `notify_reset` / timeout; a reset reloads the resolver and
   restarts with a fresh timeout. A swap-before-notify ordering means a missed wake still
   observes the new resolver.
5. **Server store actor batching** ([`signed_packets.rs`][srv-store]). _Waiting_ →
   _Batching_ (write txn open), leaving when 65,536 messages, 1 s, or cancellation fires.
   A companion eviction task snapshots the update-time index, then re-verifies each
   candidate against the live table before deleting (it may have been refreshed since the
   snapshot).

The **staggered DNS lookup** is not a persistent state machine but a fan-out: n+1
futures each prefixed by a jittered sleep, first `Ok` wins.

### Dependencies & coupling

| Crate                   | Depth (D-port cost)          | Role                                                                                                                                                                          |
| ----------------------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `simple-dns` 0.11       | load-bearing (client+shared) | builds/parses the DNS packet inside signed packets, incl. name compression. Needs a minimal RFC 1035 writer/parser: header, QNAME compression, TXT char-string RDATA, A/AAAA. |
| `hickory-resolver` 0.26 | load-bearing (client)        | full stub resolver: system config, UDP/TCP/DoT/DoH, caching, `Ipv4thenIpv6`. **Biggest reimplementation item.**                                                               |
| `ed25519-dalek`         | load-bearing                 | sign/verify the BEP-44 signable (via [`iroh-base`][base-key]).                                                                                                                |
| `data-encoding`         | small                        | z-base-32 with a custom alphabet (~30 lines to reimplement).                                                                                                                  |
| `n0-future`             | API-surface                  | `MergeBounded`, `FuturesUnorderedBounded`, `once_future`, `BoxStream`, time shims.                                                                                            |
| `n0-watcher`            | structural                   | `Watchable`/`Direct` watch-channel (last-value + async `updated()`) — **no event-horizon equivalent**.                                                                        |
| `arc-swap`              | structural                   | lock-free resolver swap — collapses to a plain field single-threaded.                                                                                                         |
| `reqwest` + `rustls`    | API-surface                  | pkarr relay HTTPS `PUT`/`GET` with the iroh `DnsResolver` plumbed in.                                                                                                         |
| `tokio` (sync, timers)  | structural                   | mpsc/oneshot/broadcast/Notify/Mutex, sleep/interval — see [Concurrency Inventory][concurrency].                                                                               |
| server-only             | server-only                  | `redb`, `lru`, `ttl_cache`, `mainline`, `axum`/`tower-governor`, `hickory-server` — only if porting the relay/DNS server.                                                     |
| `strum`                 | trivial                      | kebab-case enum ↔ string for `IrohAttr`.                                                                                                                                      |

The subsystem couples _upward_ to the [socket][socket] (which drives publish and consumes
resolve into the path map) and the [endpoint][endpoint] (which owns the registry and hands
services the secret key at bind time), and _sideways_ to [identity-crypto][identity]
(signing) and [wire-serialization][wire] (the DNS/TXT codec). It couples _downward_ only
to raw UDP/TCP (DNS) and HTTPS (pkarr) — it never dials QUIC itself.

### Concurrency & I/O model

Client-side, the moving parts are: one background `PublisherService` task per publisher
(fed by a `Watchable`, driven by a `select!` of watcher-updated vs a resettable republish
timer); the `RwLock`-guarded registry; the `MergeBounded` fan-in of resolve streams; and
the `ArcSwap` + `Notify` resolver hot-swap. Lookups are I/O-bound: DNS is small
UDP round-trips (staggered, jittered, timed out); pkarr is two-verb HTTPS with ≤1104-byte
bodies. There is no CPU-heavy work — ed25519 verify on a ≤1104-byte packet is negligible.

Server-side adds the redb write actor and eviction thread (both on dedicated OS threads
because redb IO is blocking), an mpsc mailbox per store request, an axum `JoinSet` of
HTTP/HTTPS listeners, a per-DoH-request broadcast(1) channel adapting hickory's push
`ResponseHandler` into a pull, and the mainline DHT's own internal threads. The full
tally lives in the [Tokio Concurrency Inventory][concurrency]; the load-bearing shapes
for a port are the **watch channel**, the **mpsc actor inboxes**, and the **oneshot**
reply for `connect`.

### Mapping to event-horizon

Address lookup is a good fit for [event-horizon][eh-spec]'s single-threaded fibers +
capabilities model, with three genuine gaps that need new design (all flagged in the
[event-horizon spec][eh-spec] as open issues).

**The trait → a DbI capability.** [`AddressLookup`][al-trait] is a textbook
Design-by-Introspection concept: a struct with optional `publish`/`resolve` members
detected by presence. Static compositions need no vtable; the _dynamic_ registry
(`Box<dyn AddressLookup>`) needs a small hand-rolled interface, but since iroh apps
rarely add services at runtime, a `Vec`-of-interface with two methods is the honest
mapping. The Rust trait alongside a proposed D capability trait:

```rust
// iroh/src/address_lookup.rs:333 (verbatim)
pub trait AddressLookup: std::fmt::Debug + Send + Sync + 'static {
    fn publish(&self, _data: &EndpointData) {}
    fn resolve(&self, _endpoint_id: EndpointId) -> Option<BoxStream<Result<Item, Error>>> {
        None
    }
}
```

```d
// proposed / sketch — an event-horizon DbI capability.
// Static services are detected by member presence (isAddressLookup!T);
// the runtime registry is a small interface with the same two verbs.
enum isAddressLookup(T) =
    is(typeof(T.init.publish(EndpointData.init))) ||
    is(typeof(T.init.resolve(EndpointId.init)));

interface AddressLookup                       // used only for the dynamic Vec-of-services
{
    void publish(in EndpointData data);       // fire-and-forget; may spawn a fiber
    // returns null if this service does not resolve; the caller owns the stream's Scope
    ResolveStream* resolve(EndpointId id) @safe;
}
```

**Resolve streams and the merge.** `resolve()` returns a cancellable multi-item stream
merged across services with inline error buffering. Under event-horizon tier B the
natural shape is a fiber per service pushing items into a per-lookup collector — but
event-horizon **lacks cross-fiber channels (open issue O20)**, and `race`/first-completion
is _not_ enough here: losing services must keep running and keep contributing addresses.
The honest interim is a fiber-owned result buffer plus a wakeable condition, with the
per-remote fiber as the single consumer; under the default `single` topology there is no
lock around it. The inline-error-buffering policy (emit `NoResults{errors}` only if zero
items were produced) is a small state machine over that buffer.

**Cancellation is free.** _"Once the returned `BoxStream` is dropped, the service should
stop any pending work"_ ([`address_lookup.rs:345`][al-trait]) maps directly to a child
`Scope`: spawn each service's lookup in a scope owned by the lookup; exiting the scope
cancels all children. A parked DNS/HTTP fiber is cancelled via `ASYNC_CANCEL` and resumes
only at its terminal completion.

**Staggered lookups map cleanly.** One `Scope`, spawn n+1 fibers each doing
`sleep(jittered delay); attempt()`, first success cancels siblings — i.e. a `race` where
each contestant has a sleep prefix. Jitter needs an RNG capability; the delays and the
3 s timeout are `withDeadline` cancel scopes. Republish (5-min resettable), retry
backoff, and the 60 s actor idle are all in-ring `TIMEOUT` ops; the resettable republish
`sleep` becomes re-arming a timer op.

**The watch channel has no equivalent.** `n0_watcher::Watchable` (socket → publisher) is
last-value-wins + level-triggered wakeup, and event-horizon has nothing for it. A tiny
cell suffices single-threaded, and it recurs across iroh subsystems (direct addrs, home
relay), so design it once:

```rust
// n0_watcher::Watchable<Option<EndpointInfo>> (conceptual)
//   .set(value)         // last-value-wins
//   .watch().updated()  // async: wakes on the next change
```

```d
// proposed / sketch — single-threaded watch cell (no locking under `single` topology).
struct Watched(T)
{
    private T value;
    private ulong version_;
    private Waker waker;                       // event-horizon cross-fiber wake

    void set(T v) @safe { value = v; version_++; waker.wake(); }

    // parks the caller until version_ advances past `seen`
    T await(ref ulong seen) @safe;            // returns value, updates seen := version_
}
```

**Actors collapse to state-owning fibers.** The `RemoteStateActor` and the server store
actor are mpsc actor loops → a single fiber owning its state; their inboxes again hit
O20. The `connect` `oneshot` reply maps to `fork` → `JoinHandle.join`, or a one-slot cell

- wake. The `ArcSwap` + `Notify` resolver reset dance collapses to a plain field swap plus
  waking parked lookup fibers at their next checkpoint; interrupt-and-retry maps to a
  `Cause.interrupt` requeue under a per-attempt `CancelContext`.

**No thread pool needed.** The server's redb IO threads and eviction thread exist only
because redb is blocking; on io_uring, file I/O is native, so a from-scratch D store (even
a flat append-log + eviction index) runs on the ring directly — no `spawn_blocking`
equivalent to fake.

**The crypto/IO split is clean and `@nogc`-friendly.** `SignedPacket` build/verify is pure
and allocation-light: the packet caps at 1104 bytes, ideal for a `SmallBuffer!(ubyte,
1104)`; verification is one ed25519 check over a `SmallBuffer`-built BEP-44 signable. The
monotonic `Timestamp` needs only a module-level `ulong` under `single` topology — no CAS:

```d
// proposed / sketch — strictly-monotonic pkarr timestamp, single-threaded.
private ulong lastTimestamp;                   // module-level; no atomics under `single`

ulong nowMicrosMonotonic(scope Clock clock) @safe nothrow @nogc
{
    const wall = clock.unixMicros();
    const next = wall > lastTimestamp ? wall : lastTimestamp + 1;
    lastTimestamp = next;
    return next;                               // never repeats, never goes backward
}
```

**The one large item with no shortcut is the DNS resolver.** hickory has no cheap
replacement, but the [`Resolver`][dns-resolver] trait boundary is explicitly designed for
a custom implementation. A D port starts with UDP TXT/A/AAAA queries to the configured
nameservers via event-horizon `OpSend`/`OpRecv` with a 3 s deadline, a minimal RFC 1035
codec (shared with the pkarr packet codec), and `/etc/resolv.conf` parsing. The pkarr
`PUT`/`GET` client is plain HTTPS/1.1 with two verbs and tiny bodies — a `sparkles:http`
client over [event-horizon][eh-spec] plus a TLS layer, reusing the same DNS capability for
host resolution.

---

## Strengths

- **Self-certifying records.** ed25519 over BEP-44 means every hop of infrastructure
  (relay, DNS cache) is untrusted; forgery requires the secret key, and the pubkey _is_
  the name.
- **Transport-agnostic directory.** The same signed packet resolves over DNS (cheap,
  cacheable, browser-friendly via DoH) or a pkarr HTTP relay, with no per-transport record
  schema.
- **Robust fan-out.** The `MergeBounded` merge with inline-error buffering guarantees one
  failing resolver cannot hide another's results — a regression-tested invariant.
- **Non-blocking dial path.** `connect` proceeds on the first known address; lookups
  enrich candidates in the background and never serialize other peers' connects.
- **Privacy-preserving default.** `relay_only()` keeps raw IPs off the public relay unless
  the operator opts in.
- **Small, self-contained record.** ≤1104 bytes total — trivially fits a stack buffer,
  ideal for a `@nogc` D port.
- **A single reference server** that is simultaneously pkarr relay and authoritative DNS,
  serving the same stored packet under any configured origin.

## Weaknesses

- **hickory is a heavy dependency.** The client DNS stack (system config, UDP/TCP/DoT/DoH,
  caching) is the single largest reimplementation item and has no small equivalent.
- **pkarr is vendored, not shared.** iroh reimplements the signed-packet format rather
  than depending on the upstream `pkarr` crate, so it can drift from the ecosystem
  (compatibility with third-party `pkarr.org` relays is inferred, not verified).
- **No client-side record cache.** Endpoint records rely entirely on hickory's cache, and
  negative caching is disabled (`negative_max_ttl = 0`) — every miss re-queries.
- **TTL is a lie on n0 infra.** `DEFAULT_PKARR_TTL = 30 s` is documented as ignored by the
  n0 server (records live until superseded or 7-day eviction), so the field only affects
  third-party DNS caches.
- **Multiple `relay=` records are unresolved.** There is no defined policy for choosing a
  home relay when several are published (an open upstream TODO on
  [`Item::last_updated`][al-item]).
- **Server complexity for a small job.** The reference server carries redb, an LRU, a TTL
  cache, an optional DHT, rate limiting, and two OS threads — a lot of machinery around a
  key→bytes map.

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                                 | Trade-off                                                                                      |
| -------------------------------------------------------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| pkarr signed packet (ed25519 over BEP-44 DNS)            | Self-certifying records; infra is untrusted storage; reuses DNS wire format everywhere    | ≤1104-byte cap constrains how many addresses fit; name compression must stay within budget     |
| BEP-44 `seq` == microsecond timestamp                    | One field for recency and replay protection; NTP-safe via strict monotonicity             | Two publishes in one µs need a process-global CAS/counter; no independent revision number      |
| `resolve` returns a stream, `publish` is fire-and-forget | Services can emit multiple/updated results; endpoint can't wait on best-effort publish    | Asymmetric API; drop-to-cancel discipline; needs a channel-like fan-in (event-horizon O20)     |
| Merge with inline error buffering                        | One failing service must not truncate results; report all errors only on total failure    | Callers must distinguish `Ok(Err)` (inline) from the terminal `Err`; extra buffering state     |
| Non-blocking `connect` (first-address-wins)              | A slow/hanging lookup can't serialize other connects; dial starts ASAP                    | Lookup keeps running after `connect` returns; path selection deferred to QUIC/NAT traversal    |
| `relay_only()` publish filter by default                 | Avoids leaking IPs to a public relay                                                      | Direct-IP dialing needs an explicit opt-in; default path always involves a relay hop           |
| Vendor pkarr, drop in-tree mDNS/DHT lookups              | ~400-line focused impl; keeps the workspace lean; DHT/mDNS live in optional crates        | Ecosystem drift risk; loses zero-infrastructure DHT resolution unless the extra crate is added |
| Reference server is relay + DNS in one process           | Same stored packet served over DoH and pkarr HTTP; one origin config answers many domains | Heavy dependency surface (redb, DHT, axum, two OS threads) for a conceptually simple store     |
| No client-side record cache (`negative_max_ttl = 0`)     | Freshness over hit-rate; lookups feed a live path map, not a cache                        | Every miss re-queries; relies wholly on hickory's record cache                                 |

---

## Sources

- [`iroh/src/address_lookup.rs`][al-trait] — `AddressLookup` trait, `AddressLookupServices` registry, `MergeBounded` merge, `Item`, `AddressLookupFailed`
- [`iroh/src/address_lookup/pkarr.rs`][pk-pub] — `PkarrPublisher`, `PkarrResolver`, `PkarrRelayClient`, `PublisherService` loop, n0 relay constants
- [`iroh/src/address_lookup/dns.rs`][al-dns] — `DnsAddressLookup`, staggered lookups
- [`iroh-dns/src/pkarr.rs`][dns-pkarr] — `SignedPacket` wire format, BEP-44 signable, monotonic `Timestamp`
- [`iroh-dns/src/attrs.rs`][dns-attrs] — `_iroh` TXT name, `IrohAttr`, `TxtAttrs`
- [`iroh-dns/src/endpoint_info.rs`][dns-info] — `EndpointData`/`EndpointInfo`/`UserData`/`AddrFilter`, TXT codecs
- [`iroh-dns/src/dns.rs`][dns-resolver] — `DnsResolver`, `Resolver` trait, hickory backend, staggering/jitter/reset
- [`iroh-base/src/key.rs`][base-key] — z-base-32 alphabet, `EndpointId`
- [`iroh-dns-server/src/store/signed_packets.rs`][srv-store] — redb store actor, batching, eviction
- [`iroh-dns-server/src/http/pkarr.rs`][srv-http-pkarr] · [`http/rate_limiting.rs`][srv-rate] · [`dns/node_zone_handler.rs`][srv-zone] — relay/DNS frontends
- [`iroh/src/socket/remote_map/remote_state.rs`][remote-src] · [`path_state.rs`][path-src] — how lookups race with dialing
- [pkarr] · BitTorrent [BEP-44][bep44] · [RFC 1035][rfc1035] · [RFC 1464][rfc1464] · [RFC 8484][rfc8484] · [z-base-32][zb32]
- Related pages: [Identity & Cryptography][identity] · [Wire Formats & Serialization][wire] · [The Relay Protocol][relay] · [Endpoint & Protocol Router][endpoint] · [The Multipath Socket][socket] · [NAT Traversal][nat] · [Tokio Concurrency Inventory][concurrency]

<!-- References -->

[repo]: https://github.com/n0-computer/iroh/tree/22cac742ca
[docs-iroh]: https://docs.rs/iroh/1.0.1/iroh/address_lookup/index.html
[docs-dns]: https://docs.rs/iroh-dns/1.0.1/iroh_dns/
[docs-dns-server]: https://docs.rs/iroh-dns-server/1.0.1/iroh_dns_server/
[al-trait]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/address_lookup.rs#L333
[al-item]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/address_lookup.rs#L370
[al-services]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/address_lookup.rs#L461
[al-filter]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns/src/endpoint_info.rs#L229
[al-dns]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/address_lookup/dns.rs#L22
[pk-mod]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/address_lookup/pkarr.rs#L9
[pk-pub]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/address_lookup/pkarr.rs#L270
[pk-res]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/address_lookup/pkarr.rs#L619
[pk-const]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/address_lookup/pkarr.rs#L127
[pk-filter]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/address_lookup/pkarr.rs#L208
[presets]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/presets.rs#L115
[dns-pkarr]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns/src/pkarr.rs#L26
[dns-attrs]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns/src/attrs.rs#L19
[dns-info]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns/src/endpoint_info.rs#L70
[dns-resolver]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns/src/dns.rs#L251
[base-key]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-base/src/key.rs#L20
[srv-store]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns-server/src/store/signed_packets.rs#L20
[srv-store-idx]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns-server/src/store.rs#L28
[srv-http-pkarr]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns-server/src/http/pkarr.rs
[srv-rate]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns-server/src/http/rate_limiting.rs#L61
[srv-zone]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-dns-server/src/dns/node_zone_handler.rs#L108
[socket-src]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1320
[remote-src]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state.rs#L73
[path-src]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/remote_map/remote_state/path_state.rs#L161
[iroh-util]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/util.rs#L10
[iroh-defaults]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/defaults.rs#L27
[bep44]: https://www.bittorrent.org/beps/bep_0044.html
[pkarr]: https://pkarr.org
[Mainline DHT]: https://www.bittorrent.org/beps/bep_0005.html
[rfc1035]: https://www.rfc-editor.org/rfc/rfc1035
[rfc1464]: https://www.rfc-editor.org/rfc/rfc1464
[rfc8484]: https://www.rfc-editor.org/rfc/rfc8484
[zb32]: https://philzimmermann.com/docs/human-oriented-base-32-encoding.txt
[concepts]: ./concepts.md
[identity]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[quic]: ./quic-transport.md
[endpoint]: ./endpoint.md
[socket]: ./socket.md
[nat]: ./nat-traversal.md
[relay]: ./relay.md
[concurrency]: ./concurrency.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
