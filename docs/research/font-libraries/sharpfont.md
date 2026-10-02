# SharpFont (C# / .NET binding to FreeType)

A hand-written P/Invoke binding that mirrors FreeType's public structs in C# and
wraps every handle in an `IDisposable` class — the thin-binding data point
opposite fontations' rewrite.

| Field            | Value                                                                                                            |
| ---------------- | ---------------------------------------------------------------------------------------------------------------- |
| Language         | C# (.NET Framework 4.5 / PCL `Profile111` / `net20`; `AllowUnsafeBlocks`) over native FreeType 2                 |
| License          | MIT ([`LICENSE`][license]); "based on Tao.FreeType"                                                              |
| Repository       | [`Robmaister/SharpFont`][repo]                                                                                   |
| Documentation    | [`README.md`][readme]; XML doc comments transcribed from the FreeType reference                                  |
| Category         | managed binding                                                                                                  |
| Layer(s) covered | parse · raster · outline · (shape via the separate `SharpFont.HarfBuzz` binding); no discover, no match/fallback |
| Pinned revision  | `26454a8b5b53733ff7a10de2322469b64cb75ee8` (2019-03-18, merge of PR 130; shallow clone, this is the last commit) |

## Overview

### What it solves

SharpFont exposes "the full public API and not just the basic methods needed to
render simple text", converting FreeType error codes to exceptions and `out`
parameters to return values ([`README.md`][readme]). The managed surface is
190 `DllImport` declarations in [`FT.Internal.cs`][ft-internal] against a
library named `freetype6`, remapped per OS by a Mono `dllmap`
([`SharpFont.dll.config`][dllconfig]). Native binaries come from a separate
`SharpFont.Dependencies` submodule ([`.gitmodules`][gitmodules]) — empty in the
clone — and the NuGet package depends on it ([`SharpFont.nuspec`][nuspec],
version `4.0.1`).

### Design philosophy

> The error codes that most FreeType methods return are converted to
> exceptions. Since the return values are no longer error codes, methods with a
> single `out` parameter are returned instead. Most methods are instance
> methods instead of static methods.

— [`README.md`][readme]. Nothing in FreeType's object model is redesigned;
ownership follows FreeType's, expressed in .NET idiom.

## How it works

Every FreeType record has a `[StructLayout(LayoutKind.Sequential)]` twin under
`Internal/` — `FaceRec`, `GlyphSlotRec`, `OutlineRec`, `SizeRec`, … — with
`FT_Long` aliased to `IntPtr` so field widths follow the platform
([`FaceRec.cs`][facerec]). A wrapper holds the native pointer plus a **marshalled
copy** of the struct; setting `Reference` re-reads it:

```csharp
				base.Reference = value;
				rec = PInvokeHelper.PtrToStructure<FaceRec>(value);
```

— [`Face.cs`][face]. Properties then read from `rec`, and sub-objects are
re-wrapped on every access (`Glyph => new GlyphSlot(rec.glyph, this,
parentLibrary)`), with `PInvokeHelper.AbsoluteOffsetOf<T>(ptr, "fieldName")`
computing the address of an embedded struct such as `outline` or `bitmap`
([`GlyphSlot.cs`][glyphslot], [`PInvokeHelper.cs`][pinvoke]). The copy is a
snapshot: a `Face` constructed before `FT_Load_Glyph` still reads correct
`glyph` pointers only because that pointer is stable; any field FreeType
mutates after the snapshot is stale until `Reference` is reassigned.

## Analysis spine

### 1. Layering and ownership

FreeType's three-level model — `Library` → `Face` → `FTSize`/`GlyphSlot` — is
reproduced as parent/child lists. `Library` keeps `List<Face> childFaces`,
`childGlyphs`, `childOutlines`, `childStrokers`, `childManagers`
([`Library.cs`][library]); `Face` keeps `childSizes`. Disposal cascades:

```csharp
				foreach (FTSize s in childSizes)
					s.Dispose();
				childSizes.Clear();
				FT.FT_Done_Face(base.Reference);
				if (!parentLibrary.IsDisposed)
					parentLibrary.RemoveChildFace(this);
				base.Reference = IntPtr.Zero;
				rec = new FaceRec();
				if (memoryFaceHandle.IsAllocated)
					memoryFaceHandle.Free();
```

— [`Face.cs`][face]. A memory face pins the caller's `byte[]` with
`GCHandle.Alloc(file, GCHandleType.Pinned)` for the face's whole lifetime —
FreeType borrows, so the binding must prevent the GC from moving the array.
Finalizers back every `Dispose`; every property throws
`ObjectDisposedException` after disposal. Thread-safety is FreeType's (none per
`FT_Face`). The error model is `FreeTypeException(Error)`; the 4.0.1 notes say
error checking was removed from `Dispose()` "as they should not throw".

### 2. Face loading and table access

