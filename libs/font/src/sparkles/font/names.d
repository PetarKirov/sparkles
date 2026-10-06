/**
The `name` table: records and their text (FTP8, FTP28, FTP29).

Records are enumerated with their identifiers and raw bytes; a record whose
string lies outside the storage area is an error entry while the others
stay readable (FTA11). Text decodes into caller storage after a measuring
call, validating the whole record before writing: UTF-16BE through base's
byte-order adapter (FTA15), Mac Roman through its table.
*/
module sparkles.font.names;

import sparkles.base.text.utf : encodeScalar, scalarUnits, UtfMode, UtfStatus;
import sparkles.base.text.utf16 : UtfConversionErrorCode;
import sparkles.base.text.utf16_bytes : ByteOrder, measureUtf16BytesToUtf8, utf16BytesToUtf8;

import sparkles.font.bytes : be16, fits, slice;
import sparkles.font.errors : FontError, FontErrorKind, FontLimit, FontResult, fontErr, fontOk, Tag, tableError;
import sparkles.font.face : Face;
import sparkles.font.mac_roman : macRomanToUnicode;

@safe pure nothrow @nogc:

private enum Tag nameTag = Tag("name");

/// How a record's text is encoded, from its platform, encoding and language.
enum NameEncoding : ubyte
{
    utf16be,
    macRoman,
    unsupported,
}

/// The encoding of a record (FTP29).
NameEncoding nameEncoding(ushort platformID, ushort encodingID, ushort languageID)
{
    if (platformID == 0 || (platformID == 3 && (encodingID == 0 || encodingID == 1 || encodingID == 10)))
        return NameEncoding.utf16be;
    // Mac Roman, except its Icelandic, Turkish, Croatian and Romanian variants.
    if (platformID == 1 && encodingID == 0 && languageID != 15 && languageID != 17
        && languageID != 18 && languageID != 37)
        return NameEncoding.macRoman;
    return NameEncoding.unsupported;
}

/// One `name` record (FTP28).
struct NameRecord
{
    @safe pure nothrow @nogc:

    ushort platformID, encodingID, languageID, nameID;
    /// The record's raw string bytes, borrowed from the face.
    const(ubyte)[] bytes;
    /// In a version-1 table, the language tag a `languageID` of 0x8000 or above names.
    bool hasLanguageTag;
    /// That tag's raw UTF-16BE bytes.
    const(ubyte)[] languageTag;
    private ulong tableStart_;
    private ulong stringOffset_; // from the table start

    /// How `bytes` are encoded.
    NameEncoding encoding() const scope => nameEncoding(platformID, encodingID, languageID);

    /// The UTF-8 length of the decoded text, or the error decoding would return (FTP29).
    FontResult!size_t decodedLength() const scope
    {
        final switch (encoding)
        {
            case NameEncoding.utf16be:
            {
                const m = measureUtf16BytesToUtf8(bytes, ByteOrder.bigEndian);
                if (m.hasError)
                    return fontErr!size_t(encodingError(m.error.offset));
                return fontOk!size_t(m.value.payload);
            }
            case NameEncoding.macRoman:
            {
                size_t length;
                foreach (b; bytes)
                    length += scalarUnits!char(macRomanToUnicode(b));
                return fontOk(length);
            }
            case NameEncoding.unsupported:
                return fontErr!size_t(tableError(FontErrorKind.unsupportedCapability, nameTag,
                    tableStart_, stringOffset_));
        }
    }

    /**
    Writes the text into `destination` and returns the written slice. The
    record is validated first; on any error `destination` is unchanged, and a
    destination shorter than `decodedLength` is `limitExceeded`.
    */
    FontResult!(char[]) decode(return scope char[] destination) const scope
    {
        const length = decodedLength();
        if (length.hasError)
            return fontErr!(char[])(length.error);
        if (destination.length < length.value)
            return fontErr!(char[])(FontError(FontErrorKind.limitExceeded, nameTag,
                tableStart_ + stringOffset_, stringOffset_, FontLimit.none));
        if (encoding == NameEncoding.utf16be)
        {
            // Validated and measured above, so the conversion succeeds.
            const written = utf16BytesToUtf8(bytes, ByteOrder.bigEndian, destination);
            assert(written.hasValue);
            return fontOk(destination[0 .. written.value]);
        }
        size_t at;
        foreach (b; bytes)
        {
            const r = encodeScalar(macRomanToUnicode(b), destination[at .. $]);
            assert(r.status == UtfStatus.ok);
            at += r.written;
        }
        return fontOk(destination[0 .. at]);
    }

