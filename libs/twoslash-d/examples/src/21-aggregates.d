module sample;
// ---cut---
interface Sized { size_t byteSize() const; } /// Reports its own size in bytes.
/// A named slice of bytes.
struct Chunk
{
    string name;  /// Human-readable label.
    ubyte[] data; /// The payload.
    size_t byteSize() const => data.length;
}

final class Pool : Sized
{
    Chunk[] chunks;
//  ^?
    override size_t byteSize() const => chunks.length * Chunk.sizeof;
    //              ^?
}
