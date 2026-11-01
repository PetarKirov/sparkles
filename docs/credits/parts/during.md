### during

| Field          | Value                                |
| -------------- | ------------------------------------ |
| Version source | flake input `during-src`             |
| Licence        | `BSL-1.0`                            |
| Home           | https://github.com/tchaloupka/during |
| Ships as       | `sparkles:event-horizon-sys`         |

Tomáš Chaloupka's D binding to Linux `io_uring`. `sparkles:event-horizon`'s
default backend on Linux is built on it, so on the desktop the terminal's pty
reads and hue's file and process I/O complete through it. Android builds leave
it out. Vendored into `sparkles:event-horizon-sys` as
`sparkles.event_horizon.sys.uring`; its header names the upstream revision and
what Sparkles changed.

::: details Licence text

```text
<!-- @include: ../licenses/during/LICENSE -->
```

:::
