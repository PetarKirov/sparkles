/**
The hit-id registry (`INP27`, `INP28`): hit ids are issued, never chosen by
hand.

A component that marks widgets hit-testable asks a $(LREF HitRegistry) for a
$(LREF HitBlock) under a $(LREF HitKey) — its component tag and an instance
key — and stamps `block[i]` on its `i`-th target. The registry gives the same
block on every frame the key is asked for again, so a press armed on one frame
(`STM10`) or a capture taken (`STM11`) still names its target on the release
frame, even when conditional controls appear or vanish in between. A key not
asked for during a frame frees its block when the next frame begins.

$(B Blocks never overlap and never move.) Each key owns one slot of
$(LREF HitRegistryOf.stride) ids — 2³² on a 64-bit target — so a block that
grows (an undo list getting longer) keeps its base. Slots are numbered
monotonically: a freed slot is reused only once fresh ones run out, and then
the one freed longest ago first, so an id a held press still names is not
handed to another key while it can matter. Slot 0, the ids below `stride`, is
never issued: `0` means "not hit-testable", and the small literal ids of tests
and single-widget examples live there without meeting an issued block.

$(B Decoding a hit is a query, not arithmetic.) A press arrives as an id; the
handler asks $(LREF HitRegistryOf.find) for the key it cares about and the
block answers `contains`/`indexOf`. Routing runs against the last painted
frame, and between frames the registry holds exactly the blocks that frame
was built with.

$(B A retained tree re-asks.) A component that rebuilds its widgets only when
its data changes (a document viewer) still asks for its keys on every frame
it is shown; asking is a lookup, the block is the one its cached widgets
already carry.

---
HitRegistry hits;
hits.beginFrame();
const tabs = hits.block(HitKey("editor.tabs"), documents.length);
foreach (i, doc; documents)
    row ~= b.add(Widget(kind: WidgetKind.text, text: doc.title, hitId: tabs[i]));

// later, when a press arrives:
size_t tab;
if (hits.find(HitKey("editor.tabs")).indexOf(hit, tab))
    activate(tab);
---
*/
module sparkles.ui.hit_ids;

import sparkles.base.buffer : UniqueBuffer;

/**
What a hit block is asked for under: a component's tag and the instance of it.

`tag` names the component kind (`"editor.tabs"`, `"find-bar"`); `instance`
tells copies of it apart (a pane id, a document id), `0` when there is one.
*/
struct HitKey
{
    string tag;          /// the component kind
    size_t instance;     /// which one of them; `0` for a singleton

    ///
    bool opEquals(in HitKey other) const @safe pure nothrow @nogc
        => instance == other.instance && tag == other.tag;
}

/**
A contiguous run of hit ids issued to one key: `length` ids from `base`.

`HitBlock.init` is the empty block — what $(LREF HitRegistryOf.find) answers
for a key not issued — whose ids are all `0` and which contains nothing.
*/
struct HitBlock
{
    size_t base;         /// the first id; `0` for the empty block
    size_t length;       /// how many ids the key asked for

@safe pure nothrow @nogc:

    /// Whether the block was issued.
    bool opCast(T : bool)() const => base != 0;

    /**
    The `index`-th id of the block, or `0` (not hit-testable) past its end.

    A retained component can outgrow the block it claimed at the start of
    the frame — an event adds a row before the next claim — and the row it
    cannot number yet is inert for that frame rather than an id of another
    key's slot.
    */
    size_t opIndex(size_t index) const => base == 0 || index >= length ? 0 : base + index;

    /// The block's first id: the id of a single-control block.
    size_t id() const => this[0];

    /// Whether `hit` is one of the block's ids.
    bool contains(size_t hit) const => base != 0 && hit >= base && hit - base < length;

    /// The index of `hit` in the block, when `hit` is one of its ids.
    bool indexOf(size_t hit, out size_t index) const
    {
        if (!contains(hit)) return false;
        index = hit - base;
        return true;
    }
}

/// The ids one key's slot holds on this target: 2³² on 64-bit, 2¹⁶ on 32-bit.
enum size_t defaultHitStride = size_t.sizeof == 8 ? size_t(1) << 32 : size_t(1) << 16;

/// The registry every application uses.
alias HitRegistry = HitRegistryOf!defaultHitStride;

