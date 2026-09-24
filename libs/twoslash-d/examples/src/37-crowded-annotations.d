module sample;

import std.algorithm.iteration : filter, map;
import std.array : array, split;
// @errors: undefined{{_}}identifier compile{{_}}time
// ---cut---
/// The nth space-separated word of `text`.
string word(string text, size_t n) => text.split(' ')[n];

/// Four annotations on one line. The labels peel off right to left — the
/// rightmost first, the leftmost last — and a connector keeps every anchor
/// attached to the token it describes until its own label is drawn.
int[] loudest(int[] samples, int floor, int scale)
{
    auto loud = samples.filter!(x => x > floor).map!(x => x * scale).array;
//       ^?
//                ^?
//                         ^?
//                                              ^?
    return loud;
}

/// Two anchors far enough apart that both labels fit on one row: vertical
/// space is the scarce resource on a crowded line, so a pair that provably
/// does not overlap costs one row, not two.
string pick(size_t index)
{
    auto tail = word("the quick brown fox jumps over the lazy dog", index);
//       ^?
//                                                                  ^?
    return tail;
}

/// Three anchors of three different kinds on one line — two queries and a
/// completion list — each connector drawn in the brand colour of the label it
/// is still carrying, and the list keeping its guides beside every candidate.
auto opacity = alpha;
//                  ^|
//   ^?
//             ^?

/// A diagnostic and a query on one line, at different columns: each connector
/// carries its own label's brand colour, so the red one is the error's and the
/// muted one is the query's.
int broken = missing + alpha;
//  ^?

/// D reports a CTFE failure as the error plus a `called from here:` chain.
/// Each continuation is its own row, so a multi-line diagnostic stays inside
/// the art instead of tearing it open.
string letters = "abcdef";
ubyte head(string s) => cast(ubyte) s[0];
enum first = head(letters);
//   ^?
//                ^?

/// Alpha channel opacity, 0 through 255.
enum ubyte alpha = 255;
/// The Latin alphabet, lowercase.
enum string alphabet = "abcdefghijklmnopqrstuvwxyz";
