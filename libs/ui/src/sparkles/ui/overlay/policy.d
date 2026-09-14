/**
What opens an anchored overlay, what closes it, and what a target that cannot
serve a trigger says instead.

$(H2 A dropped trigger is a declaration, not a silence)

The failure this module exists to prevent is a surface that simply never
appears. A tooltip bound to hover on a touchscreen is not a degraded tooltip —
it is content the reader has no route to at all, and nothing on screen says so.
So $(LREF resolveTriggers) returns what is $(B served), what is $(B dropped) and
what is $(B substituted) as a stored, readable value: a consumer can publish the
substitution, and a test can assert it (`TRG1`, `TRG4`).

$(B Tap-to-pin is the only hover substitution expressible on all three live
targets) — the terminal decodes SGR-1006 releases, raylib derives press/release
edges, and the Android recognizer emits a tap as a press plus a release. Long
press is deliberately not the default: on Android it is already spent on
starting a text selection, and it needs a recognizer that is not wired
everywhere (`TRG2`, `TRG3`).

$(H2 Dismissal is a policy word ANDed with a cause)

$(LREF wouldDismiss) is one pure function over three inputs: what the overlay
permits, what the router is offering, and the latched facts neither of those
carries. The policy word alone is insufficient, which is why the facts are a
separate parameter — an overlay whose own press began inside it must not be
closed by the release that ends outside it, and no flag word can express that.

A $(B mandatory) class of causes bypasses the word entirely: an overlay whose
anchor is gone has nothing to be anchored to, and a policy that declined to
close would leave it pinned to a rect nobody owns (`DSM1`).

$(B Anchor clipped hides; anchor gone closes.) The two look alike from a
distance and lead to opposite actions — the first survives to the next scroll,
the second must not (`DSM8`).

Spec: `docs/specs/ui/popup.md` `TRG1`–`TRG5`, `DSM1`–`DSM8`, `DSM11`, `MDL2`,
`MDL3`.
*/
module sparkles.ui.overlay.policy;

import sparkles.input : InputCapabilities;
import sparkles.ui.overlay.arena : OverlayArena;
import sparkles.ui.widget : HitBehavior;

@safe pure nothrow @nogc:

/**
What a surface $(I wants) to be opened by — a declaration, in the style of
`Decoration.arrow`: the view states the intent and the resolution happens
against a target.
*/
struct TriggerPolicy
{
    bool hover;        /// the pointer rests on the trigger
    bool focusVisible; /// the trigger takes keyboard focus
    bool activate;     /// a click, `Enter` or `Space` on the trigger
    bool longPress;    /// a sustained press, through a gesture recognizer
    bool contextMenu;  /// a right press, or the platform's menu key
}

/// The tooltip default: hover, plus focus so a keyboard reader gets it too.
immutable TriggerPolicy hintTriggers = TriggerPolicy(hover: true,
    focusVisible: true);
/// The menu default: opened deliberately, never by passing over it.
immutable TriggerPolicy menuTriggers = TriggerPolicy(activate: true);
/// The context-menu default.
immutable TriggerPolicy contextTriggers = TriggerPolicy(contextMenu: true);

/**
What a target actually does with a $(LREF TriggerPolicy).

Three disjoint sets, and the third is the point: `dropped` alone would leave a
consumer knowing only that something is missing. `substituted` says what to
publish instead — "tap to pin" — so the affordance is discoverable rather than
merely present (`TRG4`).
*/
struct TriggerPlan
{
    TriggerPolicy served;      /// fires on this target
    TriggerPolicy dropped;     /// cannot fire, and nothing replaces it
    TriggerPolicy substituted; /// cannot fire; another trigger stands in

@safe pure nothrow @nogc const scope:

    /// Whether anything at all opens this surface here. `false` is a product
    /// hole, and a consumer should say so rather than render an inert widget.
    bool reachable()
        => served.hover || served.focusVisible || served.activate
            || served.longPress || served.contextMenu;

    /// Whether a reader needs telling that the usual route is unavailable.
    bool degraded()
        => dropped.hover || dropped.focusVisible || dropped.activate
            || dropped.longPress || dropped.contextMenu
            || substituted.hover || substituted.focusVisible
            || substituted.activate || substituted.longPress
            || substituted.contextMenu;
}

