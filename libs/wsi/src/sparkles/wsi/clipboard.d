/**
The clipboard contract: offers named by id, bytes moved in streamed transfers.

An offer is announced by one `DataOfferEvent` per MIME type and never carries
content (`DT1`). Receiving pulls the content into an application-owned sink
(`DT2`); offering lets the platform pull chunks from an application-owned
provider (`DT3`). This module holds the vocabulary every backend shares and
`ClipboardState`, the bookkeeping a backend embeds: live offers and transfers
in generational pools, so a withdrawn offer or a finished transfer is detected
as stale rather than reused.

See `docs/specs/window-system-integration/SPEC.md` §7.1.
*/
module sparkles.wsi.clipboard;

import core.lifetime : move;

import sparkles.base.buffer : InlineBuffer, UniqueBuffer;
import sparkles.base.pool.handle : Handle;
import sparkles.base.pool.pool : Pool;
import sparkles.wsi.events : DataOfferAction, maxMimeType;
import sparkles.wsi.types;

/// Identifies one transfer of an offer's content into a sink.
struct TransferTag {}

/// ditto
alias TransferId = Handle!TransferTag;

/// How a transfer ended; the sink's `finish` receives exactly one.
enum TransferStatus : ubyte
{
    completed, /// every byte was delivered
    failed,    /// the source or the platform failed, or the offer ended
    cancelled, /// `cancelTransfer` ended it
}

/// The most MIME types one offer announces.
enum size_t maxOfferTypes = 8;

/**
Whether `S` can receive a transfer (`DT2`): `chunk(id, bytes)` for each piece
and `finish(id, status)` once at the end, both `@safe nothrow`: a backend calls
them from its dispatch, through a reference that cannot check their safety.
*/
enum isDataSink(S) = is(typeof((ref S sink, TransferId id,
        scope const(ubyte)[] bytes, TransferStatus status) @safe nothrow {
    sink.chunk(id, bytes);
    sink.finish(id, status);
}));

/**
Whether `P` can supply an offer's content (`DT3`): `fill(mimeType, offset,
buffer)` writes the bytes at `offset` into `buffer` and returns how many it
wrote; 0 means the end. It is `@safe nothrow`, like a sink's methods.
*/
enum isDataProvider(P) = is(typeof((ref P provider, scope const(char)[] mime,
        ulong offset, scope ubyte[] buffer) @safe nothrow {
    size_t written = provider.fill(mime, offset, buffer);
}));

/**
A sink held by reference for a transfer's lifetime. The application keeps the
sink alive until its `finish` call (`DT2`); nothing else can be checked here.
*/
struct SinkRef
{
    private void* context;
    private void function(void*, TransferId, scope const(ubyte)[]) @safe nothrow chunk_;
    private void function(void*, TransferId, TransferStatus) @safe nothrow finish_;

    /// Refers to `sink`, which must outlive the transfer.
    static SinkRef to(S)(ref S sink) @system
    if (isDataSink!S)
    {
        // `c` is the `S*` this reference was made from, and `S`'s methods are
        // `@safe` (`isDataSink`), so these casts are the only trusted step.
        static void chunkThunk(void* c, TransferId id, scope const(ubyte)[] bytes)
            @trusted nothrow
        {
            (cast(S*) c).chunk(id, bytes);
        }

        static void finishThunk(void* c, TransferId id, TransferStatus status)
            @trusted nothrow
        {
            (cast(S*) c).finish(id, status);
        }

        return SinkRef(cast(void*) &sink, &chunkThunk, &finishThunk);
    }

    void chunk(TransferId id, scope const(ubyte)[] bytes) @safe nothrow
        => chunk_(context, id, bytes);

    void finish(TransferId id, TransferStatus status) @safe nothrow
        => finish_(context, id, status);

    bool bound() const @safe pure nothrow @nogc => chunk_ !is null;
}

/**
A provider held by reference for its offer's lifetime. The application keeps
it alive until the offer ends (`DT3`).
*/
struct ProviderRef
{
    private void* context;
    private size_t function(void*, scope const(char)[], ulong, scope ubyte[])
        @safe nothrow fill_;

    /// Refers to `provider`, which must outlive its offer.
    static ProviderRef to(P)(ref P provider) @system
    if (isDataProvider!P)
    {
        // As for `SinkRef`: the cast is the one trusted step.
        static size_t fillThunk(void* c, scope const(char)[] mime, ulong offset,
            scope ubyte[] buffer) @trusted nothrow
            => (cast(P*) c).fill(mime, offset, buffer);

        return ProviderRef(cast(void*) &provider, &fillThunk);
    }

