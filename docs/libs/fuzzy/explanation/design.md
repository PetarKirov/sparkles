# Why admission and ranking are separate

The central design choice is that scoring cannot decide whether a candidate
matches. Local alignment is intentionally willing to abandon a weak prefix;
using its best traceback as an admission oracle therefore loses valid long-gap
subsequences and makes highlights disagree with filtering.

`sparkles:fuzzy` instead admits a term through an exact, bounded
needle-deletion cursor DP. The canonical witness minimizes deletions, then the
ending candidate position, then source-byte positions. The same witness owns
the scoring window, filename containment, offsets, and highlight ranges.
Smith–Waterman only orders already-admitted candidates. Long candidates use a
direct witness score, retaining exact admission and positions.

This separation also shapes ownership. Text analysis preserves the original
byte interval through normalization, expansion, composition, and malformed
UTF-8. A worker borrows immutable query and corpus arenas and owns its scratch.
The fuzzy package stays pure and allocation-free; the application can then add
a clock, atomics, a persistent CPU pool, and disk history without weakening the
compute kernel or hiding those lifetimes.
