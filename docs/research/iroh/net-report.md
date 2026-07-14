# Net Report, Interface Watching & Port Mapping

iroh's connectivity-sensing layer — the descendant of Tailscale's `netcheck` that answers "what does the network look like from here right now": does UDP work over IPv4/IPv6, what public address does the world see, is the NAT mapping endpoint-dependent (symmetric), which relay is closest, and is there a captive portal — measured entirely through QUIC Address Discovery and HTTPS (STUN and ICMP are **gone**), fed by per-OS interface/route watching (`netwatch`) and UPnP/PCP/NAT-PMP port mapping (`portmapper`).

| Field               | Value                                                                                                                                                                                                                                                                                                   |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Crate(s)            | `iroh` module `net_report` (`net_report/{reportgen,probes,report,options,defaults,metrics}`) + the `portmapper` wrapper module; standalone `netwatch` and `portmapper` crates (the [`net-tools`][nettools] workspace)                                                                                   |
| Version             | iroh **v1.0.1** (git `v1.0.1-6-g22cac742ca`, commit `22cac742ca`); `netwatch` **0.19.1** + `portmapper` **0.19.1** (net-tools commit `051ab876`, = tags `netwatch-v0.19.1` / `portmapper-v0.19.1`)                                                                                                      |
| Repository          | [`n0-computer/iroh`][repo] (module `iroh/src/net_report/`), [`n0-computer/net-tools`][nettools] (`netwatch/`, `portmapper/`)                                                                                                                                                                            |
| Documentation       | [docs.rs/iroh][docs] — `net_report` is `pub(crate)`, surfaced only through `Endpoint::net_report()`; [docs.rs/netwatch][docs-netwatch], [docs.rs/portmapper][docs-portmapper]                                                                                                                           |
| ALPN(s)             | `/iroh-qad/0` — the QUIC Address Discovery probe ALPN ([`ALPN_QUIC_ADDR_DISC`][qad-alpn], via [`iroh-relay`][relay]). HTTPS/captive-portal probes are plain HTTP(S), no ALPN of iroh's own                                                                                                              |
| Approx. size (LoC)  | ~2.8k `net_report` module + ~0.1k `portmapper` wrapper (iroh); ~4.9k `netwatch` (`udp.rs` 1218, `interfaces*` ~1.8k, `netmon*` ~0.7k); ~2.7k `portmapper` crate (`lib.rs` 794 + PCP/NAT-PMP/UPnP + wire codecs) — ≈**10.5k** total                                                                      |
| Category            | Connectivity                                                                                                                                                                                                                                                                                            |
| Upstream spec/draft | QAD = [draft-seemann-quic-address-discovery][qad-draft] (in [`noq-proto`][quic]); [RFC 6887][rfc6887] (PCP); [RFC 6886][rfc6886] (NAT-PMP); [UPnP-IGD][igd] `WANIPConnection` (SSDP + SOAP); captive-portal via the `generate_204` convention. Descends from Tailscale [`netcheck`][tailscale-netcheck] |

> [!NOTE]
> This is iroh's connectivity-sensing tier, restructured for 1.0. The subsystem is **three cooperating pieces**: `net_report` (the report generator, owned by [`socket`][socket]), `netwatch` (interface enumeration + route-change monitoring + the rebindable `UdpSocket`), and `portmapper` (UPnP/PCP/NAT-PMP). In iroh 0.x this was `netcheck` + `portmapper` and probed with **STUN** (UDP v4/v6) and **ICMP**; in 1.0 both are gone — the only probes are QUIC Address Discovery ("QAD") over the _main_ [`noq`][quic] endpoint and HTTPS. `NodeId` → [`EndpointId`][identity], "discovery" → `address_lookup` (see [`discovery`][discovery]); vocabulary in [Concepts][concepts]. Part of the [iroh survey][index].

---

## Overview

### What it solves

A peer that wants direct connectivity must first understand its own vantage point. `net_report` measures it: it decides whether the host has working UDP on each address family, what public `SocketAddr` a remote observer assigns it (the raw material for a direct-address candidate), whether that mapping is stable across destinations or varies per-peer (a symmetric NAT that defeats naive hole-punching), which configured relay is lowest-latency (the _home relay_), and whether a captive portal is intercepting traffic. Those findings drive two decisions in the [`socket`][socket] layer above it: **which relay to camp on** and **which direct-address candidates to advertise** for [NAT traversal][nat].

Two sibling subsystems supply the inputs. `netwatch` enumerates network interfaces, finds the default gateway, and watches the OS for link changes so a report is re-run when the network moves underfoot; it also owns the rebindable `UdpSocket` through which every QUIC datagram actually flows. `portmapper` asks the local router (via UPnP, PCP, or NAT-PMP) to install an explicit port mapping and keep it renewed, yielding a fourth kind of direct-address candidate (`Portmapped`). Together they are the layer where a native port learns exactly which raw OS surface — netlink sockets, `AF_ROUTE` routing sockets, `sysctl` route dumps, `/proc/net/route`, Win32 IP Helper notifications, `getifaddrs`, and the PCP/NAT-PMP datagram codecs — it must bind.

### Design philosophy

`net_report` states its remit at the top of the module ([`net_report.rs:3`][nr-doc]):

> _"NetReport is responsible for finding out the network conditions of the current host, like whether it is connected to the internet via IPv4 and/or IPv6, what the NAT situation is etc and reachability to the configured relays."_

It is explicitly _"Based on `https://github.com/tailscale/tailscale/blob/6ee7bcb4583575f8b2623bc16d55f92737465217/net/netcheck/netcheck.go`"_ ([`net_report.rs:6`][nr-doc]), and the 1.0 rewrite keeps `netcheck`'s _shape_ — a periodic, timeout-bounded, best-effort report merged into rolling history with hysteresis on the preferred relay — while replacing its _substrate_ wholesale. Three convictions follow, each with a direct consequence for a port:

1. **Probe with the transport you already have.** Rather than a bespoke STUN/ICMP probe socket, QAD rides the _main_ [`noq`][quic] endpoint (`ep: endpoint.clone()`, [`socket.rs:1046`][sk-ep]). Because the probe originates from the very UDP socket whose mapping it measures, the discovered `global_v4` is a _valid direct-address candidate_ — there is no "the probe socket saw a different mapping than the data socket" class of bug. Address discovery is a QUIC extension ([draft-seemann-quic-address-discovery][qad-draft]) implemented in [`noq-proto`][quic]; `net_report` merely consumes `conn.observed_external_addr()` and `conn.rtt(PathId::ZERO)`.

2. **Fail soft, always.** Every probe is racing and cancellable; the whole report is bounded by `OVERALL_REPORT_TIMEOUT` = 5 s ([`defaults.rs`][defaults]) and the socket wraps `get_report` in `NET_REPORT_TIMEOUT` = 10 s ([`defaults.rs:129`][sk-nettimeout]). HTTPS exists only as a fallback for QUIC-blocked networks ([`net_report.rs:97`][nr-https]):

   > _"Disabling them is harmless on networks that do allow QUIC traffic, but will completely prevent finding the home relay on networks that do block QUIC."_

3. **Reuse, don't re-probe.** A successful QAD connection is kept alive (25 s keep-alive, 35 s idle timeout) and its observed-address updates streamed into a watcher, so subsequent _incremental_ reports read a live NAT-refreshing connection instead of dialing again — report generation is partly passive observation, not active probing.

Within the survey this page is the connectivity-sensing counterpart to [`socket`][socket] (which _consumes_ its output), [`nat-traversal`][nat] (which uses the discovered candidates and symmetric-NAT flag), and [`relay`][relay] (whose home-relay selection this drives). The io_uring/kqueue/IOCP surface a port needs is surveyed in the [async-io tree][async-io].

---

## How it works

### Three probe kinds (STUN and ICMP are gone)

