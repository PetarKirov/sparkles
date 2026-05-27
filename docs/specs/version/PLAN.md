# Overhaul Plan: Design by Introspection Semantic Versioning

Overhauling a core semantic versioning library to use a Design by Introspection (DbI), zero-allocation, bitpacked architecture is an ambitious and incredibly rewarding systems engineering task. Since this will fundamentally change how `sparkles/semver` handles memory and comparisons, the transition needs to be phased carefully to avoid breaking downstream dependency resolution logic.

Here is the complete, revised implementation plan to execute the overhaul of `sparkles/semver/core.d`.

## Phase 1: Establish the Semantic Foundations (UDAs & Metadata)

Before writing any actual logic, define the vocabulary the DbI engine will use to understand the policies. This completely decouples the engine from hardcoded SemVer concepts.

- **Define Core Type Selector:** Implement the `GetCoreType!(size_t)` template to map layout sizes (1, 2, 4, 8, 16 bytes) to D's native unsigned integers (`ubyte`, `ushort`, `uint`, `ulong`) and `core.int128.Cent`.
- **Define Introspection UDAs:**

```d
struct Component { int printOrder; }

struct WidthTracker { string target; }

enum InternalFlag;
```

## Phase 2: Build the Fallback Layer (SSO String)

The fast-path will handle 95% of workloads, but the SSO string is required for strict SemVer 2.0.0 compliance (pre-releases and build metadata).

- **Implement `SsoString` Struct:**
  - Size must be exactly 24 bytes (on 64-bit systems).
  - Create the union overlay: 23-byte `char[23]` inline array vs. standard heap-allocated `string` slice.
  - Implement `@safe pure nothrow @nogc` lexicographical `opCmp`.
  - Implement `toString()` that seamlessly returns the inline buffer or the heap slice.

## Phase 3: The DbI Engine Core (`Version(Layout)`)

This is the heart of the overhaul. Replace the existing `SemVer` struct with the generic template struct.

- **Memory Overlay:**
  - Define `alias CoreType = GetCoreType!(Layout.sizeof);`.
  - Create the core `union { Layout core; CoreType packed; }`.
  - Conditionally inject `SsoString` metadata using `static if (Layout.hasSsoString)`.
- **CTFE Validation (The "Safety Net"):**
  - Use `static foreach` over `__traits(allMembers, Layout)`.
  - Assert all semantic fields are native bitfields via `__traits(isBitfield)`.
  - Crucially, assert that any member tagged with `@InternalFlag` is positioned exactly at the MSB (using `__traits(getBitfieldOffset)` and `__traits(getBitfieldWidth)`) to guarantee integer sorting precedence.

## Phase 4: Hardware-Accelerated Operations

Implement the primitives that will make `sparkles` dependency resolution lightning-fast.

- **`opCmp` (The Fast-Path):**
  - Implement standard `<` and `>` for `CoreType` <= 8 bytes.
  - Implement `core.int128.ult` and `core.int128.ugt` exclusively for `Cent`.
  - Implement the tie-breaker: if integers tie, and `Layout.hasSsoString` is true, return `metadata.opCmp`.
- **`truncateTo!(string comp)()`:**
  - Write a CTFE function that calculates a bitmask zeroing out everything physically located "below" the target component.
  - Apply the mask using native bitwise `&` (or `core.int128.and` for `Cent`).
- **Dynamic `toString()`:**
  - Gather all members tagged with `@Component`.
  - Sort them at compile-time using the `printOrder` UDA.
  - For each component, check if a corresponding `@WidthTracker` exists to dictate `format("%0*d", width, value)` vs standard `format("%d", value)`.

## Phase 5: Define the Concrete Layouts

Replace the old `sparkles` version representations with the new DbI layouts.

- **Standard SemVer:** Define `SemVerLayout` (64-bit, 15/24/24 bits, MSB flag, has SSO) and alias it to `SemVer`.
- **Dlang Versioning:** Define `DlangLayout` (64-bit, 15/20/20 bits, with 4-bit `@WidthTracker` fields for minor and patch, has SSO) and alias it to `DlangVer`.
- **(Optional) Tiny Version:** Define `TinyLayout` (32-bit, no SSO) for ultra-compact internal dependency tracking.

## Phase 6: Migration Strategy for `sparkles`

Since `sparkles` likely relies heavily on semantic versions for package resolution, the downstream code must be adapted to the new paradigm.

- **Remove String-Parsing Bottlenecks:** Update the parser to ingest versions directly into the bitfields. Do not instantiate standard `string`s unless the pre-release tag is detected.
- **Refactor Ranges/Predicates:** Scan the `sparkles` codebase for places where versions are grouped or filtered (e.g., `tuple(v.major, v.minor)`). Replace these with the zero-cost `v.truncateTo!"minor"().packed` integer comparisons.
