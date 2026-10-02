### libkqueue

| Field          | Value                                          |
| -------------- | ---------------------------------------------- |
| Version source | nixpkgs `libkqueue`                            |
| Licence        | `BSD-2-Clause`                                 |
| Home           | https://github.com/mheily/libkqueue            |
| Ships as       | `libkqueue.a` in the APKs; `-lkqueue` on Linux |

The BSD `kqueue` interface over `epoll`. `sparkles:event-horizon`, the event
loop under both applications, has a kqueue backend; on Android, whose app
sandbox refuses `io_uring`, that backend runs on libkqueue. Its `libkqueue`
configuration links the same library on Linux, so CI tests the Android
backend on an ordinary host.

::: details Licence text

```text
<!-- @include: ../licenses/libkqueue/LICENSE -->
```

:::