The `Probe` enum has exactly three variants ([`probes.rs:25`][probes]) — down from 0.x's six (STUN v4/v6, ICMP v4/v6, HTTPS, plus HTTP):

```rust
// iroh/src/net_report/probes.rs:25
pub enum Probe {
    Https,
    #[cfg(not(wasm_browser))] QadIpv4,
    #[cfg(not(wasm_browser))] QadIpv6,
}
```

**QAD probe.** The client dials each relay's QUIC address-discovery listener at the relay's QUIC port (default `DEFAULT_RELAY_QUIC_PORT` = **7842**, [`defaults.rs:7`][qad-port]) with ALPN `/iroh-qad/0` ([`quic.rs:10`][qad-alpn]), resolving the relay host via a _staggered_ A/AAAA DNS lookup (delays `[200, 300, 600, 1000, 2000, 3000]` ms, `DNS_TIMEOUT` 3 s — see [`discovery`][discovery]). The client transport config is tuned for a probe, not a bulk transfer: `initial_rtt(111 ms)`, `receive_observed_address_reports(true)`, `keep_alive_interval(25 s)`, `max_idle_timeout(35 s)` ([`quic.rs:283`][qad-rtt]):

> _"Setting the initial RTT estimate to a low value means we're sacrificing initial throughput, which is fine for QAD, which doesn't require us to have good initial throughput. It also implies a 999ms probe timeout, which means that if the packet gets lost (e.g. because we're probing ipv6, but ipv6 packets always get lost in our network configuration) we time out closing the connection after only 999ms."_

The server side is a plain `noq` endpoint with `send_observed_address_reports(true)` and zero allowed streams ([`quic.rs:102`][qad-server]). A probe _completes_ when the first `OBSERVED_ADDRESS` frame arrives; the result is a `QadProbeReport { relay, latency = conn.rtt(PathId::ZERO), addr }` where `addr` is canonicalized (an IPv4-mapped IPv6 observation collapses to v4) ([`reportgen.rs:447`][qad-report]).

**QAD connection caching.** Winners are _not_ closed. The first v4 winner and first v6 winner are parked in `QadConns { v4, v6 }` ([`net_report.rs:157`][nr-qadconns]); losers are closed with code `1` / reason `b"finished"` ([`quic.rs:14`][qad-alpn]). A per-connection task streams observed-address updates into a `Watchable<Option<QadProbeReport>>`, so incremental reports call `current_v4()`/`current_v6()` (which just refresh the RTT) with no new probe. The 25 s keep-alive doubles as a NAT-binding refresher. On a _full_ report the cache is cleared and re-probed; connections whose `close_reason` is set are evicted.

**HTTPS probe.** `GET {relay_url}/ping` (`RELAY_PROBE_PATH`, [`http.rs:15`][relay-http]) with redirects disabled and DNS overridden by the staggered resolver; latency = time-to-response-headers, body drained ≤ 8 KiB ([`reportgen.rs`][reportgen]). It is the only way to measure relay latency (hence pick a home relay) when QUIC is blocked.

**Captive-portal check.** Only on the first (full) report, delayed `CAPTIVE_PORTAL_DELAY` = 200 ms so a healthy QAD run can cancel it, timeout 2 s. It `GET`s `http://{host}/generate_204` with request header `X-Iroh-Challenge: ts_{host}` and treats anything other than `204` + response header `X-Iroh-Response: response ts_{host}` as a captive portal ([`reportgen.rs:619`][reportgen-captive]).

### Probe plan and scheduling

`Options::as_protocols()` turns config into a `BTreeSet<Probe>` of `{QadIpv4, QadIpv6, Https}` ([`options.rs:49`][options]). Crucially, **the `ProbePlan` only ever schedules HTTPS** — QAD is scheduled outside the plan. `ProbePlan::initial` emits, per relay, one `ProbeSet` of three HTTPS probes at delays 200/300/400 ms (`HTTPS_OFFSET` 200 ms + `DEFAULT_INITIAL_RETRANSMIT` 100 ms × attempt); the duplicates are racing retries ([`probes.rs:38`][probes-set]):

> _"The probes are to the same Relayer and of the same [`Probe`] but will have different delays. The delays are effectively retries, though they do not wait for the previous probe to be finished. The first successful probe will cancel all other probes in the set."_

`ProbePlan::with_last_report` returns an **empty plan** when the last report has any latencies (incremental runs skip HTTPS entirely, marked `// TODO: is this good?`), else falls back to the initial plan.

QAD probes fan out directly from `Client::spawn_qad_probes`: up to `MAX_RELAYS` = 5 relays (map order, `// TODO: randomize choice?`), one task per address family the interface state supports and that "needs probing" (v4 whenever there is no cached v4 report; v6 when cached-v6-presence disagrees with `if_state.have_v6`), each wrapped in `PROBES_TIMEOUT` = 3 s and a per-family child `CancellationToken` ([`net_report.rs:493`][nr-fanout]). The join loop early-cancels once `reports.len() >= enough_relays` (`min(3, num_relays)`, `ENOUGH_ENDPOINTS` = 3) _and_ at least one result per started family has landed.

`Client::get_report` (one long-lived struct per endpoint, owned by the socket) decides full vs incremental. A **full** report runs iff a `is_major` link change occurred, or it is the first run (`next_full`), or `> 5 min` since the last full report (`FULL_REPORT_INTERVAL`), or the last report saw a captive portal with no UDP ([`net_report.rs:303`][nr-full]). It then (1) runs QAD probes inline, (2) spawns the `reportgen` actor for HTTPS + captive portal, (3) merges `ProbeFinished` messages and live QAD watcher updates in a **biased** `select!`, updating the `Report` incrementally, and (4) stops early when `have_enough_reports` is satisfied — for a full report, with both families available: `(ipv4 ≥ 2 ∧ ipv6 ≥ 1) ∨ (ipv6 ≥ 2 ∧ ipv4 ≥ 1)`; single-family `≥ 2`; or `num_https ≥ num_relays`. Incremental thresholds drop to `≥ 1` per available family.

### Symmetric-NAT ("mapping varies by dest") detection

`Report::update` stores the first observed global v4 address in `global_v4`; each subsequent v4 QAD report _from a different relay_ is compared. Equal ⇒ `mapping_varies_by_dest_ipv4 = Some(false)` (only if still `None`); different ⇒ `Some(true)` + a warning ([`report.rs:88`][report-mapvaries]; v6 is symmetric). Because a full report probes up to 5 relays per family, two observations are normally available, so a symmetric (endpoint-dependent) NAT is detected within one report. `mapping_varies_by_dest()` ORs the two flags; if a new report learned nothing, the flags carry forward from the previous one. The socket uses the flag to synthesize an extra candidate (below).

### Report contents, history & preferred-relay selection

```rust
// iroh/src/net_report/report.rs:18
pub struct Report {
    pub udp_v4: bool,
    pub udp_v6: bool,
    pub mapping_varies_by_dest_ipv4: Option<bool>,
    pub mapping_varies_by_dest_ipv6: Option<bool>,
    pub preferred_relay: Option<RelayUrl>,
    pub relay_latency: RelayLatencies,       // 3 BTreeMap<RelayUrl, Duration>, min-latency per relay
    pub global_v4: Option<SocketAddrV4>,
    pub global_v6: Option<SocketAddrV6>,
    pub captive_portal: Option<bool>,
}
```

`RelayLatencies` keeps three `BTreeMap<RelayUrl, Duration>` (`ipv4`, `ipv6`, `https`), each retaining the _minimum_ latency seen ([`report.rs:136`][report-latencies]). `add_report_history_and_set_preferred_relay` maintains `Reports { prev: BTreeMap<Instant, Report>, last, last_full, next_full }`, prunes entries older than `MAX_AGE` = 5 min, merges recent latencies into a `best_recent` map, and picks the relay in the _current_ report with the lowest best-recent latency ([`net_report.rs:747`][nr-preferred]). **Hysteresis:** if the previous preferred relay is still present and the challenger is not faster than ⅔ of the old relay's current latency (`best_any > old_relay_cur_latency / 3 * 2`), the old relay is kept — preventing home-relay flapping between near-equal servers. Note `Report` has **no port-mapping fields** in 1.0 (0.x's did); port mapping is a sibling subsystem whose watch channel feeds the socket directly.

