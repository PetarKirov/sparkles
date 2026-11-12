# Application close decisions

The Vulkan host sends native window-close requests to an optional component
hook, `app.closeRequested(ref host)`. The hook calls `host.quit()` when closure
is approved. It can instead show a decision through the normal widget tree and
approve closure after a later input or worker completion. Both the client-drawn
close button and the window system's close request use this policy.
The TUI uses the same hook for Ctrl+C when the application has not grabbed
the keyboard. A grabbed embedded terminal continues receiving the interrupt.

Without the hook, `runApp` approves closure immediately. Call
`requestAppClose(app, host)` to exercise the same policy with a recording host.
The lower-level `run`, `runNative` and `runTui` functions accept an optional final
`close` callback, defaulting to `quitOnClose`.

The host schedules another frame after a deferred native request. A component
that waits for asynchronous work must continue scheduling its own wakeups and
call `host.quit()` after approval. A save's successful write and durable
acknowledgment can arrive in different application states; do not approve exit
merely because the worker queue is empty.

The editor uses the hook for the same per-document Save/Discard/Cancel policy
as its Quit command. Save waits for a captured revision's receipt, retains
later edits as dirty, and returns to the decision after failures or unconfirmed
durability. Discard applies only to the document named by the decision.

This hook handles orderly requests after the native host opens. It does not
turn process termination, device loss or operating-system activity destruction
into a vetoable request. Recovery must protect against those separately. The
legacy raylib loop retains its existing close behavior. Terminal input loss
ends the input loop rather than opening a decision that has no input channel;
the shutdown hook must flush retained recovery state and report failures.

The runnable [close-policy example](../../../../libs/ui-app/examples/close-policy.d)
demonstrates deferred and approved requests without opening a window.