/**
The registry, parameterised by its slot size so a test can run it out of
slots. Applications use $(LREF HitRegistry).

A key's slot is `stride` ids; slot `s` holds the ids `[s * stride, (s + 1) *
stride)`, and slots `1 … size_t.max / stride` are issued, so an application
has `size_t.max / stride` keys alive at once.
*/
struct HitRegistryOf(size_t stride_)
if (stride_ >= 2 && (stride_ & (stride_ - 1)) == 0)
{
    /// The ids in one key's slot.
    enum size_t stride = stride_;

    /// The slots there are to issue.
    enum size_t slotCount = size_t.max / stride;

    private static struct Entry
    {
        HitKey key;
        size_t slot;
        size_t length;
        size_t askedIn;      // the frame that last asked for it
    }

    private UniqueBuffer!(Entry, 16) entries;
    private UniqueBuffer!(size_t, 16) freed;   // freed slots, oldest first from `freedHead`
    private size_t freedHead;
    private size_t nextSlot = 1;
    private size_t frame = 1;

@safe pure nothrow @nogc:

    /**
    Begins a frame: frees every block the previous frame did not ask for.

    Call it once, before the frame's first $(LREF block). A frame that asks
    for nothing frees everything on the next call.
    */
    void beginFrame()
    {
        size_t kept;
        foreach (i; 0 .. entries.length)
        {
            if (entries[i].askedIn == frame)
                entries[kept++] = entries[i];
            else
                freed.put(entries[i].slot);
        }
        while (entries.length > kept)
            entries.popBack();
        ++frame;
    }

    /**
    The block for `key`, `length` ids long: the block the key already holds
    when it holds one, a fresh one otherwise.

    The base never changes while the key is asked for frame after frame; the
    length is the largest asked for in this frame.
    */
    HitBlock block(HitKey key, size_t length = 1)
    in (length >= 1 && length < stride, "a hit block is 1 to stride - 1 ids")
    {
        foreach (ref e; entries[])
        {
            if (e.key != key) continue;
            e.length = e.askedIn == frame && e.length > length ? e.length : length;
            e.askedIn = frame;
            return HitBlock(e.slot * stride, e.length);
        }
        const slot = takeSlot();
        entries.put(Entry(key, slot, length, frame));
        return HitBlock(slot * stride, length);
    }

    /**
    The block `key` holds — the one the last built frame stamped on its
    widgets — or the empty block when it holds none. Asking nothing, it does
    not keep the block alive.
    */
    HitBlock find(in HitKey key) const
    {
        foreach (ref e; entries[])
            if (e.key == key)
                return HitBlock(e.slot * stride, e.length);
        return HitBlock.init;
    }

    /// The key that holds `hit`, and its index in that key's block.
    bool ownerOf(size_t hit, out HitKey key, out size_t index) const
    {
        const slot = hit / stride;
        foreach (ref e; entries[])
        {
            if (e.slot != slot || hit - slot * stride >= e.length) continue;
            key = e.key;
            index = hit - slot * stride;
            return true;
        }
        return false;
    }

    /// How many keys hold a block.
    size_t length() const => entries.length;

    private size_t takeSlot()
    {
        if (nextSlot <= slotCount)
            return nextSlot++;
        assert(freedHead < freed.length, "every hit slot is held: more keys than the registry can issue");
        const slot = freed[freedHead++];
        if (freedHead == freed.length)
        {
            freed.clear(releaseStorage: false);
            freedHead = 0;
        }
        return slot;
    }
}

@("HitRegistry.block.disjointKeys")
@safe pure nothrow @nogc
unittest
{
    HitRegistry hits;
    hits.beginFrame();
    const a = hits.block(HitKey("tabs"), 40);
    const b = hits.block(HitKey("buttons"), 3);
    const c = hits.block(HitKey("tabs", instance: 2), 40);
    assert(a && b && c);
    // Disjoint: no id of one is an id of another, and none is 0.
    const HitBlock[3] all = [a, b, c];
    foreach (x; all)
        foreach (y; all)
            if (x.base != y.base)
                assert(!y.contains(x[0]) && !y.contains(x[x.length - 1]));
    assert(a.base >= HitRegistry.stride, "slot 0 is never issued");
}