`new Face(library, path, faceIndex)`, `new Face(library, byte[] file,
faceIndex)` and `new Face(library, IntPtr bufferPtr, length, faceIndex)` map to
`FT_New_Face` / `FT_New_Memory_Face`; `FaceCount`/`FaceIndex` surface
collections. Raw tables: `GetSfntTable(SfntTag)` returns a boxed typed struct
and `LoadSfntTable(tag, offset, IntPtr buffer, ref uint length)` is
`FT_Load_Sfnt_Table` verbatim — the caller allocates ([`Face.cs`][face],
[`FT.Internal.cs`][ft-internal]). Laziness is FreeType's; the binding adds
nothing and refuses nothing.

### 3. Shaping

Not in SharpFont. The companion `SharpFont.HarfBuzz` binds `hb_ft_font_create`,
`hb_shape`, buffers and `GlyphInfo`/`GlyphPosition`
([`HB.Internal.cs`][hb-internal]) against `libharfbuzz-0.dll`; a `Face.Reference`
handle crosses into it. Script/language/feature arrays and cluster mapping are
whatever HarfBuzz exposes — the binding is a dozen imports.

### 4. Variation and instances

Bound, not interpreted: `GetMMVar()` → `MMVar` with `VarAxis`/`VarNamedStyle`
mirrors, `SetVarDesignCoordinates(long[])`, `SetMMDesignCoordinates(long[])`
([`Face.cs`][face]; [`MultipleMasters/`][mmvar]). Coordinates are FreeType
16.16 `long`s handed through; the binding does not know `avar` or normalised
space exists. There is no `FT_Get_Var_Blend_Coordinates` of the newer API —
the surface is frozen at the FreeType of circa 2016.

### 5. Rasterization and outlines

`LoadGlyph(glyphIndex, LoadFlags, LoadTarget)` and `GlyphSlot.RenderGlyph(RenderMode)`
drive FreeType's rasterizer; `LcdFilter`, `LoadTarget` (mono/light/LCD) and
`FTBitmap` expose its modes. **Outline access is two-way.** Array form:
`Outline.Points` (`FTVector[]`), `Tags` (`byte[]`), `Contours` (`short[]`),
each a `Marshal.Read*` loop copying out of native memory
([`Outline.cs`][outline]). Callback form:

```csharp
	public delegate int MoveToFunc(ref FTVector to, IntPtr user);
	public delegate int ConicToFunc(ref FTVector control, ref FTVector to, IntPtr user);
```