### How the socket consumes it (and when it runs)

The socket owns `net_reporter: Arc<AsyncMutex<net_report::Client>>` inside `DirectAddrUpdateState` ([`socket.rs:706`][sk-dau]). A report is (re-)run on one of several `UpdateReason`s ([`socket.rs:719`][sk-reason]):

| `UpdateReason`    | Trigger                                                                                                                                                        | Full?   |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------- |
| `Periodic`        | a `time::Interval` randomized to **20..=26 s** ("just under 30s, a common UDP NAT timeout"), reset after each completed report ([`socket.rs:2004`][sk-restun]) | no      |
| `PortmapUpdated`  | the portmapper's external-address watch changed                                                                                                                | no      |
| `LinkChangeMinor` | `netmon` reported a non-major interface change                                                                                                                 | no      |
| `LinkChangeMajor` | `netmon` reported a major change (default route / v4-v6 availability / interesting iface)                                                                      | **yes** |
| `RelayMapChange`  | the configured relay set changed                                                                                                                               | **yes** |

`schedule_run` uses `try_lock_owned`: if a report is already running, the reason is parked in `want_update` and re-fired when the running one signals completion via a `run_done` mpsc — the whole "only one report at a time" invariant is encoded as a lock-failure signal, not a queue. Each run first calls `port_mapper.procure_mapping()`.

The finished report lands in `Watchable<(Option<Report>, UpdateReason)>`. `handle_net_report_report` ([`socket.rs:1554`][sk-handle]): (a) stores `udp_v6` in an `AtomicBool ipv6_reported` used by relay dialing, (b) backfills `preferred_relay` with the current home relay if absent, (c) forwards the report so the relay transport actor **switches the home relay** if `preferred_relay` changed ([`relay/actor.rs:1124`][sk-homerelay], see [`relay`][relay]), and (d) recomputes **direct-address candidates**. `update_direct_addresses` ([`socket.rs:1814`][sk-uda]) merges, in priority order into a `BTreeMap<SocketAddr, DirectAddrType>`: the portmapper external address (`Portmapped`), `global_v4`/`global_v6` (`Qad`), then — when `mapping_varies_by_dest` is true and a socket is bound to a fixed non-zero port — the guess `global_v4_ip:local_port` (`Qad4LocalPort`, [`socket.rs:1841`][sk-qad4]):

> _"If they're behind a hard NAT and are using a fixed port locally, assume they might've added a static port mapping on their router to the same explicit port that we are running with. Worst case it's an invalid candidate mapping."_

then local interface addresses (expanding unspecified binds across every interface IP; loopback only if nothing else exists), then user-configured addresses. IPv6 addresses whose netmon flags say `deprecated` are filtered out.

### netwatch: interface state + change monitoring

`netmon::Monitor` spawns one actor owning a `Watchable<State>` fed by a per-OS `RouteMonitor` over a `NetworkMessage::Change` mpsc (cap 16). The actor **debounces for `DEBOUNCE` = 250 ms** ([`actor.rs:93`][nm-actor]), then rebuilds the whole `State::new()` snapshot and republishes only if it differs. It also polls wall time every 15 s (1 h on iOS/Android) and treats a jump `> 1.5×` the interval as an _unsuspend_ event, force-publishing with `last_unsuspend` set — a monotonic-vs-wall-clock skew test that detects the machine waking from sleep. External code can inject a hint via `Monitor::network_change()` (iroh surfaces this as `Endpoint::network_change`).

```rust
// netwatch/src/interfaces.rs:200 (trimmed)
pub struct State {
    pub interfaces: HashMap<String, Interface>,   // Interface wraps netdev::Interface
    pub local_addresses: LocalAddresses,          // { loopback: Vec<IpAddr>, regular: Vec<IpAddr> }
    pub have_v6: bool,                             // any 2000::/3 or fc00::/7 up
    pub have_v4: bool,                             // any non-loopback v4 up
    pub is_expensive: bool,                        // declared, compared, NEVER populated (dead)
    pub default_route_interface: Option<String>,
    pub last_unsuspend: Option<Instant>,
}
```

`is_major_change` fires on differing `have_v4`/`have_v6`/`is_expensive`/default-route-interface, or any _interesting_ interface added/removed/changed (flags, MAC, index) or its non-link-local, non-loopback, non-multicast prefixes changing ([`interfaces.rs:319`][nw-ismajor]). On macOS the `llw*`, `awdl*`, `ipsec*` interfaces are _uninteresting_; Linux and Windows treat everything as interesting.

The **per-OS route-monitoring facilities a port must bind** are the heart of this subsystem:

| OS                | Facility                                                                                                                                                                    | Notes for a port                                                                                                                                                                               |
| ----------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Linux**         | `AF_NETLINK`/`NETLINK_ROUTE` socket bound to `RTNLGRP_{IPV4,IPV6}_{IFADDR,ROUTE,RULE}` multicast groups ([`netmon/linux.rs:61`][nm-linux])                                  | parse `RTM_*` (`NewAddress`/`DelAddress`/`New`/`DelRoute`/`New`/`DelRule`); dedupe addrs per iface; ignore route table 254/255 + multicast/link-local dst; reconnect 1 s→30 s doubling backoff |
| **macOS/iOS/BSD** | raw `AF_ROUTE` socket (`socket(AF_ROUTE, SOCK_RAW)`) read nonblocking; RIB parsed with a Go `x/net`-derived parser ([`netmon/bsd.rs:95`][nm-bsd])                           | **must drain with `try_read` until `WouldBlock`** — registration is edge-triggered; backoff 50 ms→30 s                                                                                         |
| **Windows**       | `NotifyUnicastIpAddressChange(AF_UNSPEC, cb)` + `NotifyRouteChange2(AF_UNSPEC, cb)` from IP Helper; `CancelMibChangeNotify2` on drop ([`netmon/windows.rs:32`][nm-windows]) | callbacks fire on **foreign OS threads** and `try_send` into the channel                                                                                                                       |
| **Android**       | none ([`netmon/android.rs:16`][nm-android]): _"Very sad monitor. Android doesn't allow us to do this"_                                                                      | only the 250 ms-debounced external hints + wall-time polling                                                                                                                                   |

The macOS drain discipline is worth quoting because it maps precisely onto a completion-first runtime ([`netmon/bsd.rs:95`][nm-bsd]):

> _"Drains with `try_read` until `WouldBlock`. Do not read via `AsyncRead::read` one message per await: the fd is registered edge-triggered, so leaving data queued can lose the next readiness notification and permanently stall the monitor."_

**Default-route detection** ([`interfaces.rs:411`][nw-defroute]) is separately per-OS: Linux parses `/proc/net/route` for destination `00000000` mask `00000000` (read with an 8 KiB one-shot buffer because gVisor/Cloud Run requires it), falling back to a netlink `GetRoute` dump of `RT_TABLE_MAIN` selecting a `Gateway` attribute with `destination_prefix_length == 0`, then `GetLink` for the name ([`interfaces/linux.rs:62`][nw-linux-route]); Android shells out to `ip route show table 0`; BSD/macOS fetch the RIB via `sysctl([CTL_NET, AF_ROUTE, 0, af, NET_RT_DUMP2, 0])` (ENOMEM-retry ≤3) and select routes with `RTF_GATEWAY` set, `RTF_IFSCOPE` clear, all-zero dst+netmask ([`interfaces/bsd.rs:73`][nw-bsd-route]); Windows queries WMI `Win32_IP4RouteTable` inside `spawn_blocking` ("WMI uses COM which can deadlock on a tokio worker thread", [`interfaces/windows.rs:29`][nw-win-route]). `HomeRouter::new()` (gateway IP + own LAN IP, the portmapper target) uses `netdev`'s default-gateway on Linux/Android/Windows and the RIB scan on BSD.

