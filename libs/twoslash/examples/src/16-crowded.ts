// Crowded lines: several annotations anchored to one line of code. Each is a
// showcase for the connected below-line layout — a shared marker row, then the
// labels peeled off right to left with a connector per anchor still owed one.

const readings = [3, 7, 11]

// Four anchors. The rightmost label is drawn first and the leftmost last, so a
// connector only ever runs down past anchors whose labels are still to come.
const loud = readings.filter(x => x > 3).map(x => x * 10).join(", ")
//    ^?
//           ^?
//                    ^?
//                                       ^?

// Two anchors far enough apart that both labels fit on one row: vertical space
// is the scarce resource on a crowded line, so a pair that provably does not
// overlap costs one row, not two.
const tail = "the quick brown fox jumps over the lazy dog".split(" ").at(-1)
//    ^?
//                                                                    ^?

// Three anchors of two kinds — two queries and a completion list — each
// connector in the brand colour of the label it is still carrying, and the
// list keeping its guides beside every candidate.

const scale = { linear: 1, logarithmic: 2 }
const chosen = scale.linear
//                   ^|
//    ^?
//             ^?
