# Endpoint & Protocol Router

iroh's public front door: a cheaply-clonable `Endpoint` handle — an `Arc<EndpointInner>` shell over the [`noq`][quic] QUIC stack — paired with a `Router` that multiplexes inbound connections onto per-`ALPN` `ProtocolHandler`s. This is the API surface a D port must mirror one-for-one.

| Field               | Value                                                                                                                                                                                                     |
| ------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate(s)            | `iroh` — modules `endpoint`, `endpoint::connection`, `protocol`, `runtime`, `tls` — over `noq` / `noq-proto`                                                                                              |
| Version             | iroh **v1.0.1** (git `v1.0.1-6-g22cac742ca`, commit `22cac742ca`); `noq` tag `noq-v1.0.1`                                                                                                                 |
| Repository          | [`n0-computer/iroh`][repo] (crate under `iroh/`)                                                                                                                                                          |
| Documentation       | [docs.rs/iroh][docs]                                                                                                                                                                                      |
| ALPN(s)             | None owned by this layer — `ALPN`s are application-chosen byte strings (`b"iroh-example/echo/0"`, `b"n0/iroh/transfer/example/1"`); the accept side picks the winner                                      |
| Approx. size (LoC)  | ~8.3k across `endpoint.rs` (4121), `connection.rs` (1642), `protocol.rs` (1059), `quic.rs` (716), plus `bind.rs`/`hooks.rs`/`presets.rs`/`runtime.rs` (~740); ≈6.1k non-test                              |
| Category            | Connectivity                                                                                                                                                                                              |
| Upstream spec/draft | None of its own; rides QUIC [RFC 9000][rfc9000], TLS 1.3 [RFC 8446][rfc8446], `ALPN` [RFC 7301][rfc7301]. Multipath / NAT drafts live under [`quic-transport`][quic-transport] and [`nat-traversal`][nat] |

> [!NOTE]
> iroh 1.0 is a major restructure of the 0.x API. In this subsystem: **`magicsock` → the [socket][socket] layer**, **"discovery" → `address_lookup`** (see [`discovery`][discovery]), **`NodeId` → `EndpointId`**, `NodeAddr` → `EndpointAddr` (vocabulary in [Concepts][concepts]). The `DISCO` UDP side-protocol and STUN are gone — NAT traversal and address discovery are now QUIC-native inside `noq-proto` (see [`nat-traversal`][nat]). `NodeAddr`-era folklore does not compile. This page is part of the [iroh survey][index].

---

## Overview

### What it solves

An application that wants to speak an iroh peer-to-peer protocol needs three things wired together: a bound QUIC endpoint with a stable cryptographic identity, an outbound `connect(addr, alpn)` that resolves a peer's `EndpointId` to a live network path and negotiates a protocol, and an inbound accept path that maps each incoming connection to the right handler. The `endpoint` and `protocol` modules are exactly this glue. They own **no wire bytes of their own** — QUIC/TLS framing, streams, datagrams, multipath, NAT-traversal, address discovery, retry tokens and 0-RTT all live in `noq`/`noq-proto` (see [`quic-transport`][quic-transport]) — and are best understood as a **thin state-tracking + policy shell** that adds iroh's identity model, its four interception layers, its holepunching-tuned QUIC defaults, and a protocol-router run loop on top of that stack.

`Endpoint` is the primary object; the crate documentation recommends a single instance per process ([`endpoint.rs:861`][ep-single]). `Router` is the optional multiplexer for servers that speak more than one `ALPN`. Everything else in the module — the builder's ~20 knobs, the `Incoming` verbs, the type-state `Connection<State>`, the hooks, the `Runtime` seam — exists to make those two objects safe, configurable, and (critically for the D port) driven by a **host-injectable concurrency substrate** rather than a hard-wired runtime.

### Design philosophy

The endpoint is meant to be shared, long-lived, and singular. From the `Endpoint` doc comment ([`endpoint.rs:861`][ep-single]):

> _"It is recommended to only create a single instance per application. This ensures all the connections made share the same peer-to-peer connections to other iroh endpoints, while still remaining independent connections. This will result in more optimal network behaviour."_

Three consequences shape the API:

