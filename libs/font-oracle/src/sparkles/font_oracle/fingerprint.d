/**
What a recorded golden names a face by: a digest of the tables a shaper
reads, so a rebuild that changes nothing else keeps its goldens.
*/
module sparkles.font_oracle.fingerprint;

import std.algorithm : sort;
import std.digest : LetterCase, toHexString;
import std.digest.sha : SHA256;

import sparkles.font : DirectoryRecord, openFace, Tag;

/**
The SHA-256 of face `index` of `file` over every table but `name`, in tag
order, with `head.checkSumAdjustment` zeroed (it sums the whole file).

`name` is left out because a build may write it differently while every
other byte stays put: the bundle's Maple Mono build stores its unreferenced
stylistic-set names (IDs 256 to 266) in an order that changes from one
build to the next, on Linux and macOS alike.
*/
string shapingFingerprint(scope const(ubyte)[] file, uint index = 0) @safe
{
    const face = openFace(file, index).value;
    auto records = new DirectoryRecord[face.tableCount];
    foreach (i, ref r; records)
        r = face.record(i);
    records.sort!((a, b) => a.tag.value < b.tag.value);

    SHA256 sha;
    foreach (r; records)
    {
        if (r.tag == Tag("name"))
            continue;
        const ubyte[8] header = [
            r.tag.value >> 24, r.tag.value >> 16 & 0xFF, r.tag.value >> 8 & 0xFF, r.tag.value & 0xFF,
            r.length >> 24, r.length >> 16 & 0xFF, r.length >> 8 & 0xFF, r.length & 0xFF,
        ];
        sha.put(header[]);
        const data = face.table(r.tag).value;
        if (r.tag == Tag("head") && data.length >= 12)
        {
            static immutable ubyte[4] zero;
            sha.put(data[0 .. 8]);
            sha.put(zero[]);
            sha.put(data[12 .. $]);
        }
        else
            sha.put(data);
    }
    return toHexString!(LetterCase.lower)(sha.finish()).idup;
}
