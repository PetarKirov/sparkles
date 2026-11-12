### sendme and iroh

| Field          | Value                                                              |
| -------------- | ------------------------------------------------------------------ |
| Version source | nixpkgs `sendme`                                                   |
| Licence        | `MIT OR Apache-2.0`                                                |
| Home           | https://www.iroh.computer                                          |
| Ships as       | `sparkles:iroh-send`, which opens libsparkles_iroh_send.so to send |

n0's `sendme` and the iroh libraries it is built on: QUIC connections between
two machines found by their keys, through relays and hole-punching, and
iroh-blobs' verified transfer of content-addressed files. The fileset
explorer's Send is `sendme send` built as a library inside `sendme`'s own
source tree (`sparkles:iroh-send`), so it carries every crate `sendme` locks,
iroh, iroh-blobs and tokio among them, each under its own licence, nearly
all `MIT OR Apache-2.0`; the list is `sendme`'s `Cargo.lock`. The texts below
are `sendme`'s.

::: details Licence texts

```text
<!-- @include: ../licenses/sendme/LICENSE-MIT -->
```

```text
<!-- @include: ../licenses/sendme/LICENSE-APACHE -->
```

:::