/**
Resolve `want` against `caps` (`TRG1`).

The shape $(REF ScrollbarState.expanded, sparkles,ui,state) already uses, one
dimension over: a pure function from a declaration and a capability set to what
the target will actually do.
*/
TriggerPlan resolveTriggers(in TriggerPolicy want, in InputCapabilities caps)
{
    TriggerPlan plan;

    // Hover needs both the capability AND a motion stream to notice a rest on
    // the target. A terminal that has not enabled DEC 1003 reports no bare
    // motion at all, so a hover trigger there is not slow — it is absent.
    const canHover = caps.hover && caps.motion;
    if (want.hover)
    {
        if (canHover)
            plan.served.hover = true;
        else if (caps.tier >= typeof(caps.tier).interactive)
            // `TRG3`: tap-to-pin, the one substitution every live target can
            // express. A press-and-release is decoded by the terminal, derived
            // by raylib and emitted by the Android recognizer as a tap.
            plan.substituted.hover = true;
        else
            plan.dropped.hover = true;
    }

    // Focus-visible is bound to key DOWN, not to a release: `INP16` means a
    // terminal never reports one, and a rule written against release parity
    // would make a keyboard reader's tooltip unreachable there (`MDL4`).
    if (want.focusVisible)
    {
        if (caps.tier >= typeof(caps.tier).interactive)
            plan.served.focusVisible = true;
        else
            plan.dropped.focusVisible = true;
    }

    if (want.activate)
    {
        if (caps.tier >= typeof(caps.tier).interactive)
            plan.served.activate = true;
        else
            plan.dropped.activate = true;
    }

    // A long press needs a recognizer, and `maxPointers` is not one: a target
    // can report contacts nobody interprets (`TRG2`).
    if (want.longPress)
    {
        if (caps.gestures)
            plan.served.longPress = true;
        else if (caps.tier >= typeof(caps.tier).interactive)
            plan.substituted.longPress = true;
        else
            plan.dropped.longPress = true;
    }

    // A right press. A touch target has no second button and no menu key, so
    // this is where a long press would substitute — if one were wired.
    if (want.contextMenu)
    {
        if (caps.tier >= typeof(caps.tier).interactive && caps.hover)
            plan.served.contextMenu = true;
        else if (caps.gestures)
            plan.substituted.contextMenu = true;
        else
            plan.dropped.contextMenu = true;
    }

    return plan;
}

/**
Why an overlay opened, recorded on the record and readable by the $(B placement)
stage as well as the timing one (`TRG5`).

Placement cares: a menu opened by a right press anchors to the cursor, the same
menu opened from the keyboard anchors to its trigger. A cause reachable only by
the timing layer forces the second case to be a different code path.

Deliberately $(I not) sufficient on its own. The catalog's claim that one enum
derives every cross-trigger suppression rule was refuted, so a consumer keeps
per-trigger latches for time-scoped suppression and for suppression while shut.
*/
enum OpenCause : ubyte
{
    none,
    programmatic, /// the application opened it
    hover,        /// the pointer rested on the trigger
    focusVisible, /// the trigger took keyboard focus
    activate,     /// clicked, or `Enter`/`Space`
    longPress,    /// a sustained press
    contextMenu,  /// a right press or menu key
}

/// How deliberate the open was. A surface opened by passing over something
/// should yield to one the reader asked for; the ordering is what says so.
enum TriggerPriority : ubyte
{
    background, /// hover: the reader did not ask
    sustained,  /// focus: the reader is here, but did not ask for this
    deliberate, /// activate, long press, context menu: they asked
}

/// ditto
TriggerPriority priorityOf(OpenCause c)
{
    final switch (c)
    {
        case OpenCause.none:
        case OpenCause.hover:
            return TriggerPriority.background;
        case OpenCause.focusVisible:
            return TriggerPriority.sustained;
        case OpenCause.programmatic:
        case OpenCause.activate:
        case OpenCause.longPress:
        case OpenCause.contextMenu:
            return TriggerPriority.deliberate;
    }
}