    size_t fill(scope const(char)[] mime, ulong offset, scope ubyte[] buffer)
        @safe nothrow
        => fill_(context, mime, offset, buffer);

    bool bound() const @safe pure nothrow @nogc => fill_ !is null;
}

/**
The provider behind the whole-value `offerClipboard`: one owned copy of a
small value, served at any offset. It is the only place WSI keeps offered
bytes (`DT3`).
*/
struct ValueProvider
{
    UniqueBuffer!(ubyte, 64) bytes;

    size_t fill(scope const(char)[], ulong offset, scope ubyte[] buffer)
        @safe pure nothrow @nogc
    {
        if (offset >= bytes.length)
            return 0;
        const size_t start = cast(size_t) offset;
        const size_t n = bytes.length - start < buffer.length
            ? bytes.length - start : buffer.length;
        buffer[0 .. n] = bytes[][start .. start + n];
        return n;
    }
}

@("wsi.clipboard.valueProviderServesAnyOffset")
@safe pure nothrow @nogc
unittest
{
    ValueProvider value;
    value.bytes ~= cast(const(ubyte)[]) "hello";
    ubyte[3] buffer;
    assert(value.fill("text/plain", 0, buffer[]) == 3 && buffer == "hel");
    assert(value.fill("text/plain", 3, buffer[]) == 2 && buffer[0 .. 2] == "lo");
    assert(value.fill("text/plain", 5, buffer[]) == 0);
    static assert(isDataProvider!ValueProvider);
}

/// One live offer: its MIME types and where its bytes come from.
struct OfferRecord
{
    WindowId window;
    bool own;            /// made by this application, not another source
    ProviderRef provider; /// own offers only
    ValueProvider value;  /// the whole-value form's copy, else empty
    bool hasValue;
    InlineBuffer!(char, maxMimeType)[maxOfferTypes] types;
    ubyte typeCount;

    /// The bytes at `offset`: from the owned copy for a whole-value offer,
    /// otherwise from the provider.
    size_t fill(scope const(char)[] mime, ulong offset, scope ubyte[] buffer)
        @safe nothrow
        => hasValue ? value.fill(mime, offset, buffer)
            : provider.fill(mime, offset, buffer);

    bool offers(scope const(char)[] mime) const @safe pure nothrow @nogc
    {
        foreach (ref t; types[0 .. typeCount])
            if (t[] == mime)
                return true;
        return false;
    }
}

/// One live transfer from an offer into a sink.
struct TransferRecord
{
    OfferId offer;
    InlineBuffer!(char, maxMimeType) mime;
    SinkRef sink;
    ulong offset;
}

/**
The bookkeeping a backend embeds for its clipboard: the live offers and
transfers, each in a generational pool. Platform I/O stays in the backend;
this owns identity, MIME validation and the end-of-transfer rules.
*/
struct ClipboardState(size_t maxOffers = 4, size_t maxTransfers = 8)
{
    Pool!(OfferId, OfferRecord, maxOffers) offers;
    Pool!(TransferId, TransferRecord, maxTransfers) transfers;
    OfferId current; /// the clipboard's offer, own or foreign

    @disable this(this);

    /**
    Records a new offer. `types` must hold 1 to `maxOfferTypes` MIME types of
    at most `maxMimeType` bytes each.
    */
    WsiResult!OfferId add(WindowId window, scope const(char[])[] types, bool own)
        nothrow
    {
        if (types.length == 0 || types.length > maxOfferTypes)
            return wsiErr!OfferId(wsiError(WsiErrorKind.invalidArgument,
                WsiOperation.command,
                diagnostic: "an offer names 1 to maxOfferTypes MIME types"));
        foreach (t; types)
            if (t.length == 0 || t.length > maxMimeType)
                return wsiErr!OfferId(wsiError(WsiErrorKind.invalidArgument,
                    WsiOperation.command,
                    diagnostic: "a MIME type is empty or longer than maxMimeType"));

        OfferRecord record;
        record.window = window;
        record.own = own;
        foreach (i, t; types)
        {
            const assigned = record.types[i].assign(t);
            assert(assigned, "lengths were checked above");
        }
        record.typeCount = cast(ubyte) types.length;
        return insert(record);
    }