1. **Cloning is cheap and shares state.** `Endpoint` is `#[derive(Clone)]` over `Arc<EndpointInner>` ([`endpoint.rs:897`][ep-struct]); every clone shares one QUIC endpoint, one socket actor, one `Runtime`, and one TLS-ticket cache. UDP sockets close only when the last clone drops.
2. **Closing is an explicit async drain, not a `Drop`.** Because QUIC acknowledgements are implemented in user-land, a graceful close must wait for `CONNECTION_CLOSE` frames to be delivered and acked ([`endpoint.rs:1695`][ep-close-comment]). Dropping an `EndpointInner` without `close()` is an error-level event that aborts ungracefully ([`socket.rs:220`][socket-drop]).
3. **The concurrency substrate is a trait, not a hard dependency.** `noq` never spawns tokio tasks directly — it drives every driver task and timer through the `noq::Runtime` trait, which iroh implements in ~135 lines ([`runtime.rs:9`][runtime]). This single seam is the entire QUIC stack's coupling to its host executor, and is the port's front door (see [Mapping to event-horizon](#mapping-to-event-horizon)).

The design is deliberately **layered as a veneer**: ~50 `noq`/`noq-proto` types — streams, datagrams, `VarInt`, connection stats, `ConnectionError` — are re-exported verbatim ([`quic.rs:15`][quic-reexport]), a handful newtyped (`QuicTransportConfig`, `ServerConfig`) so iroh can pin holepunching-critical defaults the raw `noq` builder would leave open.

---

## How it works

### Layering: what an `Endpoint` actually holds

`Endpoint` is a newtype over `Arc<EndpointInner>` ([`endpoint.rs:897`][ep-struct]); `EndpointInner` ([`socket.rs:204`][ep-inner]) derefs (via `#[deref(forward)]`) to the [`Socket`][socket] multipath transport and owns the QUIC endpoint plus the concurrency machinery:

```rust
// iroh/src/socket.rs:204-218 — what Endpoint actually holds
pub(crate) struct EndpointInner {
    #[deref(forward)]
    sock: Arc<Socket>,
    actor_task: Mutex<Option<AbortOnDropHandle<()>>>, // empty when shutdown
    actor_sender: mpsc::Sender<ActorMessage>,
    endpoint: noq::Endpoint,
    runtime: Arc<Runtime>,
    pub(crate) static_config: StaticConfig,
}
```

`StaticConfig` ([`socket.rs:232`][ep-inner]) is the immutable per-endpoint bundle: the TLS config, base server/client QUIC configs, the retry-token key, the TLS-ticket `TokenStore` (a `noq::TokenMemoryCache`), and the transport config. The socket `Actor` (fed by `actor_sender`) owns per-remote state; `resolve_remote` and `register_connection` are request/response round-trips into it ([`socket.rs:1320`][socket-resolve], [`socket.rs:1379`][socket-actormsg]).

### Builder → bind: mandatory `Preset`, mandatory crypto provider

`Endpoint::builder(preset)` takes a **mandatory** `Preset` argument ([`presets.rs:21`][presets]). `Builder::empty()` starts with two implicit IP transports (`0.0.0.0` and `[::]`, the latter allowed to fail) and _no_ relay, _no_ address-lookup, and _no_ crypto provider ([`endpoint.rs:191`][ep-empty]). `Builder::bind()` ([`endpoint.rs:225`][ep-bind]) then: (1) generates a `SecretKey` if unset; (2) **fails** with `BindError::InvalidCryptoProvider` if no rustls `CryptoProvider` was configured — the crypto provider is a required knob, normally supplied by the `Minimal`/`N0` presets ([`endpoint.rs:747`][ep-crypto]); (3) builds the retry-token key and `TlsConfig`; (4) constructs `socket::Options` and awaits `EndpointInner::bind` ([`socket.rs:874`][socket-bind]), which binds the transports and creates the `noq::Endpoint` via `new_with_abstract_socket(...)` ([`socket.rs:1027`][socket-abstract]) — the QUIC stack talks to an **abstract socket**, not a raw UDP fd; (5) instantiates each queued address-lookup service against the live endpoint.

The presets are the supported way to reach a bindable state ([`presets.rs`][presets]):

| Preset           | Applies                                                                                                            | Cite                           |
| ---------------- | ------------------------------------------------------------------------------------------------------------------ | ------------------------------ |
| `Empty`          | Nothing — `bind()` fails unless a crypto provider is set manually                                                  | [`presets.rs:21`][presets]     |
| `Minimal`        | Sets only `crypto_provider` (prefers `ring` over `aws-lc-rs` when both features are on)                            | [`presets.rs:57`][presets-min] |
| `N0`             | `Minimal` + a `PkarrPublisher::n0_dns()` publisher + `DnsAddressLookup::n0_dns()` resolver + `relay_mode(default)` | [`presets.rs:110`][presets-n0] |
| `N0DisableRelay` | `N0`, then `RelayMode::Disabled`                                                                                   | [`presets.rs:110`][presets-n0] |

The builder exposes roughly twenty knobs. The complete inventory, defaults, and citations ([`endpoint.rs`][ep-bind]):

| Knob                                                          | Default                                                                   |
| ------------------------------------------------------------- | ------------------------------------------------------------------------- |
| `bind_addr(A)` / `bind_addr_with_opts(A, BindOpts)`           | `0.0.0.0` + `[::]` implicit; `BindOpts{prefix_len:0, is_required:true}`   |
| `clear_ip_transports()` / `clear_relay_transports()`          | —                                                                         |
| `secret_key(SecretKey)`                                       | random                                                                    |
| `alpns(Vec<Vec<u8>>)`                                         | empty (accept needs ≥1)                                                   |
| `relay_mode(RelayMode)`                                       | `Disabled` in `empty()`; `N0` sets Default/Staging                        |
| `address_lookup(...)` (repeatable) / `clear_address_lookup()` | none (see [`discovery`][discovery])                                       |
| `addr_filter(AddrFilter)` / `clear_addr_filter()`             | none                                                                      |
| `user_data_for_address_lookup(UserData)`                      | none                                                                      |
| `external_addr(SocketAddr)` (repeatable)                      | none                                                                      |
| `transport_config(QuicTransportConfig)`                       | iroh-tuned default                                                        |
| `dns_resolver(DnsResolver)`                                   | system config                                                             |
| `proxy_url(Url)` / `proxy_from_env()`                         | none (`HTTP_PROXY`/`http_proxy`/`HTTPS_PROXY`/`https_proxy`, CGI-guarded) |
| `ca_tls_config(CaTlsConfig)`                                  | webpki defaults                                                           |
| `keylog(bool)`                                                | `false` (`SSLKEYLOGFILE`)                                                 |
| `max_tls_tickets(usize)`                                      | 256 (`8 * 32`, ≈150 KiB)                                                  |
| `crypto_provider(Arc<CryptoProvider>)`                        | **mandatory** (via preset)                                                |
| `hooks(impl EndpointHooks)` (repeatable, ordered)             | none                                                                      |
| `portmapper_config(...)`                                      | Enabled — UPnP/PCP/NAT-PMP (see [`net-report`][net-report])               |
| `net_report_config(...)`                                      | default (see [`net-report`][net-report])                                  |
| `add_custom_transport(...)`                                   | unstable                                                                  |
| `path_selector(...)`                                          | `BiasedRttPathSelector` (IPv6>IPv4, relay=backup, sticky); unstable       |

A subtle bind-time trick: `endpoint_config.grease_quic_bit(false)` is set so that non-QUIC UDP packets — whose first byte iroh's transport zeroes — are silently dropped by `noq` rather than needing a buffer rewrite ([`socket.rs:1013`][socket-grease]).

### Timing constants and limits

The holepunching-critical values (`QuicTransportConfigBuilder::new()` overriding `noq` defaults, [`quic.rs:151`][quic-defaults]) and the socket constants ([`socket.rs:109`][socket-const]):

| Constant                                                   | Value            | Source                          |
| ---------------------------------------------------------- | ---------------- | ------------------------------- |
| `keep_alive_interval`                                      | 5 s              | [`quic.rs:151`][quic-defaults]  |
| `default_path_keep_alive_interval` (`HEARTBEAT_INTERVAL`)  | 5 s              | [`socket.rs:109`][socket-const] |
| `default_path_max_idle_timeout` (`PATH_MAX_IDLE_TIMEOUT`)  | 15 s             | [`socket.rs:109`][socket-const] |
| relay-path idle timeout                                    | 30 s             | [`socket.rs:109`][socket-const] |
| connection `max_idle_timeout`                              | 30 s             | [`quic.rs:151`][quic-defaults]  |
| `max_concurrent_multipath_paths` (`MAX_MULTIPATH_PATHS`)   | 8                | [`socket.rs:109`][socket-const] |
| `max_remote_nat_traversal_addresses` (`MAX_QNT_ADDRESSES`) | 32               | [`socket.rs:109`][socket-const] |
| retry-token lifetime                                       | 15 s             | [`quic.rs:613`][quic-server]    |
| TLS tickets (`8 * 32`)                                     | 256 (≈150 KiB)   | [`tls.rs:35`][tls-tickets]      |
| `max_incoming`                                             | 65536            | [`quic.rs:613`][quic-server]    |
| per-`Incoming` buffer / total                              | 10 MiB / 100 MiB | [`quic.rs:613`][quic-server]    |
| `initial_rtt`                                              | 333 ms           | [`quic.rs:151`][quic-defaults]  |
| `initial_mtu` / `min_mtu`                                  | 1200             | [`quic.rs:151`][quic-defaults]  |

Public setters _guard_ the holepunching values: multipath paths `< 9` are ignored with a warning (code enforces `MAX_MULTIPATH_PATHS + 1`, though the doc says "recommended 13" — a doc/code mismatch, [`quic.rs:462`][quic-guards]); path idle `> 15 s` is clamped; path keep-alive `> 5 s` is ignored; NAT addresses `< 8` are ignored.

### Connect flow

`Endpoint::connect(addr, alpn)` is `connect_with_opts(...).await?` then awaiting the `Connecting` future ([`endpoint.rs:1050`][ep-connect]). `connect_with_opts` ([`endpoint.rs:1090`][ep-connect-opts]) runs a fixed pipeline:

```text
Endpoint::connect(addr, alpn)
  └─ connect_with_opts(addr, alpn, opts)
       1. closed check                       → EndpointClosed
       2. hooks.before_connect(&addr, alpn)  → LocallyRejected on Reject
       3. self-connect check                 → SelfConnect
       4. inner.resolve_remote(addr)  ──────▶ socket Actor (RemoteStateActor):
             starts/updates remote state, seeds relay + IP paths,
             kicks off address_lookup if no path known,
             returns EndpointIdMappedAddr (a synthetic per-remote IP)
       5. build ClientConfig { [alpn] ++ additional_alpns, transport_config }
       6. noq.connect_with(cfg, mapped.private_socket_addr(),
                           "<base32(endpoint_id)>.iroh.invalid")
  └─ .await  ⇒  Connecting
       poll noq::Connecting → handshake done → conn_from_noq_conn:
         extract EndpointId from the single ed25519 cert,
         extract negotiated ALPN from rustls HandshakeData,
         register_connection with the RemoteStateActor,
         hooks.after_handshake(&conn) → LocallyRejected on Reject
  ⇒  Connection<HandshakeCompleted>
```

The key indirection is that `noq` never sees a real peer address: `resolve_remote` returns an `EndpointIdMappedAddr` — a synthetic per-remote IP the QUIC stack dials while the real path selection happens underneath in the [socket][socket] layer ([`socket.rs:1320`][socket-resolve]). The TLS `server_name` (`SNI`) is `base32(endpoint_id) + ".iroh.invalid"` ([`tls/name.rs:17`][tls-name-enc]). A code comment notes the `noq` connect "will time out after 10 seconds if no reachable address is available" ([`endpoint.rs:1090`][ep-connect-opts]); the exact origin of that 10 s bound is a handshake-phase/PTO limit inside `noq` (see [`quic-transport`][quic-transport]), not a constant in this layer. On handshake completion, `conn_from_noq_conn` extracts the remote `EndpointId` from the single ed25519 certificate ([`connection.rs:377`][conn-identity]).

### Accept flow and the `Incoming` verbs

`Endpoint::accept()` returns `Accept<'_>` wrapping `noq::Accept` ([`endpoint.rs:1162`][ep-accept]); it yields `None` once the endpoint is closed. Each yield is an `Incoming` — the server has _not yet_ begun its handshake, so the application can screen it cheaply before spending crypto:

```text
Endpoint::accept()  ⇒  Accept<'_>  (yields None once closed)
  each yield: Incoming             (server has not begun its handshake)
    inspectors: local_addr(), remote_addr() -> IncomingAddr,
                remote_addr_validated(),
                decrypt() -> Option<DecryptedInitial>   (peek ALPNs pre-handshake)
    verbs:
      accept()            → Accepting                  (begin handshake)
      accept_with(cfg)    → Accepting                  (per-connection ServerConfig)
      refuse()            → CONNECTION_REFUSED
      retry()             → QUIC RETRY packet          (Err(RetryError) if already validated)
      ignore()            → no response (peer times out)
      drop                → same as ignore
  Accepting  ── await ──▶ handshake done
    → register_with_socket → hooks.after_handshake → Connection<HandshakeCompleted>
    or Accepting::into_0rtt() (infallible) → Connection<IncomingZeroRtt>
```

`decrypt()` clones and decrypts the ~1200-byte Initial to reassemble `CRYPTO` frames and parse `ALPN`s out of the `ClientHello` _before_ handshaking ([`connection.rs:217`][conn-decrypt]; parser in [`noq-proto/src/endpoint.rs:1310`][noq-initial]). `retry()` is dual-purpose — for direct connections it is address validation; for [relay][relay] connections it is a cost-imposition mechanism ([`protocol.rs:197`][proto-retry]):

> _"In short: for direct connections, `Retry` is address validation; for relay connections, it is a cost-imposition mechanism."_

`Accepting` mirrors `Connecting` (`alpn().await`, `handshake_data().await`, `remote_addr()`, `into_0rtt()`) and resolves to `Connection` through the same two-phase poll: poll the inner `noq` handshake, then build and drive a `'static` register-with-socket + `after_handshake` future ([`connection.rs:660`][conn-accepting]).

### Type-state `Connection<State>` and 0-RTT

`Connection` is generic over a sealed state ([`connection.rs:736`][conn-typestate]):

```rust
// iroh/src/endpoint/connection.rs:736-803 — type-state connection
pub struct Connection<State: ConnectionState = HandshakeCompleted> {
    inner: noq::Connection,
    data: State::Data,
}
pub trait ConnectionState: sealed::Sealed { type Data: std::fmt::Debug + Clone; }
pub struct HandshakeCompleted;   // Data = { info: StaticInfo, paths: PathStateReceiver }
pub struct IncomingZeroRtt;      // Data = { accepted: Shared<BoxFuture<...>> }
pub struct OutgoingZeroRtt;      // Data = { accepted: Shared<BoxFuture<...>> }
```

The shared `impl<State: ConnectionState>` exposes every stream/datagram op in every state; only `alpn()` and `remote_id()` differ — infallible in `HandshakeCompleted`, `Option`/`Result` in the 0-RTT states. 0-RTT is asymmetric: the client's `Connecting::into_0rtt() -> Result<OutgoingZeroRttConnection, Connecting>` **fails** (handing the `Connecting` back) when no session ticket is cached ([`connection.rs:528`][conn-0rtt-client]), while the server's `Accepting::into_0rtt() -> IncomingZeroRttConnection` is **infallible** — _"incoming connections can always be converted to 0-RTT"_ ([`connection.rs:620`][conn-0rtt-server]). Both wrap the `noq` connection plus a `Shared<BoxFuture>` "accepted" future that, once the real handshake completes, runs `conn_from_noq_conn` and yields either a `Connection` (server) or `ZeroRttStatus::{Accepted, Rejected}(Connection)` (client) via `handshake_completed()`. Streams opened pre-handshake survive `Accepted` and error with `ZeroRttRejected` on `Rejected`, so the client resends on fresh streams ([`0rtt.rs:92`][ex-0rtt]).

### The `Router` and `ProtocolHandler`

`Router::builder(endpoint).accept(alpn, handler)…spawn()` registers a `ProtocolMap: BTreeMap<Vec<u8>, Box<dyn DynProtocolHandler>>` ([`protocol.rs:377`][proto-map]), calls `endpoint.set_alpns(...)`, and spawns one run-loop task ([`protocol.rs:501`][proto-runloop]). `ProtocolHandler` is an async trait with default methods ([`protocol.rs:228`][proto-handler]):

```rust
// iroh/src/protocol.rs:228-287 (trimmed)
pub trait ProtocolHandler: Send + Sync + std::fmt::Debug + 'static {
    fn on_accepting(&self, accepting: Accepting)
        -> impl Future<Output = Result<Connection, AcceptError>> + Send
    { async move { Ok(accepting.await?) } }
    fn accept(&self, connection: Connection)
        -> impl Future<Output = Result<(), AcceptError>> + Send;      // required
    fn shutdown(&self) -> impl Future<Output = ()> + Send
    { async move {} }
}
```

The run loop is a `tokio::select! { biased; }` over three arms, in priority order ([`protocol.rs:501`][proto-runloop]): (a) the router's `CancellationToken`; (b) `join_set.join_next()` — a task panic breaks the loop, failures break, cancellations are ignored; (c) `endpoint.accept()`. For each `Incoming`, an optional **`IncomingFilter`** — a _synchronous_ `Arc<dyn Fn(&Incoming) -> IncomingFilterOutcome>` with outcomes `Accept`/`Retry`/`Reject`/`Ignore` — runs inline _before_ any task spawn ([`protocol.rs:168`][proto-filter]). Accepted connections spawn a `handle_connection` task into a `JoinSet<Option<()>>`, wrapped in a per-handler `child_token().run_until_cancelled(...)`. `handle_connection` does `incoming.accept()` → `accepting.alpn().await` → `protocols.get(&alpn)` (unknown `ALPN`: log + drop) → `handler.on_accepting(accepting).await` → `handler.accept(connection).await` ([`protocol.rs:625`][proto-handle]).

`Router::shutdown` is a **two-phase graceful teardown** ([`protocol.rs:429`][proto-shutdown]): cancel the router token, then (1) await `protocols.shutdown()` (all handlers' `shutdown()` concurrently via `join_all`), (2) cancel `handler_cancel_token` (aborts in-flight `accept` futures), (3) `endpoint.close().await`, (4) `join_set.abort_all()` + drain. The `Router` handle is `Clone`; its run-loop task is stored as `Arc<Mutex<Option<AbortOnDropHandle<()>>>>`, so dropping the last `Router` aborts the loop.

### The `Runtime` seam

`noq` drives every driver task and timer through the `noq::Runtime` trait; iroh's implementation is the whole QUIC stack's coupling to its host executor ([`runtime.rs:9`][runtime]):

```rust
// iroh/src/runtime.rs:9-18 — the runtime seam noq drives everything through
pub(crate) struct Runtime {
    id: EndpointId,
    tasks: TaskTracker,
    cancel: CancellationToken,
    task_counter: AtomicU64,
}
impl noq::Runtime for Runtime {
    fn new_timer(&self, i: std::time::Instant) -> Pin<Box<dyn noq::AsyncTimer>>;
    fn spawn(&self, future: Pin<Box<dyn Future<Output = ()> + Send>>);
    fn wrap_udp_socket(&self, t: std::net::UdpSocket)
        -> io::Result<Box<dyn noq::AsyncUdpSocket>>; // "not actually using this"
}
```

`spawn` refuses when closed, wraps each future in `cancel.run_until_cancelled(...)`, and tracks it; `new_timer` delegates to `noq::TokioRuntime`; `wrap_udp_socket` is documented dead code — the endpoint uses `new_with_abstract_socket`, so the QUIC stack never touches a raw UDP socket through this trait ([`runtime.rs:103`][runtime-wrap]). `shutdown()` = cancel + close the tracker + `tasks.wait().await`; `abort()` = cancel + close with no wait.

---

## Analysis

### Wire format & framing

This subsystem defines almost no wire bytes — QUIC/TLS framing lives in `noq` (see [`wire-serialization`][wire]). What it _does_ pin:

- **`ALPN` identifiers** are free-form byte strings chosen by applications: `b"iroh-example/echo/0"` ([`echo.rs:20`][ex-echo]), `b"n0/iroh/transfer/example/1"` ([`transfer.rs:68`][ex-transfer]). Router dispatch is exact-match on `ALPN` bytes; the **accept side determines the negotiated protocol**, connect-side order is irrelevant ([`endpoint.rs:1799`][ep-accept-decides]).
- **TLS `SNI` / server name**: `BASE32_DNSSEC(endpoint_id_32_bytes) + ".iroh.invalid"` — 52 base32 chars plus suffix (hex would exceed the 63-char DNS-label limit) ([`tls/name.rs:17`][tls-name-enc]). The `.invalid` TLD is chosen per [RFC 2606][rfc2606] precisely so per-remote names bucket 0-RTT session tickets correctly ([`tls/name.rs:1`][tls-name]):

  > _"We used to use a constant "localhost" for the TLS server name - however, that affects 0-RTT and would put all of the TLS session tickets we receive into the same bucket in the TLS session ticket cache. So we choose something that'd dependent on the EndpointId. … We use the `.invalid` TLD, as that's specified (in RFC 2606) to never actually resolve "for real"."_

- **Peer identity**: exactly one `CertificateDer` in the TLS handshake; `EndpointId` = the ed25519 verifying key parsed with `VerifyingKey::from_public_key_der` (SPKI DER). A count `≠ 1` or a parse failure yields `RemoteEndpointIdError` ([`connection.rs:377`][conn-identity]). See [`identity-crypto`][identity].
- **Close frames**: `close(error_code: VarInt, reason: &[u8])` — code and reason are application-opaque, reason truncated to one packet ([`connection.rs:935`][conn-close]). `Endpoint::close` and connection-drop use code `0` + empty reason.
- **Initial-packet `ALPN` peek**: `DecryptedInitial::alpns()` reassembles `CRYPTO` frames and parses the `ClientHello` (handshake type `0x01`, u24 length, `ALPN` extension `0x0010`, u8-length-prefixed names) — best-effort, `None` if the hello spans packets it cannot reassemble ([`noq-proto/src/endpoint.rs:1310`][noq-initial]).

### Cryptography & identity

The endpoint's identity is an ed25519 `SecretKey` (random if unset); the corresponding `EndpointId` is the public key, transported as the single self-signed TLS certificate and re-derived on the peer from `HandshakeData` ([`connection.rs:377`][conn-identity]). The crypto provider is a **mandatory** rustls `CryptoProvider` ([`endpoint.rs:747`][ep-crypto]), shared with relay/pkarr/DoH HTTPS TLS. Post-quantum is not a dedicated API: an `X25519MLKEM768`-only provider is injected via `crypto_provider` (requires the `aws-lc-rs` backend), though PQ-only endpoints cannot yet reach n0 relay/lookup infrastructure ([`pq-only-key-exchange.rs:90`][ex-pq]). TLS 1.3 session resumption backs 0-RTT; the ticket cache defaults to `8 * 32 = 256` entries (≈150 KiB) keyed per-remote via the `SNI` scheme above ([`tls.rs:35`][tls-tickets]). `export_keying_material` ([RFC 5705][rfc5705]) is exposed on `HandshakeCompleted` connections. Full treatment in [`identity-crypto`][identity].

### State machines & lifecycle

Six state machines govern this subsystem:

1. **`Incoming` (accept side)** — `Incoming` → `accept()`/`accept_with(cfg)` → `Accepting` → register-with-socket → `after_handshake` → `Connection`. Alternative exits: `refuse()`, `retry()` (with `RetryError` recovery via `into_incoming()`), `ignore()`, drop ([`connection.rs:137`][conn-incoming]).
2. **`Connecting` (dial side)** — the connect pipeline above; `into_0rtt()` succeeds only with a cached ticket ([`connection.rs:528`][conn-0rtt-client]).
3. **`Connection<State>` type-state** — `IncomingZeroRtt`/`OutgoingZeroRtt` → `HandshakeCompleted`, _witnessed_ by `handshake_completed()` (not mutated in place); the 0-RTT handles stay usable for streams throughout ([`connection.rs:736`][conn-typestate]).
4. **`Router` lifecycle** — `spawn()` → biased-select run loop → `shutdown()` (or drop-guard) → the four-step teardown. A handler panic breaks the loop and resurfaces from `Router::shutdown` as a `JoinError` ([`protocol.rs:429`][proto-shutdown]).
5. **Endpoint shutdown** — `ShutdownState { at_close_start, at_endpoint_closed, closed }` ([`socket.rs:281`][socket-shutdown]). `close()`: cancel `at_close_start` (stops net-reports) → clear address-lookup services → `noq.close(0, b"")` → `wait_all_draining().await` (close-frame delivery + ack, worst case ≈3 s PTO) → cancel `at_endpoint_closed` → 100 ms grace for the actor task → `runtime.shutdown().await`. Idempotent; `abort()` (the Drop path) skips all waiting ([`socket.rs:1148`][socket-drain]).
6. **`online()` wait loop** — watches `home_relay_status()` and returns once any relay `is_connected()`; **pends forever** if no relay is configured or reachable — deliberately timeout-free ([`endpoint.rs:1355`][ep-online]).

The QUIC-vs-TCP asymmetry motivates the drain ([`endpoint.rs:1695`][ep-close-comment]):

> _"Someone used to closing TCP sockets might wonder why it is necessary to wait for timeouts when closing QUIC endpoints … This is due to QUIC and its acknowledgments being implemented in user-land, while TCP sockets usually get closed and drained by the operating system in the kernel during the 'Time-Wait' period."_

### Dependencies & coupling

| Crate                            | Depth                                                                                                    | Note for the D port                                                                |
| -------------------------------- | -------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- |
| `noq` / `noq-proto` (quinn fork) | **Load-bearing** — the entire QUIC stack, ~50 types re-exported verbatim ([`quic.rs:15`][quic-reexport]) | Reimplement separately ([`quic-transport`][quic-transport]); this layer is a shell |
| `rustls` + `ring`/`aws-lc-rs`    | Load-bearing: TLS 1.3, `ALPN`, session tickets, kx groups, keying-material export                        | Needs a TLS 1.3 stack with resumption + raw ed25519-cert verification              |
| `ed25519-dalek` (+pkcs8)         | `VerifyingKey::from_public_key_der` for identity ([`connection.rs:377`][conn-identity])                  | ed25519 + SPKI DER parse (see [`identity-crypto`][identity])                       |
| `n0-error`                       | API surface: `stack_error` derive, `e!`, `ensure!`, `AnyError`                                           | Only the error _shapes_ matter → `Expected`/`Cause` taxonomy                       |
| `n0-future`                      | `task::{spawn, JoinSet, AbortOnDropHandle, JoinError}`, `BoxFuture`                                      | event-horizon natives                                                              |
| `n0-watcher`                     | `Watcher` — watch-like observable (`get`/`updated`/`stream`/`or`/`map`)                                  | **No event-horizon equivalent — needs design** (a `Watchable!T`)                   |
| `tokio` / `tokio-util`           | runtime; `CancellationToken`, `TaskTracker`, `run_until_cancelled`                                       | `CancelContext` tree covers all uses                                               |
| `futures-util`                   | `Shared` (multi-waiter future), `FutureExt`                                                              | Needs a memoized multi-waiter completion cell                                      |
| `data-encoding`                  | `BASE32_DNSSEC` for `SNI` ([`tls/name.rs:17`][tls-name-enc])                                             | Trivial base32                                                                     |

The coupling to `noq` is total but _narrow_: it flows through the re-export list plus the `Runtime` trait. The port's job is to reimplement `noq`, then re-shell it — this module's logic (identity extraction, the four interception layers, the guarded config knobs, the router loop) is small and portable.

### Concurrency & I/O model

The subsystem's concurrency inventory — a small, [tokio][tokio]-shaped surface (see the [async-io survey][async-io] for the runtime it is built on) ([`protocol.rs`][proto-runloop], [`runtime.rs`][runtime], [`socket.rs`][socket-actormsg]):

| Primitive                                                       | Purpose                                                                  |
| --------------------------------------------------------------- | ------------------------------------------------------------------------ |
| `task::spawn` + `AbortOnDropHandle` (run loop)                  | Router accept loop                                                       |
| `JoinSet<Option<()>>`                                           | one `handle_connection` task per accepted connection                     |
| `CancellationToken` ×2 (`cancel_token`, `handler_cancel_token`) | shutdown signal; per-handler `run_until_cancelled`                       |
| `tokio::select! { biased; }`                                    | cancel > task-reap > accept priority                                     |
| `Runtime`: `TaskTracker` + `CancellationToken` + `AtomicU64`    | ALL noq-spawned tasks (EndpointDriver, ConnectionDrivers)                |
| `mpsc::channel(256)` `ActorMessage`                             | socket Actor inbox: `ResolveRemote`, `AddConnection`, `NetworkChange`, … |
| `oneshot` replies                                               | `resolve_remote` / `register_connection` request-response                |
| `Shared<BoxFuture>` (futures-util)                              | multi-waiter 0-RTT "handshake completed" future                          |
| `n0_watcher::Watcher`                                           | `watch_addr`, `home_relay_status`, `net_report`, `online()`              |

There is **no `spawn_blocking`**, no `broadcast`, and no `RwLock` beyond `configured_addrs`. The `Mutex`es on `Router.task` and `actor_task` exist only to make the handles `Clone + Send` while permitting a `take()`-then-await at shutdown — vestigial under single-threaded ownership. This is a full inventory-level treatment in [`concurrency`][concurrency].

### Mapping to event-horizon

The `noq::Runtime` seam is the port's front door: it is exactly the shape [`event-horizon`][eh-spec] — the completion-first fiber + [algebraic-effect][algebraic-effects] runtime — replaces. The `TaskTracker` + `CancellationToken` pair _is_ a `Scope` — exit joins children, `abort` = cancel the subtree — so the boxed trait object becomes a monomorphized capability row handed to the QUIC core:

```rust
// iroh/src/runtime.rs:9-18 (see full definition above)
pub(crate) struct Runtime {
    id: EndpointId, tasks: TaskTracker,
    cancel: CancellationToken, task_counter: AtomicU64,
}
// spawn → run_until_cancelled + track; new_timer → tokio; wrap_udp_socket → dead code
```

```d
// proposed / sketch — the concurrency seam becomes an event-horizon capability row,
// not a boxed trait object; noq's driver fibers live on the Endpoint's Scope.
struct QuicRuntime(Env)
{
    Env       env;      // CtxOf!(RingClock, RingNet, ...) — authority, monomorphized
    Scope*    scope;    // structured-concurrency nursery; exit joins all drivers
    EndpointId id;

    // was noq::Runtime::spawn(BoxFuture<()>): a daemon driver fiber on the scope
    void spawnDriver(scope void delegate() @safe body) => scope.spawnDaemon(body);

    // was noq::Runtime::new_timer(Instant): an in-ring TIMEOUT op / deadline scope
    Timer newTimer(MonoTime deadline) => env.clock.timerAt(deadline);

    // was wrap_udp_socket: DEAD CODE in iroh (new_with_abstract_socket) — omit entirely
}
```

**Router run loop** → one fiber owning the `ProtocolMap`, using `race` (cancel vs accept — the `biased` priority is the natural first-completion semantics of `race`); per-connection handlers → `Scope.spawn` into a child scope; `handler_cancel_token` → a child `CancelContext`; `abort_all` → scope cancel. `accept() -> Option` (None when closed) maps to an `Outcome` interrupt or a sentinel; the `select!`-in-a-loop consumers translate to `repeat`/`race` drivers.

The **type-state `Connection<State>`** maps beautifully to a D template with `static if`-gated members — DbI-native, zero-cost; the sealed-trait trick is unnecessary because module-private template constraints seal it:

```rust
// iroh/src/endpoint/connection.rs:736-803 (see full definition above)
pub struct Connection<State: ConnectionState = HandshakeCompleted> {
    inner: noq::Connection,
    data: State::Data,
}
```

```d
// proposed / sketch — DbI typestate: one template, `static if`-gated members.
struct Connection(State = HandshakeCompleted)
    if (isConnectionState!State)
{
    NoqConnection inner;          // the re-exported noq connection handle
    State.Data    data;

    // shared surface, present in every state:
    IoResult!Stream openBi() { /* ... */ }
    IoResult!void   sendDatagram(scope const(ubyte)[] d) { /* ... */ }

    static if (is(State == HandshakeCompleted))
    {
        // infallible in the completed state:
        const(ubyte)[] alpn()     @safe pure nothrow @nogc { return data.info.alpn; }
        EndpointId     remoteId() @safe pure nothrow @nogc { return data.info.endpointId; }
    }
    else  // IncomingZeroRtt / OutgoingZeroRtt — optional until the handshake completes
    {
        Nullable!(const(ubyte)[]) alpn() { /* ... */ }
    }
}
```

**`ProtocolHandler`** — an async trait with default methods, dyn-erased via `DynProtocolHandler` — becomes a struct-of-delegates row keyed by exact `ALPN` bytes (the `BTreeMap` ordering is irrelevant; only exact-match lookup happens):

```rust
// iroh/src/protocol.rs:228-287 (see full definition above)
pub trait ProtocolHandler: Send + Sync + std::fmt::Debug + 'static {
    fn on_accepting(&self, accepting: Accepting) -> impl Future<...> + Send { /* default */ }
    fn accept(&self, connection: Connection)     -> impl Future<...> + Send;      // required
    fn shutdown(&self)                            -> impl Future<...> + Send { /* no-op */ }
}
```

```d
// proposed / sketch — a row of fiber-blocking delegates keyed by exact ALPN bytes.
// No async-trait, no dyn-erasure, no boxed futures; dispatch is exact-match lookup.
struct ProtocolHandler
{
    Outcome!Connection delegate(Accepting) onAccepting;  // default: just await accepting
    Outcome!void       delegate(Connection) accept;      // required
    void               delegate()           shutdown;    // default: no-op
}

alias ProtocolMap = ProtocolHandler[immutable(ubyte)[]]; // exact-match AA, order irrelevant
```

Three constructs have **no event-horizon equivalent and need new design**:

- **`Shared<BoxFuture>` 0-RTT accepted future** — cloned and awaited by many waiters ([`connection.rs:736`][conn-typestate]). `JoinHandle.join` is single-consumer; the port needs a **memoized one-shot completion cell** (a promise/event caching its `Outcome`). Flag as a new primitive.
- **`n0_watcher::Watcher`** — `watch_addr`, `home_relay_status`, `online()`, `net_report` all sit on it. The brief notes `tokio::sync::watch` has no counterpart, so a **`Watchable!T`** (version-counter + waiter list on one loop) is a prerequisite for `Endpoint.addr()`/`online()`.
- **The socket `Actor` + `oneshot`** (`resolve_remote`, `register_connection`) — under the `single` topology there is no data race, so these can be **direct capability-method calls** on the socket state object, eliminating the `mpsc(256)` + `oneshot` pair. But `resolve_remote` _awaits_ address lookup, so it must remain a **suspendable** (fiber-blocking) method, not a plain getter. Keeping actor isolation for clarity instead would hit open-issue **O20** (no cross-fiber channels).

**Single-threaded implications** are favourable: `noq`'s tasks are host-spawned and the endpoint uses an abstract socket, so a fiber port never needs `wrap_udp_socket`; the `Arc<Mutex<…>>` handle-guards collapse to plain ownership; CPU work here is trivial (no blake3 on this loop — that concern belongs to [`blobs`][blobs]). The `IncomingFilter` is deliberately synchronous — a plain `@nogc` delegate that must stay non-suspending by construction ([`protocol.rs:168`][proto-filter]). Hooks, by contrast, are _awaitable_ (the auth example runs a full side-connection inside `before_connect`), so they must run on the calling fiber and take the `Connection` by non-owning reference to preserve the "don't keep it alive" contract — implying the port needs weak-connection semantics (a `WeakConnectionHandle`, or an id + registry lookup) ([`hooks.rs:93`][hooks-weak]). Close/drop maps to an `onExit` LIFO hook on the endpoint's `Scope` running `close()` as structured teardown; the "drop without close" case becomes a debug assert in the destructor, since single-threaded lifetimes are deterministic. See [`d-architecture-migration`][d-migration] for the whole-stack synthesis.

---

## Strengths

- **Small, portable policy shell.** The identity model, the four interception layers, the guarded holepunching defaults, and the router loop are a few thousand lines over `noq` — the reimplementation surface for _this_ module is tractable once the QUIC core exists.
- **Host-injectable concurrency.** The `noq::Runtime` trait is a clean seam: the entire QUIC stack's task/timer coupling is one ~135-line adapter, ideal for swapping in an event-horizon `Scope`/`Env` capability.
- **Type-state `Connection<State>`** encodes 0-RTT correctness in the type system and translates to zero-cost DbI templates in D.
- **Four distinct, well-placed interception layers** — synchronous `IncomingFilter`, async `before_connect`, `on_accepting`, async `after_handshake` — cover screening from cheapest (pre-decrypt) to richest (post-identity).
- **Cheap-clone, share-everything endpoint** with a principled graceful-close drain that respects QUIC's user-land ack semantics.
- **Abstract-socket design** means the QUIC stack never touches a raw UDP fd through the runtime seam — a natural fit for a completion-first port.

## Weaknesses

- **Total `noq` dependency.** The module is a veneer; nothing works until the QUIC/TLS core (multipath, NAT-traversal ext., address discovery, retry tokens, 0-RTT) is reimplemented — by far the larger effort (see [`quic-transport`][quic-transport]).
- **Three primitives with no event-horizon analogue** (`Watcher`, `Shared` multi-waiter future, actor + `oneshot`) force new designs before `Endpoint.addr()`/`online()`/0-RTT can be ported.
- **`online()` can pend forever** by design — a foot-gun without an application-level deadline.
- **Mandatory-`Preset` + mandatory-crypto-provider** ergonomics: `bind()` fails at runtime (`InvalidCryptoProvider`) rather than at compile time if the provider is missing.
- **Doc/code mismatches** in the guarded knobs (`max_concurrent_multipath_paths` doc says "13", code enforces `9`) are latent porting traps.
- **`Drop`-without-`close()`** is only an error-level log, not a hard failure — a hazard the D port should tighten into a destructor assert.

## Key design decisions and trade-offs

| Decision                                                             | Rationale                                                                                     | Trade-off                                                                                          |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `Endpoint` = `Arc<EndpointInner>`, single instance per app           | Share peer-to-peer connections + ticket cache across all clones for optimal network behaviour | All clones share fate; close must be coordinated; hidden global-ish state                          |
| Concurrency behind the `noq::Runtime` trait                          | Decouples the QUIC stack from any specific executor; one adapter is the whole coupling        | An indirection layer + boxed futures in Rust; the port must supply the substrate                   |
| Abstract socket (`new_with_abstract_socket`)                         | QUIC talks to iroh's multipath transport, not a UDP fd; enables synthetic mapped addresses    | `wrap_udp_socket` is dead code; extra address-space translation (`EndpointIdMappedAddr`)           |
| Mandatory `Preset` + mandatory crypto provider                       | Forces an explicit, correct crypto configuration; presets bundle the common setups            | Runtime `bind()` failure instead of a compile-time guarantee; more ceremony for `Empty`            |
| Type-state `Connection<State>` (sealed) for 0-RTT                    | Encodes handshake-completion invariants in types; shared op surface stays ergonomic           | Sealed-trait + `Shared` boilerplate; client `into_0rtt` is fallible, server infallible (asymmetry) |
| Four interception layers (sync filter + 3 async hooks)               | Screen from cheapest (pre-decrypt) to richest (post-identity) at the right cost               | More API surface; hooks are awaitable and can block the accept path                                |
| Router run loop = `select! { biased }` + `JoinSet` + 2 cancel tokens | Prioritise cancel > reap > accept; graceful two-phase shutdown with per-handler abort         | Bespoke lifecycle; handler panics break the loop; `Arc<Mutex<…>>` handle-guards for `Clone`        |
| `SNI` = `base32(EndpointId).iroh.invalid`                            | Per-remote ticket bucketing for correct 0-RTT; `.invalid` never resolves (RFC 2606)           | Non-standard server name; base32 chosen only to fit the 63-char DNS-label limit                    |
| Graceful close waits `wait_all_draining` (≈3 s PTO)                  | QUIC acks are user-land; frames must be flushed + acked, unlike kernel TCP `TIME-WAIT`        | `close()` is async and slow-ish; `Drop` fallback aborts and only logs an error                     |

---

## Sources

- [`iroh/src/endpoint.rs`][ep-struct] — `Endpoint`, `Builder`, connect/accept/close, knob inventory
- [`iroh/src/endpoint/connection.rs`][conn-typestate] — `Incoming`/`Accepting`/`Connecting`, type-state `Connection`, 0-RTT, identity
- [`iroh/src/endpoint/hooks.rs`][hooks-weak] — `EndpointHooks`, `before_connect`/`after_handshake`
- [`iroh/src/endpoint/presets.rs`][presets] — `Preset`, `Empty`/`Minimal`/`N0`/`N0DisableRelay`
- [`iroh/src/endpoint/quic.rs`][quic-reexport] — noq re-exports, `QuicTransportConfig`/`ServerConfig` guards
- [`iroh/src/protocol.rs`][proto-runloop] — `Router`, `ProtocolHandler`, `IncomingFilter`, run loop, shutdown
- [`iroh/src/runtime.rs`][runtime] — the `noq::Runtime` seam
- [`iroh/src/socket.rs`][ep-inner] — `EndpointInner`, `bind`, `resolve_remote`, `ShutdownState`, drain
- [`iroh/src/tls.rs`][tls-tickets] / [`iroh/src/tls/name.rs`][tls-name] — ticket constant, `SNI` encoding
- [`noq-proto/src/endpoint.rs`][noq-initial] — `DecryptedInitial` `ALPN` peek parser
- Examples: [`echo.rs`][ex-echo], [`transfer.rs`][ex-transfer], [`0rtt.rs`][ex-0rtt], [`auth-hook.rs`][ex-auth], [`pq-only-key-exchange.rs`][ex-pq]
- Related iroh pages: [`socket`][socket] · [`quic-transport`][quic-transport] · [`discovery`][discovery] · [`nat-traversal`][nat] · [`identity-crypto`][identity] · [`concurrency`][concurrency] · [`d-architecture-migration`][d-migration]

<!-- References -->

[repo]: https://github.com/n0-computer/iroh/tree/22cac742ca5e84da4542681e14b2d23b74c8330e
[docs]: https://docs.rs/iroh/1.0.1/iroh/
[ep-struct]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L897
[ep-single]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L861
[ep-empty]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L191
[ep-bind]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L225
[ep-crypto]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L747
[ep-connect]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L1050
[ep-connect-opts]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L1090
[ep-accept]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L1162
[ep-accept-decides]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L1799
[ep-close-comment]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L1695
[ep-online]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint.rs#L1355
[conn-typestate]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/connection.rs#L736
[conn-identity]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/connection.rs#L377
[conn-incoming]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/connection.rs#L137
[conn-decrypt]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/connection.rs#L217
[conn-accepting]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/connection.rs#L660
[conn-0rtt-client]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/connection.rs#L528
[conn-0rtt-server]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/connection.rs#L620
[conn-close]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/connection.rs#L935
[hooks-weak]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/hooks.rs#L93
[presets]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/presets.rs#L21
[presets-min]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/presets.rs#L57
[presets-n0]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/presets.rs#L110
[quic-reexport]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/quic.rs#L15
[quic-defaults]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/quic.rs#L151
[quic-guards]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/quic.rs#L462
[quic-server]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/endpoint/quic.rs#L613
[proto-runloop]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/protocol.rs#L501
[proto-handler]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/protocol.rs#L228
[proto-map]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/protocol.rs#L377
[proto-handle]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/protocol.rs#L625
[proto-shutdown]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/protocol.rs#L429
[proto-filter]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/protocol.rs#L168
[proto-retry]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/protocol.rs#L197
[runtime]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/runtime.rs#L9
[runtime-wrap]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/runtime.rs#L103
[ep-inner]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L204
[socket-bind]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L874
[socket-abstract]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1027
[socket-grease]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1013
[socket-resolve]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1320
[socket-actormsg]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1379
[socket-shutdown]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L281
[socket-drain]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1148
[socket-drop]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L220
[socket-const]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L109
[tls-tickets]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/tls.rs#L35
[tls-name]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/tls/name.rs#L1
[tls-name-enc]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/tls/name.rs#L17
[ex-echo]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/examples/echo.rs#L20
[ex-transfer]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/examples/transfer.rs#L68
[ex-0rtt]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/examples/0rtt.rs#L92
[ex-auth]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/examples/auth-hook.rs#L175
[ex-pq]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/examples/pq-only-key-exchange.rs#L90
[noq-initial]: https://github.com/n0-computer/noq/blob/340e9c7da0d60eda6f5c7ffa7a36d20ed8d793fd/noq-proto/src/endpoint.rs#L1310
[quic]: ./quic-transport.md
[quic-transport]: ./quic-transport.md
[socket]: ./socket.md
[nat]: ./nat-traversal.md
[relay]: ./relay.md
[discovery]: ./discovery.md
[net-report]: ./net-report.md
[identity]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[blobs]: ./blobs.md
[concurrency]: ./concurrency.md
[d-migration]: ./d-architecture-migration.md
[concepts]: ./concepts.md
[index]: ./index.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[tokio]: ../async-io/tokio.md
[async-io]: ../async-io/index.md
[algebraic-effects]: ../algebraic-effects/index.md
[rfc9000]: https://www.rfc-editor.org/rfc/rfc9000
[rfc8446]: https://www.rfc-editor.org/rfc/rfc8446
[rfc7301]: https://www.rfc-editor.org/rfc/rfc7301
[rfc2606]: https://www.rfc-editor.org/rfc/rfc2606
[rfc5705]: https://www.rfc-editor.org/rfc/rfc5705
