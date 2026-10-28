/**
What a step asks of its host (`EDT9`). The step reports these and never
performs them; it does not depend on whether the host did.

Specification: `docs/specs/ui/editor.md` §2.
*/
module sparkles.ui.editor.effect;

import sparkles.text_buffer.change_set : ChangeSet;
import sparkles.text_buffer.text : Text;

/// The kind of a request to the host.
enum EffectKind : ubyte
{
    /// Nothing applied; `reason` says why.
    noop,
    /// An edit inside a read-only span was dropped (`EDT10`).
    rejectedReadOnly,
    /// The text changed; `changes` is the change set (`EDR4`).
    changed,
    submit,
    cancel,
    /// Put `text` on the system clipboard.
    writeClipboard,
    /// Read the system clipboard and answer request `request` (`INP25`).
    readClipboard,
    /// Tell the input method its composition was cancelled.
    cancelComposition,
    /// The kill ring dropped its oldest entry.
    killRingFull,
    /// Bring the primary caret into view.
    scrollToPrimary,
}

/// Why a command changed nothing.
enum NoopReason : ubyte
{
    nothingToDo,
    /// The host lacks a capability the command needs (`EDI5`).
    capabilityAbsent,
    nothingToUndo,
    nothingToRedo,
    /// `addNextOccurrence` found no further match.
    noMatch,
    /// Vertical motion in single-line mode.
    singleLine,
    /// A clipboard answer for a request that is no longer pending.
    staleAnswer,
    /// `yankPop` without a preceding yank, or an empty kill ring.
    nothingToYank,
}

/// One request to the host.
struct EditEffect
{
    EffectKind kind;
    NoopReason reason;
    /// `changed`: the change set from the previous text.
    ChangeSet changes;
    /// `writeClipboard`: the text to write.
    Text text;
    /// `readClipboard`: the request number the answer must carry.
    uint request;
}

/// The requests one step makes, in order.
struct EditEffects
{
    private EditEffect[6] items;
    private size_t count;

@safe pure nothrow @nogc:

    void put(EditEffect effect) scope
    in (count < items.length, "too many effects for one step")
    {
        items[count++] = effect;
    }

    const(EditEffect)[] opIndex() const return => items[0 .. count];

    size_t length() const scope => count;

    /// Whether an effect of `kind` was requested.
    bool has(EffectKind kind) const scope
    {
        foreach (ref e; items[0 .. count])
            if (e.kind == kind)
                return true;
        return false;
    }

    /// The first effect of `kind`; `has(kind)` must hold.
    ref const(EditEffect) first(EffectKind kind) const return
    {
        foreach (ref e; items[0 .. count])
            if (e.kind == kind)
                return e;
        assert(0, "no such effect");
    }
}