— [`OutlineFuncs.cs`][outlinefuncs]; `OutlineFuncs` turns four delegates into
function pointers with `Marshal.GetFunctionPointerForDelegate`, keeps the
delegates alive as fields (the 4.0.1 notes record "Fixed memory pinning bugs in
OutlineFuncs"), and `Outline.Decompose` passes the `OutlineFuncsRec` by `ref`
to `FT_Outline_Decompose`. Units are FreeType's: 26.6 pixels after
`SetCharSize`, font units with `LoadFlags.NoScale`. No atlas, no GPU, no
colour-glyph helper beyond what `FT_Load_Glyph` with `LoadFlags.Color` returns.

### 6. Metrics and measurement

`Face.Ascender`/`Descender`/`Height`/`UnitsPerEM`/`UnderlinePosition` read the
`FaceRec` fields FreeType already derived (hhea with OS/2 fallbacks, decided in
C). `SizeMetrics` mirrors `FT_Size_Metrics` in 26.6; `GlyphSlot.Advance` is an
`FTVector26Dot6`, `LinearHorizontalAdvance` a `Fixed16Dot16`. The fixed-point
structs are where layout hazards live: `Fixed26Dot6` is a `struct` over `int`
with implicit conversions from `short`/`int`/`float`/`double`/`decimal`
([`Fixed26Dot6.cs`][fixed]), while `FTVector26Dot6` stores `IntPtr x, y` to
match `FT_Pos` (a `long`) and narrows with `(int)x` on read
([`FTVector26Dot6.cs`][vec266]) — correct on LP64 only while values fit 32 bits,
and the reason the README needs a FreeType patch for 64-bit Windows, where
`long` is 32-bit and struct-return conventions diverge
([`README.md`][readme]). `FT_Get_Kerning` is bound with `out FTVector26Dot6`
([`FT.Internal.cs`][ft-internal]).

### 7. Discovery, matching and fallback

Absent, by scope: FreeType has no font database and neither does the binding.
No fontconfig, CoreText or DirectWrite import exists in the tree. A consumer
pairs SharpFont with its own enumeration, which is how every FreeType-only
stack ends up (compare [`./crossfont.md`](./crossfont.md), which adds fontconfig
on Linux).

## What it teaches `sparkles:font`

- **Mirror structs are a maintenance contract with a specific FreeType ABI.**
  Thirty `*Rec.cs` files encode field order and `FT_Long` width by hand; any
  upstream struct change is silent corruption. ImportC reading `freetype.h`
  removes exactly this class of bug — the strongest argument for ImportC over a
  hand binding, and the one SharpFont's stall illustrates.
- **Pin what C borrows.** `GCHandle` for memory faces and delegates kept alive
  for `FT_Outline_Decompose` are the managed analogue of D's `scope`/`@trusted`
  boundary; a D API over FreeType must own or pin the buffer for the `FT_Face`
  lifetime, and `toTempStringz` is not enough for `FT_New_Face`.
- **Snapshot-copy wrappers go stale.** Reading native fields through a cached
  copy is cheap but desynchronises after any mutating call; prefer reading
  through the pointer, or re-snapshot after every `FT_*` call that writes.
- **Two outline forms is the right default**: an array view for inspectors and
  a sink for path builders, both over the same `FT_Outline`.
- **A binding inherits the native library's layering wholesale** — library →
  face → size → slot, 26.6 units, error codes — and cannot offer a better
  ownership story than the C API without a layer above it.

## Strengths

- Near-complete surface (190 imports: caching subsystem, strokers, TrueType and
  Type 1 format APIs, MM/Var, `FT_Load_Sfnt_Table`) with transcribed docs.
- Deterministic cleanup via cascading `Dispose` plus finalizers.
- Honest about the ABI edge: the 64-bit Windows patch is documented.

## Weaknesses

- Unmaintained since 2019-03-18; frozen at a circa-2016 FreeType API.
- `IntPtr`-as-`FT_Long` with `(int)` narrowing; platform-conditional layouts.
- Snapshot `rec` copies; per-access re-wrapping allocates.
- Native dependency distribution via a submodule of prebuilt binaries.
- No discovery, no shaping (separate binding), no abstraction above FreeType.

## Key design decisions and trade-offs

| Decision                                        | Rationale                                             | Trade-off                                                              |
| ----------------------------------------------- | ----------------------------------------------------- | ---------------------------------------------------------------------- |
| Hand-mirrored `Sequential` structs              | Zero-copy field reads, no native shim to build        | Silent breakage on any FreeType layout change; 64-bit hazards          |
| `FT_Long` = `IntPtr`                            | One source for 32/64-bit Unix                         | Wrong on Win64 (`long` is 32-bit) without a FreeType patch             |
| Exceptions for `FT_Error`                       | Idiomatic .NET                                        | Every call allocates on failure; no `Expected`-style flow              |
| Parent/child lists + `IDisposable` + finalizers | Deterministic native cleanup                          | Bookkeeping on every create/dispose; enumeration-during-dispose guards |
| `GCHandle`-pinned memory faces                  | FreeType borrows, GC moves                            | Array pinned for the face's whole life                                 |
| Delegates kept alive for outline callbacks      | `FT_Outline_Decompose` needs stable function pointers | Easy to get wrong — the 4.0.1 "pinning bugs" fix                       |

## Sources

All paths verified with `git -C $REPOS/SharpFont cat-file -e HEAD:<path>`.

- [`README.md`][readme], [`LICENSE`][license], [`Build/NuGet/SharpFont.nuspec`][nuspec], [`.gitmodules`][gitmodules], [`Source/SharpFont.dll.config`][dllconfig].
- [`Source/SharpFont/FT.Internal.cs`][ft-internal] — the 190 `DllImport`s, `freetype6` name.
- [`Source/SharpFont/Library.cs`][library], [`Face.cs`][face], [`GlyphSlot.cs`][glyphslot], [`Outline.cs`][outline], [`OutlineFuncs.cs`][outlinefuncs].
- [`Source/SharpFont/Internal/FaceRec.cs`][facerec], [`PInvokeHelper.cs`][pinvoke].
- [`Source/SharpFont/Fixed26Dot6.cs`][fixed], [`FTVector26Dot6.cs`][vec266].
- [`Source/SharpFont/MultipleMasters/MMVar.cs`][mmvar].
- [`Source/SharpFont.HarfBuzz/HB.Internal.cs`][hb-internal].

<!-- References -->

[repo]: https://github.com/Robmaister/SharpFont
[license]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/LICENSE
[readme]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/README.md
[nuspec]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Build/NuGet/SharpFont.nuspec
[gitmodules]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/.gitmodules
[dllconfig]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont.dll.config
[ft-internal]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/FT.Internal.cs
[library]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/Library.cs
[face]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/Face.cs
[glyphslot]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/GlyphSlot.cs
[outline]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/Outline.cs
[outlinefuncs]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/OutlineFuncs.cs
[facerec]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/Internal/FaceRec.cs
[pinvoke]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/PInvokeHelper.cs
[fixed]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/Fixed26Dot6.cs
[vec266]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/FTVector26Dot6.cs
[mmvar]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont/MultipleMasters/MMVar.cs
[hb-internal]: https://github.com/Robmaister/SharpFont/blob/26454a8b5b53733ff7a10de2322469b64cb75ee8/Source/SharpFont.HarfBuzz/HB.Internal.cs
