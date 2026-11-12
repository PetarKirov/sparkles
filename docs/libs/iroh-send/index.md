# sparkles:iroh-send

Sending files to another machine the way iroh's
[`sendme`](https://github.com/n0-computer/sendme) does: the files are served
over iroh's blobs protocol, and a receiver runs `sendme receive <ticket>`
and gets each one, verified as it arrives, under its name.

The sending is iroh's own code. `libsparkles_iroh_send.so` is built from the
Rust in `libs/iroh-send/rust`, inside `sendme` 0.37's source tree and against
its `Cargo.lock` (`nix build .#sparkles-iroh-send`), and this library opens it
at run time with `dlopen`. Nothing links it: a program that uses it builds
without a Rust toolchain, and runs without the library, reporting why
sending is unavailable. The fileset explorer's Send is built on it
([`FXS`](../../specs/fileset-explorer/SPEC.md#_7-names-and-sending-fxs),
[X18](../../specs/fileset-explorer/decisions.md)).

```d
import core.thread : Thread;
import core.time : msecs;
import std.stdio : writeln;

import sparkles.iroh_send;

void send(SendFile[] files)
{
    auto lib = loadIrohSend(); // `$SPARKLES_IROH_SEND_LIB`, or the bare name
    if (lib.hasError)
        return writeln("cannot send: ", lib.error);
    auto session = lib.value.start(files);
    scope (exit) session.stop();
    SendState st;
    do
    {
        Thread.sleep(100.msecs);
        st = session.poll();
    }
    while (st.phase < SendPhase.serving);
    if (st.phase == SendPhase.failed)
        return writeln("failed: ", st.error);
    writeln("sendme receive ", st.ticket);
    // ... serve until the user stops it
}
```

## What is sent

Each `SendFile` is a name and a path. The names are the collection's, as
`sendme send dir` names a directory's files: `dir/a`, `dir/sub/b`, with `/`
between components. The files are imported into a store the library keeps
in a temporary directory, by reference where the file system allows, and
named as `sendme` names them, so the ticket's hash is the collection the
content-addressing library computes for the same files
([`CAI1`](../../specs/build-primitives/content-addressing/SPEC.md#_8-iroh-s-collection-cai)).
`IrohSend.collection` computes that name with no network.

## A session

`IrohSend.start` returns at once: the import, the endpoint and the serving
run on the library's own threads. `SendSession.poll` reads where it is:

| `SendPhase` | Meaning                                                              |
| ----------- | -------------------------------------------------------------------- |
| `importing` | hashing the files into the store; `filesDone` of `filesTotal`        |
| `online`    | the collection is named (`hash`); finding the endpoint's addresses   |
| `serving`   | `ticket` is ready; `peers`, `requests` and `bytesSent` count fetches |
| `failed`    | `error` says why                                                     |
| `stopped`   | `stop` ended it                                                      |

A new key is made for every session, so a ticket stops working when its
session stops. `stop` ends the session, removes its store and frees it.
With `noRelay`, the ticket carries direct addresses only, which is how the
tests send and receive on one machine without a network.

## On Android

`nix/packages/android/iroh-send.nix` builds the same library for each ABI
an APK ships. Before its first `start`, an Android app calls
`installAndroidContext` with its `JavaVM` and a global reference to its
application `Context`. iroh reads the system's DNS servers through JNI, and
without them its fallback relies on unwinding, which the build's
`panic = "abort"` turns into an abort of the whole app. The fileset
explorer does this in `installJniContext` (`android_entry.d`). The app also
needs the `INTERNET` permission, and `ACCESS_NETWORK_STATE` for the
network watcher.

## Testing

`dub test :iroh-send` runs against the library and `sendme` the dev shell
names (`$SPARKLES_IROH_SEND_LIB`, `$SPARKLES_SENDME`), and skips without
them. `iroh_send.FXS7.sendmeReceives` sends a tree on loopback and checks that
`sendme receive` writes exactly its files.
