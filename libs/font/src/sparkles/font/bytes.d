/**
Bounds checks and big-endian integer reads (FTP17).

Every read of font data goes through `fits` first and then one of the `be*`
readers, whose preconditions only restate a check the caller already made.
Offsets are `ulong`, so an offset plus a length taken from a font cannot wrap.
*/
module sparkles.font.bytes;

@safe pure nothrow @nogc:

/// Whether `size` bytes at `offset` lie inside a buffer of `length` bytes.
bool fits(size_t length, ulong offset, ulong size)
    => offset <= length && size <= length - offset;

/// The `size` bytes at `offset`; callers check `fits` first.
inout(ubyte)[] slice(return scope inout(ubyte)[] data, ulong offset, ulong size)
in (fits(data.length, offset, size))
    => data[cast(size_t) offset .. cast(size_t)(offset + size)];

/// An unsigned 16-bit big-endian integer at `offset`.
ushort be16(scope const(ubyte)[] data, size_t offset)
in (fits(data.length, offset, 2))
    => cast(ushort)((data[offset] << 8) | data[offset + 1]);

/// A signed 16-bit big-endian integer at `offset`.
short bes16(scope const(ubyte)[] data, size_t offset)
in (fits(data.length, offset, 2))
    => cast(short) be16(data, offset);

/// An unsigned 24-bit big-endian integer at `offset`.
uint be24(scope const(ubyte)[] data, size_t offset)
in (fits(data.length, offset, 3))
    => (uint(data[offset]) << 16) | (uint(data[offset + 1]) << 8) | data[offset + 2];

/// An unsigned 32-bit big-endian integer at `offset`.
uint be32(scope const(ubyte)[] data, size_t offset)
in (fits(data.length, offset, 4))
    => (uint(data[offset]) << 24) | (uint(data[offset + 1]) << 16)
        | (uint(data[offset + 2]) << 8) | data[offset + 3];

/// A signed 32-bit big-endian integer at `offset`.
int bes32(scope const(ubyte)[] data, size_t offset)
in (fits(data.length, offset, 4))
    => cast(int) be32(data, offset);

///
@("bytes.readsAndBounds")
unittest
{
    static immutable ubyte[6] data = [0x12, 0x34, 0xFF, 0xFE, 0x00, 0x01];
    assert(be16(data[], 0) == 0x1234);
    assert(bes16(data[], 2) == -2);
    assert(be32(data[], 2) == 0xFFFE_0001);
    assert(be24(data[], 0) == 0x12_34FF);
    assert(fits(6, 4, 2) && !fits(6, 5, 2) && !fits(6, 7, 0));
    assert(!fits(6, ulong.max, 2) && !fits(6, 2, ulong.max));
    assert(slice(data[], 2, 2) == [0xFF, 0xFE]);
}