@("HitRegistry.block.stableAcrossFrames")
@safe pure nothrow @nogc
unittest
{
    HitRegistry hits;
    hits.beginFrame();
    const first = hits.block(HitKey("undo"), 4);
    hits.beginFrame();
    const grown = hits.block(HitKey("undo"), 9);
    assert(grown.base == first.base, "a block keeps its base while it grows");
    assert(grown.length == 9);
    assert(hits.find(HitKey("undo")) == grown);
}

@("HitRegistry.beginFrame.freesUnasked")
@safe pure nothrow @nogc
unittest
{
    HitRegistry hits;
    hits.beginFrame();
    const dialog = hits.block(HitKey("dialog"), 2);
    hits.block(HitKey("tabs"), 3);
    hits.beginFrame();
    hits.block(HitKey("tabs"), 3);     // the dialog closed: not asked
    hits.beginFrame();
    assert(!hits.find(HitKey("dialog")));
    HitKey owner;
    size_t index;
    assert(!hits.ownerOf(dialog[1], owner, index), "a freed id resolves to nothing");
    const reopened = hits.block(HitKey("dialog"), 2);
    assert(reopened.base != dialog.base, "a fresh slot, not the freed one");
}

/// INP28: a press held across a frame that adds a control keeps its id.
@("HitRegistry.block.pressSurvivesNewControl")
@safe pure nothrow @nogc
unittest
{
    HitRegistry hits;
    hits.beginFrame();
    hits.block(HitKey("toolbar"), 2);
    const pressed = hits.block(HitKey("save"))[0];   // the press arms this id

    hits.beginFrame();                               // a control appears first
    hits.block(HitKey("toolbar"), 2);
    hits.block(HitKey("restore"));
    const release = hits.block(HitKey("save"));
    assert(release.contains(pressed), "the release frame tests the armed id");
}

@("HitRegistry.ownerOf.resolvesIssuedIds")
@safe pure nothrow @nogc
unittest
{
    HitRegistry hits;
    hits.beginFrame();
    hits.block(HitKey("a"));
    const b = hits.block(HitKey("b", instance: 7), 5);
    HitKey key;
    size_t index;
    assert(hits.ownerOf(b[3], key, index));
    assert(key == HitKey("b", instance: 7) && index == 3);
    assert(!hits.ownerOf(b.base + 5, key, index), "past the asked length");
    assert(!hits.ownerOf(7, key, index), "slot 0 holds nothing");
}

@("HitRegistry.block.lengthIsTheFramesLargest")
@safe pure nothrow @nogc
unittest
{
    HitRegistry hits;
    hits.beginFrame();
    hits.block(HitKey("rows"), 10);
    assert(hits.block(HitKey("rows"), 3).length == 10, "two asks in a frame keep the larger");
    hits.beginFrame();
    assert(hits.block(HitKey("rows"), 3).length == 3, "a new frame starts from its own asks");
}

@("HitBlock.init.isEmpty")
@safe pure nothrow @nogc
unittest
{
    size_t index;
    assert(!HitBlock.init);
    assert(HitBlock.init[0] == 0);
    assert(HitBlock(64, 2)[1] == 65 && HitBlock(64, 2)[2] == 0, "past the end is inert");
    assert(!HitBlock.init.contains(0) && !HitBlock.init.indexOf(0, index));
}

@("HitRegistryOf.takeSlot.reusesOldestFreedWhenExhausted")
@safe pure nothrow @nogc
unittest
{
    // A stride of a quarter of the id space leaves three slots to issue.
    alias Tiny = HitRegistryOf!(size_t(1) << (size_t.sizeof * 8 - 2));
    static assert(Tiny.slotCount == 3);
    Tiny hits;
    hits.beginFrame();
    const a = hits.block(HitKey("a"));
    const b = hits.block(HitKey("b"));
    const c = hits.block(HitKey("c"));
    hits.beginFrame();
    hits.block(HitKey("c"));           // a and b freed, a first
    hits.beginFrame();
    hits.block(HitKey("c"));
    assert(hits.block(HitKey("d")).base == a.base, "the slot freed longest ago");
    assert(hits.block(HitKey("e")).base == b.base);
    assert(c.base != a.base && c.base != b.base);
}
