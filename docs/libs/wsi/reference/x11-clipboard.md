# X11 clipboard transfers

`X11Wsi.offerClipboard` announces MIME types and either owned bytes or a
borrowed provider. A borrowed provider must remain alive until the offer ends.
`receive(offer, mime, sink)` returns a generational transfer ID; the sink remains
alive until its one `finish` callback. A successful `cancelTransfer(id)` finishes
the sink immediately and releases its reference. A finished or withdrawn ID
cannot name a replacement sink.

Each incoming X11 conversion has a private requestor window. Its window and
property identify the wire transaction independently of the reusable transfer
pool slot. A delayed selection reply cannot become bytes for a newer transfer.
The backend retains eight wire slots and eight fixed property atoms; it creates
no atom per paste. Completed requestor windows are destroyed.

Canceled conversions and `INCR` streams are drained without calling their
former sinks. If all wire slots are occupied, a new read may retire a canceled
requestor window. It never retires a live read to make room. The replacement
gets a different window ID, so old packets remain harmless even when their
property atom is reused. This also prevents canceled providers that never
reply from permanently exhausting clipboard capacity. Queued requests to the
backend's own retired windows are ignored rather than producing `BadWindow`.

Owner notifications are revalidated against the X server before they withdraw
an offer: an older queued loss notification cannot invalidate a newer
synchronously accepted offer. Clipboard ownership and application paste
ownership are separate; the application must still retain the requesting
document or input identity.

Whole values and `INCR` chunks are read in pieces of at most 64 KiB. This is a
streaming bound, not an application payload limit. The
[Vulkan host adapter](../../ui-app/reference/clipboard.md) validates complete
UTF-8 and applies its own per-read limit. X11 imposes no transfer deadline;
eight live stalled providers occupy the bounded wire capacity until completion,
cancellation or host closure.

The focused native probe runs shared clipboard conformance, including a
32 MiB `INCR` transfer, then cancels nine queued own-clipboard reads and verifies
that a subsequent read completes without stale callbacks or protocol errors:

```bash
dub build --single libs/wsi/examples/x11-clipboard-probe.d -b checked --compiler=ldc2
xvfb-run -a libs/wsi/build/wsi-x11-clipboard-probe
```

The editor's private-provider probe additionally changes ownership eight times
while holding old replies, then delivers stale and current replies to check the
resulting document checkpoint:

```bash
dub run --single apps/editor/tools/native-close-probe.d -b checked --compiler=ldc2 -- --clipboard-withdrawal
```