/// What an overlay $(B permits) to close it (`DSM1`). A word, ANDed with the
/// cause the router offers.
enum DismissOn : ushort
{
    nothing           = 0,
    closeRequest      = 1 << 0,  /// `isDismiss`: Escape and Android back alike
    pressOutside      = 1 << 1,
    releaseOutside    = 1 << 2,
    outsideAnchor     = 1 << 3,
    triggerReactivate = 1 << 4,
    focusOutside      = 1 << 5,
    surfaceBlur       = 1 << 6,  /// not detectable on the TUI (`DSM7`)
    resize            = 1 << 7,
    scroll            = 1 << 8,
    siblingOpened     = 1 << 9,
    cascade           = 1 << 10,
}

/// The menu default: Escape and an outside press, and nothing else — a menu
/// that closed on scroll would vanish while the reader was reaching for it.
immutable DismissOn menuDismiss =
    cast(DismissOn)(DismissOn.closeRequest | DismissOn.pressOutside
        | DismissOn.triggerReactivate | DismissOn.cascade);
/// The tooltip default: it also goes when the thing it describes moves.
immutable DismissOn hintDismiss =
    cast(DismissOn)(DismissOn.closeRequest | DismissOn.pressOutside
        | DismissOn.outsideAnchor | DismissOn.scroll | DismissOn.resize);

/// What the router is offering, including the $(B mandatory) class that
/// bypasses the policy word (`DSM1`).
enum DismissCause : ubyte
{
    none,
    closeRequest, releaseOutside, pressOutside, outsideAnchor,
    triggerReactivate, focusOutside, surfaceBlur, resize, scroll,
    siblingOpened, cascade,
    // --- mandatory, below ---
    anchorGone,    /// the anchor is not in this frame: nothing to point at
    anchorClipped, /// it is scrolled out: HIDE, do not close (`DSM8`)
    unplaceable,   /// the solve refused; there is no honest geometry
}

/// Whether `c` bypasses the policy word.
bool isMandatory(DismissCause c)
    => c == DismissCause.anchorGone || c == DismissCause.anchorClipped
        || c == DismissCause.unplaceable;

/// Why an overlay closed, stored on the record so dismissal is a $(B value) the
/// recording canvas can assert rather than an effect it must observe (`DSM2`).
enum DismissReason : ubyte
{
    none,
    programmatic, closeRequest, pressOutside, releaseOutside, outsideAnchor,
    triggerReactivate, focusOutside, surfaceBlur, anchorGone, anchorClipped,
    unplaceable, resize, scroll, siblingOpened, cascade, parentClosed, timeout,
}

/// An overlay's dismissal policy.
struct DismissPolicy
{
    /// What may close it.
    DismissOn on = menuDismiss;
    /// The dismissal group. A menu and its submenus share one, so an outside
    /// press closes the chain rather than one link of it.
    size_t group;
    /**
    Whether the dismissing press $(B also) reaches what it hit (`DSM5`).

    Independent of dismissal on purpose: the corpus splits on the default, and
    sparkles routes its own events, so there is no ambient answer to inherit. A
    menu usually swallows the click that closes it; a tooltip usually does not.
    */
    bool passThrough;
}

/**
The latched facts the evaluator needs and neither the policy word nor the cause
carries (`DSM1`, narrowed).

Each of these exists because a rule written without it is wrong in a way that
only shows up under interaction.
*/
struct DismissFacts
{
    /// The overlay's $(B own) `PressState` armed inside it (`DSM4`). A press
    /// that began inside and released outside is a drag, not a dismissal — and
    /// sharing the button-activation instance would let an in-overlay button
    /// press disarm this test.
    bool armedInside;
    /// It opened this frame (`DSM9`). Events route against the last painted
    /// frame, so its hit rect is one frame stale by construction: the press
    /// that opened it would otherwise read as a press outside it.
    bool openedThisFrame;
    /// A drag that began outside owns the pointer until it releases (`LYR6`),
    /// so it is exempt from every outside cause.
    bool captureOutside;
}

