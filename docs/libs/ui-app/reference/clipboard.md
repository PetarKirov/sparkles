# Clipboard reads

The native Vulkan host offers `readClipboard(request)` alongside clipboard
writes. A read returns `true` when accepted and later delivers `PasteEvent`
chunks carrying that request. The final chunk has `last == true`; an empty
clipboard produces one empty final chunk. A synchronous `false` result leaves
no pending native transfer.

`allocateClipboardRequest()` supplies increasing identities shared by every
consumer of the host session. `forwardClipboard(field, host)` uses that
allocator when present and updates the field's expected reply identity.
Consumers that provide their own request mapper must allocate from the same
host namespace, retain the requesting input's identity and translate the
answer back to its local request. Reused or decreasing native request IDs
are rejected.

The native adapter retains eight independent transfers, each limited to
16 MiB. Clipboard bytes become paste events only after the complete transfer
finishes and passes UTF-8 validation. Oversized, malformed or failed transfers
complete with empty tagged data and a diagnostic; partial text is never
inserted. `takeClipboardError()` consumes the latest diagnostic without
exposing clipboard contents. Native transfer buffers are released explicitly
after delivery or cancellation.

Offers arriving during initial window configuration are retained before app
setup. Clipboard reads remain independent of font or GPU resources, and sink
references are cancelled before their storage is released during host teardown.
The adapter does not impose a transfer timeout; a stalled provider occupies a
bounded slot until completion or host closure.

## Routing replies to their owner

An application with several inputs must deliver each reply to the input that
asked, and to nothing once that input is gone. `ClipboardRouter!(Owner,
capacity = 64)` (`sparkles.ui_app.clipboard_router`) does this for any
application-defined `Owner` value. The application passes a hooks object to
both of its calls:

| Hook                                                     | Required by | Meaning                                                                           |
| -------------------------------------------------------- | ----------- | --------------------------------------------------------------------------------- |
| `bool valid(in Owner owner)`                             | both        | Whether `owner` may still receive text                                            |
| `void deliver(in Owner owner, scope const(char)[] text)` | `receive`   | The completed paste, for a valid owner                                            |
| `Owner unsolicited()`                                    | optional    | The owner of a paste nobody requested (`request == 0`); without it, it is dropped |

`route(host, owner, hooks)` checks `owner`, drops every pending read whose
owner is no longer valid, and records a new one. It returns a
`ClipboardTicket`: the `request` to pass to `host.readClipboard`, or zero and
a `ClipboardRefusal` (`invalidOwner`, `full`, `exhausted`). Identities come
from the host's `allocateClipboardRequest()` when it has one, else from the
router's own counter. It fits as the `route` argument of `forwardClipboard`.

`receive(chunk, hooks)` joins a reply's chunks and returns a `PasteOutcome`.
The owner is checked before every chunk. A chunk of another reply abandons the
partial one. A reply is consumed once: its request stops being pending when it
is delivered, cancelled (`cancelled`, its owner became invalid) or abandoned.
A chunk whose request is not pending is `dropped`.

The editor's owner is the document ID plus the palette ticket, dialog epoch or
find-bar epoch, and the field's local request. A delayed reply can update its
original live tab without moving focus; a closed or cancelled input cannot
consume it. Terminal-emulator paste uses unsolicited events (`request == 0`);
explicit terminal clipboard reads depend on the terminal host's capabilities.

`apps/editor/tools/native-close-probe.d --clipboard` runs a private X11
provider that delays two transfers and completes them in reverse order.
The resulting checkpoint must retain each tab's intended text. This is X11
evidence; Wayland and Android clipboard acceptance remain separate gates.

The `--clipboard-withdrawal` scenario changes providers eight times while
holding replies, then sends old replies before the current one. The X11 backend
isolates these wire conversions with private requestor windows; see
[X11 clipboard transfers](../../wsi/reference/x11-clipboard.md) for cancellation,
capacity reclamation and the focused native streaming probe.
