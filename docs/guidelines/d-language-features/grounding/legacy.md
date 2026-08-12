# Grounding ledger — Legacy constructs still worth knowing

> Not published. Do not link to it from the guide.

Pin: `351dd6d91bfed604b473c4dedd4b5fdf262c3629`.

Framing: removed features are hard errors; deprecated warn — official deprecate table.
The table is “still compile silently but better modern form”.

| #   | Claim (short)                                              | Type     | Versions claimed | Source                                                            | Status |
| --- | ---------------------------------------------------------- | -------- | ---------------- | ----------------------------------------------------------------- | ------ |
| 1   | Framing: use deprecate.html for removed/deprecated         | fact     | —                | https://dlang.org/deprecate.html (secondary 🌐)                   | 🌐     |
| 2   | Expression contracts instead of `in { }`/`out { }` + `do`  | fact     | [2.081]          | `2.081.0.dd` § expression-based contracts; `body` dep 2.097       | ✓      |
| 3   | Copy ctor instead of postblit                              | fact     | [2.086]          | DIP1018 copy constructors                                         | ✓      |
| 4   | Postblit still legal (silent compile)                      | behavior | —                | Still compiles; deprecate path for interactions, not full removal | ≈      |
| 5   | `AliasSeq` instead of `TypeTuple`                          | fact     | [2.068]          | `2.068.0.dd` TypeTuple → AliasSeq rename                          | ✓      |
| 6   | `static foreach` / alias assignment vs recursive templates | fact     | [2.076]→[2.098]  | static foreach 2.076; alias assignment 2.098                      | ✓      |
| 7   | Hex strings / `import()` vs hexString + casts              | fact     | [2.108]→[2.110]  | hexstring-cast 2.108; import-exp-hexstring 2.110                  | ✓      |
| 8   | Named arguments for struct literals vs positional          | fact     | [2.108]          | `2.108.0.dd` § `dmd.named-arguments` (struct/union literals)      | ✓      |
