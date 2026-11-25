/// The tree checksum every builder folds its nodes into, in pre-order.
module treehash;

ulong treeHash(ulong h, scope const(char)[] kind, uint w, uint hgt, uint children)
    @safe pure nothrow @nogc
{
    foreach (c; kind)
        h = (h ^ c) * 0x100000001b3;
    const uint[3] vs = [w, hgt, children];
    foreach (v; vs)
        h = (h ^ v) * 0x100000001b3;
    return h;
}