    /// An `invalidEncoding` error at byte `offset` of the string.
    private FontError encodingError(ulong offset) const scope
        => tableError(FontErrorKind.invalidEncoding, nameTag, tableStart_, stringOffset_ + offset);
}

/// The `name` table, versions 0 and 1 (FTP23, FTP28).
struct NameTable
{
    @safe pure nothrow @nogc:

    ushort version_, count;
    /// Version 1: the number of language-tag records.
    ushort langTagCount;
    private const(ubyte)[] data_;
    private ulong start_;
    private ushort storageOffset_;

    /// The records, a random-access range of results.
    NameRecords records() const return scope => NameRecords(this, 0, count);

    /// Record `i`, `i < count`: a `badOffset` entry when its string lies outside storage.
    FontResult!NameRecord record(size_t i) const return scope
    in (i < count)
    {
        const at = 6 + 12 * i;
        NameRecord r;
        r.platformID = be16(data_, at);
        r.encodingID = be16(data_, at + 2);
        r.languageID = be16(data_, at + 4);
        r.nameID = be16(data_, at + 6);
        const length = be16(data_, at + 8);
        r.stringOffset_ = ulong(storageOffset_) + be16(data_, at + 10);
        r.tableStart_ = start_;
        if (!fits(data_.length, r.stringOffset_, length))
            return fontErr!NameRecord(tableError(FontErrorKind.badOffset, nameTag, start_, at + 10));
        r.bytes = slice(data_, r.stringOffset_, length);
        if (version_ == 1 && r.languageID >= 0x8000)
        {
            const tag = r.languageID - 0x8000u;
            if (tag >= langTagCount)
                return fontErr!NameRecord(tableError(FontErrorKind.indexOutOfRange, nameTag, start_, at + 4));
            const tagAt = 6 + 12UL * count + 2 + 4UL * tag;
            const tagLength = be16(data_, cast(size_t) tagAt);
            const tagOffset = ulong(storageOffset_) + be16(data_, cast(size_t) tagAt + 2);
            if (!fits(data_.length, tagOffset, tagLength))
                return fontErr!NameRecord(tableError(FontErrorKind.badOffset, nameTag, start_, tagAt + 2));
            r.hasLanguageTag = true;
            r.languageTag = slice(data_, tagOffset, tagLength);
        }
        return fontOk(r);
    }
}

/// The records of a `name` table.
struct NameRecords
{
    @safe pure nothrow @nogc:

    private NameTable table_;
    private size_t front_, back_;

    bool empty() const scope => front_ >= back_;
    size_t length() const scope => back_ - front_;
    FontResult!NameRecord front() const return scope => table_.record(front_);
    FontResult!NameRecord back() const return scope => table_.record(back_ - 1);
    FontResult!NameRecord opIndex(size_t i) const return scope => table_.record(front_ + i);
    void popFront() scope { ++front_; }
    void popBack() scope { --back_; }
    NameRecords save() return scope => this;
}

/// The face's `name` table (FTP23).
FontResult!NameTable name(return scope const Face face)
{
    auto t = face.table(nameTag);
    if (t.hasError)
        return fontErr!NameTable(t.error);
    const start = face.record(face.find(nameTag)).offset;
    const d = t.value;
    if (d.length < 6)
        return fontErr!NameTable(tableError(FontErrorKind.truncated, nameTag, start, d.length));
    NameTable n;
    n.version_ = be16(d, 0);
    if (n.version_ > 1)
        return fontErr!NameTable(tableError(FontErrorKind.unsupportedVersion, nameTag, start, 0));
    n.count = be16(d, 2);
    n.storageOffset_ = be16(d, 4);
    if (!fits(d.length, 6, 12UL * n.count))
        return fontErr!NameTable(tableError(FontErrorKind.truncated, nameTag, start, 6));
    if (n.version_ == 1)
    {
        const tagsAt = 6 + 12UL * n.count;
        if (!fits(d.length, tagsAt, 2))
            return fontErr!NameTable(tableError(FontErrorKind.truncated, nameTag, start, tagsAt));
        n.langTagCount = be16(d, cast(size_t) tagsAt);
        if (!fits(d.length, tagsAt + 2, 4UL * n.langTagCount))
            return fontErr!NameTable(tableError(FontErrorKind.truncated, nameTag, start, tagsAt + 2));
    }
    n.data_ = d;
    n.start_ = start;
    return fontOk(n);
}