/**
The one evaluator (`DSM1`).

Returns the reason to record, or `DismissReason.none` to stay open. A mandatory
cause bypasses `p.on`; `anchorClipped` is mandatory and yet answers `none`,
because the correct response is to $(B hide) — the overlay survives to the next
scroll (`DSM8`).
*/
DismissReason wouldDismiss(in DismissPolicy p, DismissCause cause,
    in DismissFacts f)
{
    if (cause == DismissCause.none)
        return DismissReason.none;

    // `DSM8`: clipped is not gone. It is the one mandatory cause that does not
    // close, and conflating the two either strands a popup on a stale rect or
    // destroys state the next scroll would have restored.
    if (cause == DismissCause.anchorClipped)
        return DismissReason.none;

    if (cause == DismissCause.anchorGone)
        return DismissReason.anchorGone;
    if (cause == DismissCause.unplaceable)
        return DismissReason.unplaceable;

    // `DSM9`: one frame of grace. The press that opened it is delivered
    // against the frame before it existed, so without this every
    // press-triggered overlay closes itself the instant it opens.
    if (f.openedThisFrame && isOutside(cause))
        return DismissReason.none;

    // `LYR6`: a drag begun outside owns the pointer. Releasing it over an
    // overlay is not a click on the overlay, and it is not a dismissal either.
    if (f.captureOutside && isOutside(cause))
        return DismissReason.none;

    // `DSM4`: a press that began INSIDE and released outside is a drag — a
    // selection dragged out of a menu, a scrollbar grabbed and overshot.
    if (f.armedInside && cause == DismissCause.releaseOutside)
        return DismissReason.none;

    if (!permits(p.on, cause))
        return DismissReason.none;
    return reasonOf(cause);
}

/// Whether `cause` is one of the outside-the-surface family, which the
/// exemptions above apply to as a group.
private bool isOutside(DismissCause c)
    => c == DismissCause.pressOutside || c == DismissCause.releaseOutside
        || c == DismissCause.outsideAnchor || c == DismissCause.focusOutside;

/// Whether the policy word admits `cause`.
private bool permits(DismissOn on, DismissCause c)
{
    final switch (c)
    {
        case DismissCause.none: return false;
        case DismissCause.closeRequest: return (on & DismissOn.closeRequest) != 0;
        case DismissCause.pressOutside: return (on & DismissOn.pressOutside) != 0;
        case DismissCause.releaseOutside: return (on & DismissOn.releaseOutside) != 0;
        case DismissCause.outsideAnchor: return (on & DismissOn.outsideAnchor) != 0;
        case DismissCause.triggerReactivate:
            return (on & DismissOn.triggerReactivate) != 0;
        case DismissCause.focusOutside: return (on & DismissOn.focusOutside) != 0;
        case DismissCause.surfaceBlur: return (on & DismissOn.surfaceBlur) != 0;
        case DismissCause.resize: return (on & DismissOn.resize) != 0;
        case DismissCause.scroll: return (on & DismissOn.scroll) != 0;
        case DismissCause.siblingOpened: return (on & DismissOn.siblingOpened) != 0;
        case DismissCause.cascade: return (on & DismissOn.cascade) != 0;
        case DismissCause.anchorGone:
        case DismissCause.anchorClipped:
        case DismissCause.unplaceable:
            return true; // mandatory; handled before this is reached
    }
}

/// The reason a permitted cause records.
private DismissReason reasonOf(DismissCause c)
{
    final switch (c)
    {
        case DismissCause.none: return DismissReason.none;
        case DismissCause.closeRequest: return DismissReason.closeRequest;
        case DismissCause.pressOutside: return DismissReason.pressOutside;
        case DismissCause.releaseOutside: return DismissReason.releaseOutside;
        case DismissCause.outsideAnchor: return DismissReason.outsideAnchor;
        case DismissCause.triggerReactivate: return DismissReason.triggerReactivate;
        case DismissCause.focusOutside: return DismissReason.focusOutside;
        case DismissCause.surfaceBlur: return DismissReason.surfaceBlur;
        case DismissCause.resize: return DismissReason.resize;
        case DismissCause.scroll: return DismissReason.scroll;
        case DismissCause.siblingOpened: return DismissReason.siblingOpened;
        case DismissCause.cascade: return DismissReason.cascade;
        case DismissCause.anchorGone: return DismissReason.anchorGone;
        case DismissCause.anchorClipped: return DismissReason.anchorClipped;
        case DismissCause.unplaceable: return DismissReason.unplaceable;
    }
}