### The rebindable `UdpSocket`

`netwatch::UdpSocket` is the socket every QUIC datagram flows through ([`udp.rs:20`][udp]):

```rust
// netwatch/src/udp.rs:20 (trimmed)
pub struct UdpSocket {
    socket: RwLock<SocketState>,
    recv_waker: AtomicWaker,
    send_waker: AtomicWaker,
    is_broken: AtomicBool,   // set on NotConnected(read)/BrokenPipe(write) -> lazy rebind
}
enum SocketState {
    Connected { socket: tokio::net::UdpSocket, state: noq_udp::UdpSocketState, addr: SocketAddr },
    Closed    { addr: SocketAddr, last_max_gso_segments: NonZeroUsize,
                last_gro_segments: NonZeroUsize, last_may_fragment: bool },
}
```

Buffers are 7 MiB each way ("the max supported by a default configuration of macOS", [`udp.rs:28`][udp-buf]); IPv6 sockets set `IPV6_V6ONLY` (no dualstack); bind verifies the requested nonzero port was actually obtained. **Rebind logic:** a read error `NotConnected` or write error `BrokenPipe` marks the socket broken; every subsequent operation first runs `maybe_rebind()`, which double-checks under the write lock, closes, and re-binds to the _same_ addr (preserving the port) ([`udp.rs:281`][udp-rebind]); the transport layer can also force `rebind()` on a major link change. Transient read errors are swallowed on **all** platforms ([`udp.rs:518`][udp-transient]):

> _"We treat `ConnectionReset` as transient on every platform, not only Windows: ECONNRESET is undefined in QUIC and can be injected by an attacker, so it must never tear down the receive path."_

(`WSAENETRESET` = 10052 is additionally swallowed on Windows.) **GSO/GRO** is delegated entirely to `noq_udp::UdpSocketState` (the quinn-udp fork): `try_send_noq`/`poll_send_noq` take a segmented `noq_udp::Transmit`; `poll_recv_noq` fills `IoSliceMut` + `RecvMeta` arrays with a per-datagram `stride` for GRO; `max_gso_segments`/`gro_segments`/`may_fragment` are cached across the `Closed` state ([`udp.rs:332`][udp-gso]). `close()` moves the fd to `spawn_blocking` because `libc::close` may block ([`udp.rs:192`][udp-close]).

### portmapper: probes, leases & renewal

One `Service` actor per client drives an mpsc(32) of `{ProcureMapping, UpdateLocalPort, Probe}` and emits a `watch::Receiver<Option<SocketAddrV4>>` of the current external address ([`lib.rs:434`][pm-lib]):

```rust
// portmapper/src/mapping.rs:18
pub enum Mapping { Upnp(upnp::Mapping), Pcp(pcp::Mapping), NatPmp(nat_pmp::Mapping) }
```

**Probe trust is cached** ([`lib.rs:40`][pm-trust]): a protocol seen within `AVAILABILITY_TRUST_DURATION` = 10 min is trusted without re-probe; a _mapping_ attempt against an unavailable protocol is tried only if the last probe is older than `UNAVAILABILITY_TRUST_DURATION` = 5 s. A probe runs the three protocol probes concurrently in a `select!` ([`lib.rs:280`][pm-probe]): **UPnP** SSDP `search_gateway` (igd-next, 1 s timeout, double-wrapped "because igd_next doesn't respect the set timeout"); **PCP** ANNOUNCE to `gateway:5351`, wait ≤500 ms; **NAT-PMP** DetermineExternalAddress to `gateway:5351`, wait ≤500 ms.

**Mapping strategy** ([`lib.rs:632`][pm-strategy]): prefer **PCP**, then **NAT-PMP**, then **UPnP** ("the most unreliable, but possibly the most deployed one"); if none is known-available, fall back to UPnP-if-enabled, then blind PCP, then blind NAT-PMP, else give up. Local IP + gateway come from `netwatch::interfaces::HomeRouter`.

**Lease renewal** is a small timer state machine in `CurrentMapping` ([`current_mapping.rs:122`][pm-current]): a stored mapping arms a sleep of `half_lifetime()`; on firing it emits `Event::Renew` and rearms for another half-lifetime with `expire_after = true`; the second firing emits `Event::Expired` and clears the mapping (and the watch). The service reacts to _both_ events identically — request a new mapping for the same external address/port. Requested lifetimes: PCP `MAPPING_REQUESTED_LIFETIME_SECONDS = 60 * 60` (**3600 s**, though the comment claims "2 hours" — a genuine bug, [`pcp.rs:14`][pm-pcp]); NAT-PMP `60 * 60 * 2` (**7200 s**, [`nat_pmp.rs:16`][pm-natpmp]); UPnP `2 * 60 * 60` (**7200 s**) with a fixed 1 h half-lifetime and description string `"iroh-portmap"` ([`upnp.rs:19`][pm-upnp]); PCP/NAT-PMP renew at `lifetime_seconds / 2` _as returned by the server_. iroh calls `procure_mapping()` at the start of every direct-address update, `update_local_port()` after binding, and `deactivate()` on shutdown ([`portmapper.rs:69`][iroh-portmapper]).

---

## Analysis

### Wire format & framing

