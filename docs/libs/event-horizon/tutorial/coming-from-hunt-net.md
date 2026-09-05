# Coming from hunt-net

Hunt-net's [README examples][hunt] configure a server or client, install a
`TextLineCodec`, and handle decoded messages through
`AbstractNetConnectionHandler.messageReceived`. Event Horizon exposes the stream
and scope primitives below that framework level.

This comparison uses revision `81fd38deebe6a5ec093ef9e86770cd0dce22b355`.
It is a source-based migration guide, not a claim of feature or performance parity.

## Keep the codec boundary explicit

| hunt-net idiom                          | Event Horizon approach                     | Important difference                                          |
| --------------------------------------- | ------------------------------------------ | ------------------------------------------------------------- |
| `NetUtil.createNetServer` and `.listen` | `env.net.listen`, then `accept`            | Give each accepted connection an owning scope or child fiber. |
| `TextLineCodec`                         | An incremental decoder over received bytes | TCP can split or combine application messages.                |
| `messageReceived`                       | Resume the waiting receive fiber           | Local variables can hold per-connection parser state.         |
| `connection.write`                      | `send(move(buf))`                          | Loop over partial sends; do not reuse an in-flight buffer.    |
| Server/client lifecycle callbacks       | Scope lifetime and explicit close          | Cancellation and cleanup need a deliberate policy.            |

The process supervisor's `LineFramer` contract does not make every socket a line
stream. Decide whether to reuse a compatible framing primitive or retain your
existing protocol codec when porting a service.

## Try a byte-stream echo

This example is smaller than a framework-based server because it handles one
loopback connection. It is not a replacement for hunt-net's codec, connection
management, or protocol facilities.

<<< @/libs/event-horizon/tutorial/snippets/eh_tcp_echo.d [event-horizon]

```ansi
echoed: hello
```

## Bound work between stages

If your handler previously enqueued decoded messages without a limit, decide how
to bound that queue. `Channel!(int, 2)` below parks a producer when full. It is
local to one scheduler; it is not a cross-thread replacement for every framework
queue.

<<< @/libs/event-horizon/tutorial/snippets/eh_channel.d [event-horizon]

```ansi
consumed: 15
```

Both programs and their prerequisites are described in
[Running the examples](./running-examples.md). Use that guide's error and
deadline sections before adapting these patterns to a long-lived server.

<!-- References -->

[hunt]: https://github.com/huntlabs/hunt-net/blob/81fd38deebe6a5ec093ef9e86770cd0dce22b355/README.md