/**
How far focus may travel while a surface is open (`MDL3`).

Four enum values, not four control types — WinUI's lesson, and the reason a
tooltip and a dialog can share an implementation while sharing no default.
*/
enum Containment : ubyte
{
    none,    /// focus ignores it entirely (a tooltip)
    inline_, /// it joins the surrounding order (a non-modal popover)
    contain, /// Tab cycles within it, but the surface below stays live
    modal,   /// nothing below it is reachable
}

/// An overlay's focus policy. A $(B value on the spec), never a shared default
/// across surface kinds: no subject examined applies one focus behaviour to
/// tooltip, menu and dialog alike.
struct FocusPolicy
{
    Containment containment;
    /// Whether the surface takes keys at all.
    bool takesKeys;
    /**
    Initial focus is $(B actively suppressed), not merely defaulted off
    (`MDL7`).

    A touch-opened surface that takes focus opens the soft keyboard, which eats
    half the placement budget the solve just computed. Three implementations in
    the corpus suppress it, each naming touch explicitly.
    */
    bool suppressInitial;
    /// Whether closing returns focus to the trigger.
    bool restoreOnClose = true;
}

/**
The hit behaviour the open stack implies for the record at `index` (`MDL2`).

$(B Derived at hit time, never cached.) Every subject in the catalog that stored
stack-derived blocking as a mutable flag shipped a defect from it — the flag
outlives the stack that justified it, and the surface it blocked stays
unreachable after the modal above it has gone.
*/
HitBehavior blockingOf(in OverlayArena a, size_t index)
{
    if (index >= a.length)
        return HitBehavior.normal;
    // A record blocks if it says so; nothing about the stack overrides that,
    // which is what keeps this derivable rather than stateful.
    return a[index].hit;
}

@("ui.overlay.policy.aDroppedTriggerIsDeclaredNotSilent")
@safe pure nothrow @nogc unittest
{
    // `TRG1`/`TRG4`. The failure is a surface that never appears with nothing
    // saying why — content the reader has no route to at all.
    const mouse = InputCapabilities(hover: true, motion: true);
    const served = resolveTriggers(hintTriggers, mouse);
    assert(served.served.hover && served.served.focusVisible);
    assert(served.reachable && !served.degraded);

    // A touchscreen: hover cannot fire, so it is SUBSTITUTED rather than
    // dropped — tap-to-pin, the one route all three live targets express.
    const touch = InputCapabilities(hover: false, maxPointers: 10);
    const tapped = resolveTriggers(hintTriggers, touch);
    assert(!tapped.served.hover && tapped.substituted.hover);
    assert(tapped.reachable, "focus still opens it");
    assert(tapped.degraded, "and a reader needs telling the usual route is gone");

    // A terminal with motion reporting OFF is the same case, and it is the one
    // that surprises: the pointer can hover, but nothing reports the rest.
    const quietTerm = InputCapabilities(hover: true, motion: false);
    assert(resolveTriggers(hintTriggers, quietTerm).substituted.hover,
        "hover without a motion stream is absent, not slow");
}

@("ui.overlay.policy.longPressNeedsARecognizerNotContacts")
@safe pure nothrow @nogc unittest
{
    // `TRG2`: `maxPointers` is a digitizer's limit, not evidence that anything
    // interprets those contacts. A target with ten fingers and no recognizer
    // reports contacts nobody turns into a gesture.
    auto contactsOnly = InputCapabilities(hover: false, maxPointers: 10);
    const want = TriggerPolicy(longPress: true);
    assert(!resolveTriggers(want, contactsOnly).served.longPress);
    assert(resolveTriggers(want, contactsOnly).substituted.longPress);

    auto wired = contactsOnly;
    wired.gestures = true;
    assert(resolveTriggers(want, wired).served.longPress);
}