The subsystem owns four distinct wire surfaces (QAD's frames are _not_ one of them — they live in [`noq-proto`][quic]):

**QAD (consumed, not framed here).** No custom framing in `net_report`; it is the [draft-seemann-quic-address-discovery][qad-draft] QUIC extension in [`noq-proto`][quic] — a transport parameter carrying a `Role` varint (0 send-only, 1 receive-only, 2 both) and `OBSERVED_ADDRESS` frames. `net_report` sees only `observed_external_addr()` (a watcher) and `rtt(PathId::ZERO)`. Identifiers a port must match: ALPN `/iroh-qad/0`, close code `1` / reason `b"finished"`, default port 7842. Frame-level encoding is deferred to [`quic-transport`][quic] and [`nat-traversal`][nat].

**HTTP probes.** `GET {relay}/ping` (2xx = success, drain ≤ 8 KiB) and `GET http://{host}/generate_204` with `X-Iroh-Challenge: ts_{host}` / expected `X-Iroh-Response: response ts_{host}`. Trivial HTTP/1.1 GETs — over TLS ([`rustls`][docs]) for `/ping`, plaintext for the portal check — with redirects disabled and a custom DNS resolver.

**PCP** ([RFC 6887][rfc6887], UDP port 5351, version 2). The 24-byte request header, then the 36-byte MAP opcode data, both fully in-tree (no external protocol crate) and directly portable:

```text
PCP request header — 24 bytes  (portmapper/src/pcp/protocol/request.rs)
 off size field
   0    1  version = 2
   1    1  opcode  (Announce = 0, Map = 1; response sets bit 0x80)
   2    2  reserved
   4    4  requested lifetime, u32 BE  (announce 0; map 3600; release 0)
   8   16  client IP as IPv4-mapped IPv6
MAP opcode data — 36 bytes appended
   0   12  mapping nonce
  12    1  protocol (UDP = 17, TCP = 6)
  13    3  reserved
  16    2  internal port, u16 BE
  18    2  suggested external port, u16 BE
  20   16  suggested external IP, v4-mapped
```

The client validates the echoed nonce, protocol, and internal port, and rejects external port 0 or a non-v4-mapped external address.

**NAT-PMP** ([RFC 6886][rfc6886], UDP port 5351, version 0). External-address request is 2 bytes `[0, 0]`; a mapping request is 12 bytes `[0, opcode(UDP=1,TCP=2), 0, 0, internal_port BE, suggested_external_port BE, lifetime u32 BE]`. Responses OR the opcode with `RESPONSE_INDICATOR = 1<<7`: the public-address response is 12 bytes `(ver, opcode, result u16, epoch u32, IPv4)`, the mapping response 16 bytes `(ver, opcode, result u16, epoch u32, private u16, public u16, lifetime u32)`. Obtaining a mapping is a **two-request dance**: MAP, then DetermineExternalAddress.

**UPnP.** SSDP M-SEARCH multicast to `239.255.255.250:1900` + SOAP `WANIPConnection` actions (`AddPortMapping`/`AddAnyPortMapping`/`DeletePortMapping`/`GetExternalIPAddress`), entirely inside the [`igd-next`][igd] crate — the single biggest reimplementation chunk for a port.

**Linux netlink / BSD routing / `/proc` formats** are described under [netwatch](#netwatch-interface-state--change-monitoring). The BSD RIB parser hardcodes per-OS struct offsets from Go `x/net` `zsys` files (e.g. Darwin `SIZEOF_RT_MSGHDR_DARWIN15 = 0x5c`, `if_msghdr2 = 0xa0`, kernel alignment 4, [`interfaces/bsd/macos.rs`][nw-bsd-macos]).

### Cryptography & identity

Near-absent — and the absence is a finding. `net_report` performs **no** cryptography of its own: QAD packet protection is [`noq`][quic]'s TLS/QUIC, and the HTTPS probe uses a stock `rustls::ClientConfig`. There is **no** DISCO shared secret, **no** STUN transaction ID, and **no** ICMP identifier — the 0.x side-channel handshakes are gone. The only identity-shaped values are: the captive-portal challenge token `ts_{host}` (an unauthenticated liveness nonce, not a secret) and the PCP mapping _nonce_ (a 12-byte anti-spoofing value the client echoes-checks — the closest thing to a security primitive here). Reachability decisions are keyed on [`EndpointId`][identity] and `RelayUrl` at the layers above; this subsystem carries neither key material nor MACs. A port must not look for a crypto handshake in the probe path — there is none.

### State machines & lifecycle

Eleven small state machines cooperate; the load-bearing ones for a port:

1. **Full-vs-incremental cycle** ([`net_report.rs:303`][nr-full]): `do_full = is_major ∨ next_full ∨ (now − last_full > 5 min) ∨ (last.captive_portal ∧ ¬last.has_udp())`. Entering full clears `reports.last` (⇒ initial `ProbePlan`) and the QAD cache, sets `last_full = now`.
2. **QAD fan-out** ([`net_report.rs:493`][nr-fanout]): per family `Idle → (needs probe ∧ family available) → ≤5 tasks → first success caches the conn, losers closed → exit when reports ≥ enough_relays ∧ ¬pending (cancel family tokens) or shutdown`; per-task 3 s timeout.
3. **`reportgen` actor** (one-shot): `Start → spawn plan tasks + delayed captive-portal task → forward each ProbeFinished → when all regular probes done ∧ any was UDP, cancel captive portal → exit on JoinSet drain / 5 s overall timeout / parent drops handle`.
4. **DirectAddrUpdateState**: invariant "only one update at a time"; `{idle, running, running+queued}`; `schedule_run` `try_lock` → running or queued (`want_update`, later reasons overwrite); `run_done` drains the queued reason.
5. **netmon debounce** ([`actor.rs:93`][nm-actor]): `{quiet, pending}`; any event/hint arms a 250 ms reset-able sleep; on fire rebuild `State`, publish if changed; a wall-clock jump > 22.5 s forces a publish with `last_unsuspend`.
6. **Route-monitor reconnect** loops: Linux netlink 1 s→30 s, BSD `AF_ROUTE` 50 ms→30 s doubling backoff.
7. **`UdpSocket` break/rebind** ([`udp.rs`][udp]): `{healthy, broken, closed}`; read `NotConnected` / write `BrokenPipe` ⇒ broken; next op runs `maybe_rebind` (double-check under write lock) ⇒ healthy (same port) or stays broken.
8. **Portmapper lease** ([`current_mapping.rs:122`][pm-current]): `Empty →(mapping)→ Active(deadline ½·lifetime) →(deadline, emit Renew)→ Renewing(deadline ½·lifetime, expire_after) →(new mapping)→ Active | →(deadline, emit Expired, clear watch)→ Empty`.
9. **Portmapper probe trust** ([`lib.rs:40`][pm-trust]): per protocol `{fresh (<10 min), stale}`; probe requests short-circuit if all three fresh; blind mapping only if last probe > 5 s old.

### Dependencies & coupling

| Crate                                                          | Depth                    | What a D port inherits                                                                                                                                                                                                                                                                                                                              |
| -------------------------------------------------------------- | ------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`noq`/`noq-proto`/`noq-udp`][quic]                            | **load-bearing**         | QAD is a QUIC transport extension — `observed_external_addr()`, `rtt(PathId)`, the `Role` transport parameter, `OBSERVED_ADDRESS` frames. No separate probe protocol exists; the port's QUIC stack must implement [draft-seemann-quic-address-discovery][qad-draft]. `noq_udp` supplies GSO/GRO/segmented `sendmsg`/`recvmsg`, `may_fragment`, ECN. |
| `netdev`                                                       | **load-bearing**         | _all_ interface enumeration (names, indices, flags, MACs, v4/v6 nets, v6 scope-ids + address flags, gateway discovery). A port reimplements per-OS: `getifaddrs`+`/proc` (Linux), `getifaddrs`+`sysctl` (BSD/macOS), `GetAdaptersAddresses` (Windows).                                                                                              |
| `netlink-packet-*`, `netlink-proto`, `netlink-sys`             | **load-bearing** (Linux) | route-monitor multicast groups + default-route dump. Port: raw `AF_NETLINK` socket + a small `RTM_*` subset.                                                                                                                                                                                                                                        |
| `windows` (Win32 IP Helper) + `wmi`                            | **load-bearing** (Win)   | `NotifyUnicastIpAddressChange`/`NotifyRouteChange2`/`CancelMibChangeNotify2`; WMI `Win32_IP4RouteTable` for the default route (replaceable by `GetBestRoute2`/`GetIpForwardTable2` to avoid COM).                                                                                                                                                   |
| [`igd-next`][igd]                                              | **load-bearing**         | the full UPnP IGD client (SSDP M-SEARCH, device-description fetch, SOAP). Biggest single reimplementation chunk in `portmapper`.                                                                                                                                                                                                                    |
| `reqwest` + `rustls` + `hickory` (via [`iroh-dns`][discovery]) | mixed                    | HTTPS probe & captive portal — trivial HTTP GETs over TLS, but with custom DNS (`resolve_to_addrs`) and redirects disabled. Port supplies its own HTTP client + staggered DNS.                                                                                                                                                                      |
| `n0-watcher` (`Watchable`/`Watcher`)                           | API-surface              | value-latest watch cells with async `updated()`; used for reports, QAD observers, netmon state, portmap addr. **No event-horizon equivalent** (see Mapping).                                                                                                                                                                                        |
| `n0-future` (`AbortOnDropHandle`, `MaybeFuture`, time)         | API-surface              | structured-cancellation glue → `Scope`-owned fibers.                                                                                                                                                                                                                                                                                                |
| `tokio-util` `CancellationToken` (+ child tokens)              | API-surface              | → `CancelContext` tree.                                                                                                                                                                                                                                                                                                                             |
| `socket2`                                                      | API-surface              | raw socket options (buffer sizes, `IPV6_V6ONLY`, nonblocking, the `AF_ROUTE` raw socket).                                                                                                                                                                                                                                                           |

PCP and NAT-PMP codecs are **in-tree** and directly portable from the byte layouts above; only UPnP is a heavy external dependency. The full concurrency inventory is enumerated in [`concurrency`][concurrency].

### Concurrency & I/O model

The subsystem is a **web of tokio actors and watch channels** — the recon counted **26 distinct concurrency primitives** across `net_report`, `netwatch`, and `portmapper` (all in [`concurrency`][concurrency]). The shape: `net_report::Client` is a plain `&mut self` struct driven by one async `get_report`, serialized by `Arc<AsyncMutex<…>> + try_lock_owned` (the lock _is_ the "already running" flag); the `reportgen` actor is a one-shot `AbortOnDropHandle` task; QAD fan-out uses two `JoinSet`s (v4/v6) with per-family child `CancellationToken`s; results flow over an `mpsc(32) ProbeFinished` and are merged with live QAD watchers in a biased `select!`. `netmon` is one actor owning a `Watchable<State>` fed by an OS `RouteMonitor` (netlink task / `AF_ROUTE` reader / Windows foreign-thread callbacks) through an mpsc(16) into a 250 ms debouncer. `UdpSocket` uses `RwLock<SocketState>` + two `AtomicWaker`s + an `AtomicBool` to swap an fd under concurrent pollers. `portmapper` is one `Service` actor with an mpsc(32), a `watch<Option<SocketAddrV4>>`, one in-flight `mapping_task` and one `probing_task` (each `AbortOnDropHandle`), and `CurrentMapping` implemented as a `Stream` with a stored `Waker` + boxed `time::Sleep`.

The critical observation for a port: **almost none of this needs true parallelism**. The `Arc`/`AsyncMutex`/`RwLock`/atomics/`JoinSet` machinery exists because tokio is multi-thread and `Send + Sync`, not because the algorithm is concurrent. The two genuinely cross-thread facts are (a) Windows `Notify*Change2` callbacks arriving on OS threads iroh does not own, and (b) `spawn_blocking` for `libc::close` and the WMI COM query — both artifacts of blocking APIs, not of the design.

### Mapping to event-horizon

This is a rich translation target: much of the concurrency dissolves under [event-horizon][eh-spec]'s `single` topology (one loop, one thread, [fibers][eh-spec] + [algebraic effects][algeff]), but three things demand _new_ design — cross-fiber watch/notify (open-issue O20), `sendmsg`/`recvmsg` for GSO/GRO (O19), and the platform route-monitor bindings.

**1. The two-actor report shape collapses.** `net_report::Client` is already `&mut self`; the `reportgen` actor is a one-shot fiber whose handle-drop-cancels maps to a child [`Scope`][eh-spec] under [`withDeadline`][eh-spec]`(5.seconds)` — Scope exit cancels the probe fibers. The `Arc<AsyncMutex<Client>> + try_lock_owned` trick degenerates, single-threaded, to a plain `bool running` + `Nullable!UpdateReason wantUpdate` on the socket fiber — no lock. The `mpsc(32) ProbeFinished` is the one real channel; on the same thread it becomes a direct method call on a `Report` accumulator plus a wake (contingent on O20), or a bounded SPSC queue owned by the report fiber:

```rust
// Rust: iroh/src/net_report/report.rs:18 — a serde-serializable value handed back over a channel
pub struct Report {
    pub udp_v4: bool,
    pub udp_v6: bool,
    pub mapping_varies_by_dest_ipv4: Option<bool>,
    pub mapping_varies_by_dest_ipv6: Option<bool>,
    pub preferred_relay: Option<RelayUrl>,
    pub relay_latency: RelayLatencies,
    pub global_v4: Option<SocketAddrV4>,
    pub global_v6: Option<SocketAddrV6>,
    pub captive_portal: Option<bool>,
}
```

```d
// D (proposed / sketch): a plain accumulator the probe fibers mutate directly on the
// report fiber's own thread — no serde round-trip, no channel to hand it back.
struct Report {
    bool udpV4, udpV6;
    Nullable!bool mappingVariesByDestV4, mappingVariesByDestV6;   // 3-state: unknown / false / true
    Nullable!RelayUrl preferredRelay;
    RelayLatencies relayLatency;                                  // 3 sorted maps, min-latency per relay
    Nullable!SocketAddrV4 globalV4;
    Nullable!SocketAddrV6 globalV6;
    Nullable!bool captivePortal;

    // called by each probe fiber; symmetric-NAT detection folds in here
    void update(in QadProbeReport r) @safe nothrow { /* set global_v*, compare, set mappingVaries */ }
}
```

**2. QAD fan-out = a scope with race-to-quorum.** Spawn ≤5 fibers per family in a child scope, each `withDeadline(3.seconds)`; the collector parks on the next completion and cancels the scope once quorum (`enough_relays` + per-family flag) is met. The per-family `CancellationToken` hierarchy is exactly a [`CancelContext`][eh-spec] subtree:

```rust
// Rust: iroh/src/net_report.rs:493 — JoinSet + per-family CancellationToken, early-cancel on quorum
let mut v4_buf = JoinSet::new();
// ... spawn ≤ MAX_RELAYS tasks, each timed out at PROBES_TIMEOUT ...
while let Some(res) = buf.join_next().await {
    if reports.len() >= enough_relays && !pending { family_token.cancel(); break; }
}
```

```d
// D (proposed / sketch): a per-family CancelContext subtree; forked fibers; quorum cancels.
Outcome!void probeFamilyQad(ref Scope sc, Family fam, ref Report acc) {
    auto famCtx = sc.childContext();                              // per-family CancelContext
    JoinHandle!QadProbeReport[MAX_RELAYS] hs;  size_t n;
    foreach (relay; relaysNeedingProbe(fam).take(MAX_RELAYS))
        hs[n++] = sc.fork(() => withDeadline(3.seconds, () => qadProbe(relay, fam)));
    size_t landed;
    while (landed < n) {
        auto r = raceNext(hs[0 .. n]);                            // next completion; ties by fork order
        if (r.hasValue) { acc.update(r.value); ++landed; }
        if (acc.enoughRelays && !acc.pending(fam)) { famCtx.cancel(); break; }
    }
    return ok();
}
```

**3. Watchables are the one real gap.** Five of them live here — the report handoff `Watchable<(Option<Report>, UpdateReason)>`, each cached QAD conn's `Watchable<Option<QadProbeReport>>`, `netmon`'s `Watchable<State>`, and portmapper's `watch<Option<SocketAddrV4>>`. Event-horizon has no watch primitive (the [brief][eh-spec] flags `tokio::sync::watch` as [open-issue O20][eh-spec]). Minimal D design: a `Watchable!T` = `{ value, ulong version, waiterList }`; `updated()` parks the calling fiber until `version` changes. Single-threaded means no lock, but the cross-fiber wake still needs the missing notify primitive. This subsystem alone justifies building it once.

**4. The portmapper lease timer is a plain fiber.** Rust models it as a `Stream` with a stored `Waker` and a boxed `time::Sleep` because it must integrate with a poll loop; on event-horizon it is one fiber sleeping on in-ring `TIMEOUT` ops keyed to [`MonoTime`][eh-spec]:

```rust
// Rust: portmapper/src/current_mapping.rs:122 — a Stream emitting Renew at ½·lifetime, then Expired
pub enum Event { Renew { external_ip: Ipv4Addr, external_port: NonZeroU16 }, Expired { /* .. */ } }
// impl Stream for CurrentMapping { ... boxed time::Sleep + stored Waker ... }
```

```d
// D (proposed / sketch): a single lease fiber; sleeps are cancellable via the enclosing scope.
Outcome!void leaseLoop(ref Scope sc, Mapping m) {
    for (;;) {
        sc.sleep(m.lifetime / 2);              // in-ring TIMEOUT (MonoTime); cancel = scope cancel
        if (!renewMapping(m.external))          // ask for the same external addr/port
            { expireMapping(m); return ok(); }
        sc.sleep(m.lifetime / 2);
    }
}
```

**5. Timers everywhere → in-ring `TIMEOUT`.** The 250 ms netmon debounce (reset-able), the 20–26 s randomized re-report interval, the 15 s wall-clock poll, the 3 s/5 s probe/report budgets, and the ½-lifetime lease sleeps are all in-ring `TIMEOUT` ops. The wall-clock _jump_ detector compares monotonic `Instant` deltas against the poll interval; [`MonoTime`][eh-spec] preserves the semantics exactly — a monotonic clock freezes during suspend on Linux, which is _why_ a 1.5× jump means "we just woke up."

**6. Route monitors are the platform-specific hard part** — and each maps cleanly onto a completion-first backend:

- **Linux netlink** is just an fd: an io*uring multishot `recv` fits perfectly; parse `RTM*\*` messages in the completion path. See the [io_uring surface][io-uring].
- **macOS `AF_ROUTE`** under the [kqueue backend][async-io]: the Rust "drain until `WouldBlock` because edge-triggered" rule is exactly event-horizon's _readiness-synthesized-into-completions_ discipline — keep reading after a completion until `EAGAIN`.
- **Windows `Notify*Change2`** callbacks run on **foreign OS threads**; the only legal cross-thread entry is [`Waker.wake()`][eh-spec] / MSG_RING (per the brief), so a callback must enqueue into a lock-free cell and wake — precisely what the Rust code does with `try_send`.
- The WMI `spawn_blocking` default-route query has **no equivalent** (no thread pool); a port should prefer `GetBestRoute2`/`GetIpForwardTable2` (plain, non-blocking Win32) over WMI/COM.
- `spawn_blocking(libc::close)` for the UDP fd is replaced by `IORING_OP_CLOSE` — strictly better, no thread hop.

**7. `UdpSocket` rebind, single-threaded.** The `RwLock` + two `AtomicWaker`s exist to swap an fd under concurrent pollers. Single-threaded this becomes: mark broken → `ASYNC_CANCEL` in-flight ops on that fd → close/rebind (same port) → resubmit. The transient-read-error policy (swallow `ECONNRESET` everywhere, `WSAENETRESET` on Windows) must be preserved **verbatim** — it is a QUIC-security requirement, not a convenience.

**8. GSO/GRO waits on O19; blocking reads stay synchronous.** `poll_send_noq`/`poll_recv_noq` need `sendmsg`/`recvmsg` with `UDP_SEGMENT`/`UDP_GRO`/PKTINFO/ECN cmsgs — event-horizon [open-issue O19][eh-spec]. `net_report` itself only needs plain send/recv (portmapper datagrams; QAD rides the main QUIC path). The blocking `sysctl`/`/proc/net/route` reads are fast and can stay synchronous on the loop thread; `/proc/net/route` must be one large read (gVisor), which an io_uring `read` handles naturally.

**Cadence knobs to keep identical:** 5 min full-report interval, 5 s report budget, 3 s probe budget, 200/300/400 ms HTTPS ladder, 200 ms captive delay, 20–26 s re-report, 250 ms netmon debounce, 10 min / 5 s portmap trust windows, ½-lifetime renewal.

---

## Strengths

- **One probe transport.** QAD reuses the main [`noq`][quic] endpoint, so the discovered public address is measured on the same socket the data uses — no probe-vs-data mapping skew — and there is no separate STUN/ICMP attack surface or side-protocol to secure.
- **Fail-soft by construction.** Every probe is racing, cancellable, and timeout-bounded (3 s probe, 5 s report, 10 s outer); an unreachable relay or blocked family degrades the report rather than hanging it.
- **Cheap incremental reports.** Long-lived QAD connections turn most reports into passive observation of a live NAT-refreshing connection — no re-dial, and the 25 s keep-alive doubles as a binding refresher.
- **Symmetric-NAT detection falls out for free** from probing ≥2 relays per family and comparing observed addresses — no extra round trips.
- **Sensible home-relay hysteresis** (challenger must beat ⅔ of the incumbent's latency) prevents flapping between near-equal relays.
- **Clean per-OS route-monitor abstraction** with an honest edge-triggered-drain contract and reconnect backoff — a solid template for a port.

## Weaknesses

- **QAD ties sensing to a bespoke QUIC fork.** A port cannot sense the network without first implementing [draft-seemann-quic-address-discovery][qad-draft] inside its QUIC stack — there is no standalone probe protocol to lean on.
- **Watch-channel-heavy.** Five `Watchable`s with no completion-first analogue; a faithful port must build a watch/notify primitive ([O20][eh-spec]) before this subsystem runs.
- **Incremental reports may run zero probes.** `ProbePlan::with_last_report` returns an empty plan (`// TODO: is this good?`), leaning entirely on cached QAD watchers — a stale cached conn can report UDP works for up to ~35 s after the network actually broke (an open question the recon could not fully resolve from `net_report` alone).
- **Platform-binding breadth.** netlink, `AF_ROUTE`, `sysctl(NET_RT_DUMP2)`, `/proc/net/route`, Win32 IP Helper + WMI, `getifaddrs`, plus PCP/NAT-PMP codecs and a full UPnP IGD client — a large, OS-specific surface to reimplement.
- **Known defects/asymmetries.** The PCP lifetime constant contradicts its comment (3600 s vs "2 hours"); `State::is_expensive` is declared and compared in `is_major_change` but never populated; Windows uses WMI/COM for the default route while using IP Helper for change notifications; the captive-portal check always passes `preferred_relay = None` (the relay is chosen at random). A port should fix, not copy, these.
- **`spawn_blocking` leaks in** (`libc::close`, WMI) — small, but with no thread-pool analogue on event-horizon they force per-site redesign.

## Key design decisions and trade-offs

| Decision                                                                 | Rationale                                                                                            | Trade-off                                                                                                        |
| ------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| QAD over the main endpoint instead of STUN/ICMP                          | Probe socket = data socket ⇒ the observed address is a valid direct-addr candidate; no side-protocol | Sensing depends on a QUIC extension in [`noq`][quic]; no probing before a QUIC stack exists                      |
| Keep QAD connections alive between reports (25 s keep-alive, 35 s idle)  | Incremental reports become passive observation; keep-alive refreshes the NAT binding                 | A dead network can be masked until the cached conn's close-reason lands (~35 s window)                           |
| `ProbePlan` schedules only HTTPS; QAD fans out separately (≤5 relays)    | QAD has no retransmit-ladder semantics; HTTPS is a pure fallback for QUIC-blocked networks           | Two scheduling paths with different limits; the elaborate 0.x STUN-ladder plan shrank to "3 HTTPS tries or none" |
| `Arc<AsyncMutex<Client>> + try_lock_owned` as the "already running" flag | Encodes the single-report invariant without a queue                                                  | Concurrency-as-state-machine; opaque to read; pure overhead single-threaded (becomes a `bool`)                   |
| Symmetric NAT = compare observed addrs across relays                     | Free with multi-relay probing; no extra round trips                                                  | Needs ≥2 successful observations per family; single-relay networks can't detect it                               |
| Home-relay hysteresis (beat ⅔ of incumbent latency)                      | Avoids flapping between near-equal relays                                                            | A genuinely-better-but-marginal relay is ignored until it wins by a third                                        |
| Swallow `ECONNRESET` on every platform in the UDP recv path              | ECONNRESET is undefined in QUIC and attacker-injectable; must never tear down recv                   | Hides genuine unreachable-destination signals; a security requirement, not a convenience                         |
| Per-OS native route monitors (netlink / `AF_ROUTE` / IP Helper)          | Push-based link-change detection is far cheaper than polling                                         | A large, fiddly, OS-specific binding surface (edge-triggered drain, foreign-thread callbacks, COM avoidance)     |
| Prefer PCP → NAT-PMP → UPnP, with cached trust windows                   | PCP/NAT-PMP are cleaner in-tree codecs; UPnP is unreliable-but-ubiquitous                            | Three protocols to maintain; UPnP drags in a heavy SSDP/SOAP dependency                                          |

---

## Sources

Primary sources — the pinned iroh `net_report` module and `portmapper` wrapper (`iroh` v1.0.1, commit `22cac742ca`), and the `netwatch` / `portmapper` crates (net-tools commit `051ab876` = `netwatch-v0.19.1` / `portmapper-v0.19.1`):

- [`iroh/src/net_report.rs`][nr-doc] — `Client`, QAD conn cache, full-vs-incremental cycle, `get_report`, preferred-relay history/hysteresis.
- [`iroh/src/net_report/reportgen.rs`][reportgen] — the one-shot reportgen actor, HTTPS probe, captive-portal check, `QadProbeReport`, `QuicConfig`.
- [`iroh/src/net_report/probes.rs`][probes] — the three-variant `Probe` enum, `ProbeSet`, `ProbePlan` (HTTPS-only).
- [`iroh/src/net_report/report.rs`][report] — `Report`, `RelayLatencies`, symmetric-NAT detection.
- [`iroh/src/net_report/{options.rs,defaults.rs,metrics.rs}`][options] — protocol-set derivation, all timeouts, counters.
- [`iroh-relay/src/quic.rs`][qad-rtt], [`iroh-relay/src/defaults.rs`][qad-port], [`iroh-relay/src/http.rs`][relay-http] — the QAD client/server config, ALPN `/iroh-qad/0`, port 7842, HTTPS probe path.
- [`iroh/src/socket.rs`][sk-dau] and [`iroh/src/portmapper.rs`][iroh-portmapper] — `DirectAddrUpdateState`, `UpdateReason`, re-report interval, `handle_net_report_report`, `update_direct_addresses`, the `Enabled`/`Disabled` portmapper wrapper.
- [`netwatch/src/interfaces.rs`][nw-interfaces] + [`interfaces/{linux,bsd,bsd/macos,windows}.rs`][nw-linux-route] — `State`, `is_major_change`, default-route detection, `HomeRouter`, the BSD RIB parser.
- [`netwatch/src/netmon/{actor.rs,linux.rs,bsd.rs,windows.rs,android.rs}`][nm-actor] — the debouncer and per-OS route monitors.
- [`netwatch/src/udp.rs`][udp] — the rebindable `UdpSocket`, GSO/GRO delegation, transient-error policy.
- [`portmapper/src/{lib.rs,current_mapping.rs,mapping.rs,pcp.rs,nat_pmp.rs,upnp.rs}`][pm-lib] + `pcp/protocol/*`, `nat_pmp/protocol/*` — the Service actor, probe trust, mapping strategy, lease renewal, and the PCP/NAT-PMP byte codecs.

Related pages: [the multipath socket][socket] (which consumes the report — home-relay + direct-addr candidates), [NAT traversal & address discovery][nat] (symmetric-NAT flag + QAD frames), [the relay protocol][relay] (home-relay selection + QUIC-address-discovery listener), [address lookup][discovery] (staggered DNS + where direct addresses are republished), [QUIC transport (`noq`)][quic] (QAD/`OBSERVED_ADDRESS` framing), [concepts & vocabulary][concepts], [identity & cryptography][identity], [wire formats & serialization][wire], [the concurrency inventory][concurrency] (all 26 primitives), and [D architecture migration][d-migration]. Runtime target: the [event-horizon spec][eh-spec] (`Scope`, `CancelContext`, `Watchable` gap O20, msghdr gap O19); I/O surface in the [async-io survey][async-io] and [io_uring deep-dive][io-uring]; concurrency-model contrast in [tokio][tokio].

<!-- References -->

[repo]: https://github.com/n0-computer/iroh/tree/22cac742ca
[docs]: https://docs.rs/iroh/1.0.1/iroh/
[nettools]: https://github.com/n0-computer/net-tools/tree/051ab876
[docs-netwatch]: https://docs.rs/netwatch/0.19.1/netwatch/
[docs-portmapper]: https://docs.rs/portmapper/0.19.1/portmapper/
[nr-doc]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report.rs#L3
[nr-https]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report.rs#L88
[nr-qadconns]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report.rs#L157
[nr-fanout]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report.rs#L493
[nr-full]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report.rs#L303
[nr-preferred]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report.rs#L747
[reportgen]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/reportgen.rs#L206
[reportgen-captive]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/reportgen.rs#L619
[qad-report]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/reportgen.rs#L447
[probes]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/probes.rs#L25
[probes-set]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/probes.rs#L38
[report]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/report.rs#L18
[report-latencies]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/report.rs#L136
[report-mapvaries]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/report.rs#L88
[options]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/options.rs#L49
[defaults]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/net_report/defaults.rs#L17
[qad-alpn]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/quic.rs#L10
[qad-rtt]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/quic.rs#L283
[qad-server]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/quic.rs#L102
[qad-port]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/defaults.rs#L7
[relay-http]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh-relay/src/http.rs#L15
[sk-dau]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L706
[sk-reason]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L719
[sk-restun]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L2004
[sk-handle]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1554
[sk-uda]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1814
[sk-qad4]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1841
[sk-ep]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket.rs#L1046
[sk-nettimeout]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/defaults.rs#L129
[sk-homerelay]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/socket/transports/relay/actor.rs#L1124
[iroh-portmapper]: https://github.com/n0-computer/iroh/blob/22cac742ca5e84da4542681e14b2d23b74c8330e/iroh/src/portmapper.rs#L69
[nw-interfaces]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/interfaces.rs#L200
[nw-ismajor]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/interfaces.rs#L319
[nw-defroute]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/interfaces.rs#L411
[nw-linux-route]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/interfaces/linux.rs#L62
[nw-bsd-route]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/interfaces/bsd.rs#L73
[nw-win-route]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/interfaces/windows.rs#L29
[nw-bsd-macos]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/interfaces/bsd/macos.rs#L4
[nm-actor]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/netmon/actor.rs#L93
[nm-linux]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/netmon/linux.rs#L61
[nm-bsd]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/netmon/bsd.rs#L95
[nm-windows]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/netmon/windows.rs#L32
[nm-android]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/netmon/android.rs#L16
[udp]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/udp.rs#L20
[udp-buf]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/udp.rs#L28
[udp-transient]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/udp.rs#L518
[udp-rebind]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/udp.rs#L281
[udp-gso]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/udp.rs#L332
[udp-close]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/netwatch/src/udp.rs#L192
[pm-lib]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/portmapper/src/lib.rs#L434
[pm-trust]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/portmapper/src/lib.rs#L40
[pm-strategy]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/portmapper/src/lib.rs#L632
[pm-probe]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/portmapper/src/lib.rs#L280
[pm-current]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/portmapper/src/current_mapping.rs#L122
[pm-pcp]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/portmapper/src/pcp.rs#L14
[pm-natpmp]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/portmapper/src/nat_pmp.rs#L16
[pm-upnp]: https://github.com/n0-computer/net-tools/blob/051ab8761006d7f2155e34a49f6bb881b582d5ab/portmapper/src/upnp.rs#L19
[socket]: ./socket.md
[nat]: ./nat-traversal.md
[relay]: ./relay.md
[discovery]: ./discovery.md
[quic]: ./quic-transport.md
[identity]: ./identity-crypto.md
[wire]: ./wire-serialization.md
[concurrency]: ./concurrency.md
[d-migration]: ./d-architecture-migration.md
[concepts]: ./concepts.md
[index]: ./index.md
[eh-spec]: ../../specs/event-horizon/SPEC.md
[algeff]: ../algebraic-effects/index.md
[async-io]: ../async-io/index.md
[io-uring]: ../async-io/io-uring/index.md
[tokio]: ../async-io/tokio.md
[qad-draft]: https://datatracker.ietf.org/doc/draft-seemann-quic-address-discovery/
[rfc6887]: https://www.rfc-editor.org/rfc/rfc6887
[rfc6886]: https://www.rfc-editor.org/rfc/rfc6886
[igd]: https://docs.rs/igd-next/
[tailscale-netcheck]: https://github.com/tailscale/tailscale/blob/6ee7bcb4583575f8b2623bc16d55f92737465217/net/netcheck/netcheck.go