    /// ditto, for an offer of one MIME type.
    WsiResult!OfferId add(WindowId window, scope const(char)[] type, bool own)
        nothrow
    {
        if (type.length == 0 || type.length > maxMimeType)
            return wsiErr!OfferId(wsiError(WsiErrorKind.invalidArgument,
                WsiOperation.command,
                diagnostic: "a MIME type is empty or longer than maxMimeType"));
        OfferRecord record;
        record.window = window;
        record.own = own;
        const assigned = record.types[0].assign(type);
        assert(assigned, "the length was checked above");
        record.typeCount = 1;
        return insert(record);
    }

    private WsiResult!OfferId insert(ref OfferRecord record) nothrow
    {
        auto inserted = offers.insert(move(record));
        if (inserted.hasError)
            return wsiErr!OfferId(wsiError(WsiErrorKind.capacity,
                WsiOperation.command, diagnostic: "too many live offers"));
        OfferId id = inserted.value;
        return wsiOk(id);
    }

    /**
    Starts a transfer of `offer`'s `mime` content into `sink`. Fails with
    `staleId` for an offer that ended and `invalidArgument` for a type the
    offer does not name.
    */
    WsiResult!TransferId begin(OfferId offer, scope const(char)[] mime,
        SinkRef sink) nothrow
    {
        auto record = offers.get(offer);
        if (record is null)
            return wsiErr!TransferId(wsiError(WsiErrorKind.staleId,
                WsiOperation.command, diagnostic: "the offer has ended"));
        if (!record.offers(mime))
            return wsiErr!TransferId(wsiError(WsiErrorKind.invalidArgument,
                WsiOperation.command, diagnostic: "the offer does not name that type"));

        TransferRecord transfer;
        transfer.offer = offer;
        const assigned = transfer.mime.assign(mime);
        assert(assigned, "an offered type fits");
        transfer.sink = sink;
        auto inserted = transfers.insert(move(transfer));
        if (inserted.hasError)
            return wsiErr!TransferId(wsiError(WsiErrorKind.capacity,
                WsiOperation.command, diagnostic: "too many transfers in flight"));
        TransferId id = inserted.value;
        return wsiOk(id);
    }

    /// Ends `id` with `status`: the sink's one `finish` call, then removal.
    void end(TransferId id, TransferStatus status) nothrow
    {
        auto transfer = transfers.get(id);
        if (transfer is null)
            return;
        auto sink = transfer.sink;
        transfers.remove(id);
        sink.finish(id, status);
    }

    /// `cancelTransfer`: `staleId` once the transfer has ended (`DT2`).
    WsiResult!void cancel(TransferId id) nothrow
    {
        if (!transfers.isLive(id))
            return wsiErr!void(wsiError(WsiErrorKind.staleId,
                WsiOperation.command, diagnostic: "the transfer has ended"));
        end(id, TransferStatus.cancelled);
        return wsiOk();
    }

    /**
    Ends `offer`: every transfer still reading it fails, because its provider
    need not outlive the offer (`DT3`). Returns whether the offer was live.
    */
    bool drop(OfferId offer) nothrow
    {
        if (!offers.isLive(offer))
            return false;
        foreach (h; transfers.byLive)
            if (transfers[h].offer == offer)
                end(h, TransferStatus.failed);
        offers.remove(offer);
        if (current == offer)
            current = OfferId.init;
        return true;
    }
}

/**
The length of the longest prefix of `text` that ends on a complete UTF-8
sequence. What follows it is the start of a sequence split across chunks,
which a backend converting chunk by chunk carries into the next one.
Invalid bytes are left for the converter to reject.
*/
size_t completeUtf8Prefix(scope const(char)[] text) @safe pure nothrow @nogc
{
    size_t back;
    while (back < 3 && back < text.length && (text[$ - 1 - back] & 0xC0) == 0x80)
        ++back;
    if (back == text.length)
        return text.length;
    const lead = text[$ - 1 - back];
    const size_t need = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3
        : lead >= 0xC0 ? 2 : 1;
    return back + 1 >= need ? text.length : text.length - back - 1;
}

@("wsi.clipboard.completeUtf8PrefixStopsBeforeASplitSequence")
@safe pure nothrow @nogc
unittest
{
    assert(completeUtf8Prefix("abc") == 3);
    assert(completeUtf8Prefix("aé") == 3);            // 'é' is complete
    assert(completeUtf8Prefix("a\xC3") == 1);         // 'é' split after its lead
    assert(completeUtf8Prefix("a\xE2\x82") == 1);     // '€' missing its last byte
    assert(completeUtf8Prefix("a\xE2\x82\xAC") == 4); // '€' complete
    assert(completeUtf8Prefix("\xF0\x9F\x98") == 0);  // an astral scalar, split
    assert(completeUtf8Prefix("") == 0);
}