@("ui.overlay.policy.anchorGoneClosesAndAnchorClippedHides")
@safe pure nothrow @nogc unittest
{
    // `DSM8`. The two look alike and lead to opposite actions: conflating them
    // either strands a popup on a stale rect or destroys state the next scroll
    // would have restored.
    const p = DismissPolicy(on: DismissOn.nothing); // permits NOTHING
    const none = DismissFacts.init;

    assert(wouldDismiss(p, DismissCause.anchorGone, none)
        == DismissReason.anchorGone, "mandatory: it bypasses the policy word");
    assert(wouldDismiss(p, DismissCause.unplaceable, none)
        == DismissReason.unplaceable);
    assert(wouldDismiss(p, DismissCause.anchorClipped, none)
        == DismissReason.none, "clipped HIDES; the record survives");
    assert(isMandatory(DismissCause.anchorClipped));
}

@("ui.overlay.policy.theLatchedFactsAreNotExpressibleAsAPolicyWord")
@safe pure nothrow @nogc unittest
{
    // Each fact exists because a rule written without it is wrong in a way that
    // only appears under interaction — which is exactly the kind of bug a flag
    // word cannot be reviewed into catching.
    const p = DismissPolicy(on: cast(DismissOn)(DismissOn.pressOutside
        | DismissOn.releaseOutside));

    // Baseline: an outside press closes it.
    assert(wouldDismiss(p, DismissCause.pressOutside, DismissFacts.init)
        == DismissReason.pressOutside);

    // `DSM9`: the press that OPENED it is delivered against the frame before it
    // existed. Without one frame of grace, every press-triggered overlay closes
    // itself the instant it opens.
    assert(wouldDismiss(p, DismissCause.pressOutside,
        DismissFacts(openedThisFrame: true)) == DismissReason.none);

    // `DSM4`: a press that began INSIDE and released outside is a drag — a
    // selection dragged out of a menu, not a dismissal.
    assert(wouldDismiss(p, DismissCause.releaseOutside,
        DismissFacts(armedInside: true)) == DismissReason.none);
    assert(wouldDismiss(p, DismissCause.pressOutside,
        DismissFacts(armedInside: true)) == DismissReason.pressOutside,
        "a fresh press outside still closes it");

    // `LYR6`: a drag begun outside owns the pointer until it releases.
    assert(wouldDismiss(p, DismissCause.releaseOutside,
        DismissFacts(captureOutside: true)) == DismissReason.none);

    // A cause the word does not admit changes nothing, whatever the facts.
    assert(wouldDismiss(p, DismissCause.scroll, DismissFacts.init)
        == DismissReason.none);
}

@("ui.overlay.policy.everyPermittedCauseRecordsItsOwnReason")
@safe pure nothrow @nogc unittest
{
    // `DSM2` wants the reason to be a VALUE a test can assert. That is only
    // worth anything if the mapping is total and injective — a cause that
    // recorded a neighbour's reason would be indistinguishable from it.
    static immutable DismissCause[11] causes = [
        DismissCause.closeRequest, DismissCause.releaseOutside,
        DismissCause.pressOutside, DismissCause.outsideAnchor,
        DismissCause.triggerReactivate, DismissCause.focusOutside,
        DismissCause.surfaceBlur, DismissCause.resize, DismissCause.scroll,
        DismissCause.siblingOpened, DismissCause.cascade,
    ];
    // Permit everything, so only the mapping is under test.
    const all = DismissPolicy(on: cast(DismissOn)0x7FF);

    DismissReason[11] seen;
    foreach (i, c; causes)
    {
        seen[i] = wouldDismiss(all, c, DismissFacts.init);
        assert(seen[i] != DismissReason.none, "a permitted cause closes it");
    }
    foreach (i; 0 .. causes.length)
        foreach (j; i + 1 .. causes.length)
            assert(seen[i] != seen[j], "and each records a distinct reason");
}

@("ui.overlay.policy.priorityRanksDeliberateAboveIncidental")
@safe pure nothrow @nogc unittest
{
    // A surface opened by passing over something should yield to one the
    // reader asked for.
    assert(priorityOf(OpenCause.hover) == TriggerPriority.background);
    assert(priorityOf(OpenCause.focusVisible) == TriggerPriority.sustained);
    assert(priorityOf(OpenCause.contextMenu) == TriggerPriority.deliberate);
    assert(priorityOf(OpenCause.activate) > priorityOf(OpenCause.hover));
}
