---
status: accepted
owner: sparkles:math
reviewed: 2026-10-21
---

# `sparkles:math` — Vectors and matrices

## Abstract

`sparkles:math` is the project's one vector type and its matrix type. The
same types describe a point on a terminal's cell grid, a window's size, a
GUI's insets and a shader's colour, so a value crosses from one library to
another without a conversion. A vector names its components as its domain
does, lays them out either densely or as a GPU lays a vector out, is a
compile-time value as well as a runtime one, and compiles both for the host
and, through LDC's dcompute targets, for the device. Its storage follows what
each compiler handles correctly, while its layout and its results do not.

## Introduction

A geometry vocabulary appears in every layer of a UI stack. A terminal reports
a cell position as a column and a row, a window system reports sizes in
physical and logical units, a layout pass computes points and insets, and a
shader receives colours and texture coordinates. Each of these is a small
fixed-length tuple of numbers with arithmetic, and each layer names its
components after its own world: `col`/`row`, `width`/`height`,
`top`/`right`/`bottom`/`left`, `x`/`y`/`z`/`w`.

Two requirements make one type for all of them hard. A shader's vector must
be what the GPU compiler wants, a native vector, and must occupy the bytes the
GPU gives it (a three-component `float` vector is 16 bytes there), while a
grid of cells wants its two `ushort`s back to back. And the type must work at
compile time, in constant tables and `static assert`s, on two compilers whose
code generators and compile-time evaluators handle native vectors differently:
DMD miscompiles some vector code when optimising, and neither released
compiler evaluates vector arithmetic at compile time.

The approach is one template with the layout as a parameter and the storage as
a consequence. A vector is a single private array of its components, named by
accessors, never by a union of views, so the compiler's own compile-time
evaluator can read it. Where a vector is device-shaped and the compiler both
needs and correctly handles a native vector, that array is a native vector;
everywhere else it is a static array. Nothing observable depends on which.

This specification does not cover transformations (rotation, projection,
quaternions), geometric algorithms, or numerically careful operations such as
normalisation; consumers build those on the types. It promises no particular
machine code: a native vector is an opportunity for the compiler, not a
guarantee of SIMD instructions. Matrices are at most four by four. What a
shader may do with these types, and which names a shader writes them under, is
[`sparkles:shaders`](../shaders/vocabulary.md)'s to say; this library owns the
types themselves.

The requirements follow, vectors (`MV`) and then matrices (`MM`); the
decisions that shaped them are in [Decisions](#decisions), and the evidence
for each requirement is in the [ledger](#evidence).

## The contract at a glance

1. A vector is one private field, a static array or a native vector of its
   components, and a component's name is a `ref` accessor to one element.
2. A vector's size and alignment are fixed by its component type, its length
   and its layout, identically on every compiler, host and device.
3. Every operation means the same on every representation, and is available
   at compile time.
4. Operations between vectors depend on their lengths, not on their names or
   layouts.
5. A matrix is an array of device-layout vectors, its columns or its rows,
   and is indexed and constructed as mathematics writes it, whatever its order.

## Vectors

**MV1: The type.** The library **must** provide
`Vector!(T, N, layout = Layout.packed, names = defaultNames!N)`: `N`
components of a numeric type `T`, laid out as `layout`, named by the `N`
strings `names`. `N` **must** be at least 1, and a device-layout vector
**must** have at most four components; other arguments **must** fail to
compile. The default names **must** be `x`, `y`, `z` and `w` for up to four
components and `v0`, `v1`, … beyond.

**MV2: Layout.** A packed vector **must** have size `N * T.sizeof` and the
alignment of `T`. A device vector **must** have the size and alignment of one,
two, four and four components for one, two, three and four components: a
device `float3` is 16 bytes, aligned to 16. Size and alignment **must** be the
same under every compiler and in a host build and a device build.

_Rationale:_ the device layout is how `std140`, `std430` and GPU compilers lay
a vector out, so a value, a struct field or an array element holding one
means the same bytes on both sides; the packed layout is the dense storage a
grid of cells needs.

**MV3: Storage.** A vector **must** store its components in one private field.
That field **must** be a native vector (`__vector(T[N])`) for a device vector
of `float`, `int` or `uint`, in a dcompute device build for two to four
components, and in a host build under LDC for two or four components when the
compiler evaluates vector arithmetic at compile time. It **must** be a static
array `T[N]` otherwise, under DMD always. `storesNative` **must** say which,
and a vector that stores a native vector **must** expose it (`nativeVector`)
and be constructible from one (`fromNative!V`). No other observable behaviour
of this specification **may** depend on the storage.

**MV4: Components.** Each name **must** be a `ref` accessor to its component,
readable and writable, at compile time and at run time. `v[i]` **must** be
component `i`, with `$` the length; `v.array` **must** be a copy of the
components as `T[N]`. A packed vector **must** also slice its storage, `v[]`
and `v[i .. j]`.

**MV5: Construction.** A vector **must** be constructible from all `N`
components in order, and by name (`Cell(col: 3, row: 4)`); with more than one
component, from one value broadcast to every component, and from a vector of
the first `N - 1` components and the last. Construction from more than one but
fewer than all components **must** not compile. A default-initialised vector's components
**must** all be zero.

**MV6: Arithmetic.** `+`, `-`, `*` and `/` **must** apply component-wise
between two vectors of the same length, whatever their names and layouts, and
between a vector and a numeric value on either side; the result **must** have
the left vector's names and layout (the vector's, for a scalar on the left)
and the common type of the components. The assignment forms **must** apply in
place, keeping the vector's type. Unary `-` **must** negate every component,
and unary `+` **must** be the identity.

**MV7: Equality and hashing.** `a == b` **must** be one `bool`, true when
every component of `a` equals the one of `b`, for two vectors of the same
length whatever their names and layouts. On the host, equal vectors of one
type **must** hash alike, so that a vector can key an associative array.

**MV8: Swizzles.** For a vector whose names are single letters, a name of one
to four of those letters **must** read the named components in order, with
repetition (`v.yx`, `v.xxz`); for a vector with the default names, `rgba`
**must** spell `xyzw` too (`c.rgb`). One letter **must** read the component
itself, as GLSL's does. A swizzle **must** not mix the two spellings. Assigning
to a swizzle **must** write the named components in order, and **must** not
compile when it names a component twice. A name that is neither a member nor a
swizzle **must** be an ordinary "no property" error, not a swizzle error.

**MV9: Compile time.** Every operation of `MV4` to `MV8`, and the constants of
`MV11`, **must** be available in CTFE: a vector built at compile time is read,
written and computed with at compile time, under every compiler a build may
use, including a device build.

**MV10: Reflection.** A vector **must** have exactly one field, its private
storage, and each name **must** be a public, zero-argument `@property` getter,
so that a reflective consumer sees each component once, by its name.

**MV11: Utilities.** `dot(a, b)` **must** be the sum of the component-wise
products of two vectors of one length, in their components' common type, and
`a.dot(b)` **must** be the same. A
floating-point vector **must** have `infinity`, every component infinite. A
vector **must** print as a tuple of its components, `(1, 2)`.

**MV12: Shader interface.** A vector that stores a native vector **must** carry
`ldc.dcompute`'s `@vectorType`, so that it crosses a shader's interface as that
native vector: with its type, its location and its block layout.

## Matrices

**MM1: The type.** The library **must** provide
`Matrix!(T, R, C, order = MatrixOrder.columnMajor)`: `R` rows and `C` columns
of a numeric `T`, each from one to four, stored in `order`.

**MM2: Storage and layout.** A column-major matrix **must** store its `C`
columns, each a `Vector!(T, R, Layout.device)`, and a row-major one its `R`
rows, each a `Vector!(T, C, Layout.device)`. So a column-major
`Matrix!(float, 3, 3)` is 48 bytes, the bytes of a column-major `mat3` under
`std140` and `std430`.

**MM3: Indexing and construction.** `m[r, c]` **must** be the element in row
`r` and column `c`, readable and writable, whatever the order. The element
constructor **must** take the `R * C` elements row by row; `fromColumns` and
`fromRows` **must** build a matrix from its columns or its rows; `column(c)`
and `row(r)` **must** read them as vectors; a square matrix **must** have
`identity`; and `transpose` **must** swap rows and columns, keeping the order.
A default-initialised matrix's elements **must** all be zero.

**MM4: Products.** `m * v` **must** be the product with a vector of `C`
components as a column vector, a vector of `R`; `v * m` the product with a
vector of `R` components as a row vector, a vector of `C`; and `m * n` the
matrix product of an `R`×`C` and a `C`×`K` matrix, an `R`×`K` matrix in
`m`'s order. `mul(m, v)`, `mul(v, m)` and `mul(m, n)` **must** be the same
products. The result **must** not depend on either operand's order.

**MM5: Element-wise operations.** `+` and `-` between two matrices of one
shape, and `*` and `/` with a scalar on either side (`/` on the right),
**must** apply element-wise. `==` **must** be true when every element is
equal, whatever the orders. On the host, equal matrices **must** hash alike. A
matrix **must** print row by row, `[(1, 2), (3, 4)]`.

**MM6: Compile time.** Every operation of `MM3` to `MM5` **must** be available
in CTFE, as `MV9` requires of vectors.

## Decisions

**MD1: Accessors, not a union.** A vector's names are accessors to one array,
where they were the fields of a union overlaying the array. Reading a union's
other view is not allowed in CTFE, a reflective consumer saw every component
twice, and a union of named fields cannot also be a native vector. The cost is
that a name is a function, so a struct literal cannot set the names; the
constructor can, by name.

**MD2: Storage follows the compiler.** Accepted by the owner, 2026-10-21. A
device build needs native vectors, which are what a shader's interface is. A
host could use them too, but DMD's optimiser hangs on and miscompiles some
vector code (`-O` and `-inline`), and no released compiler evaluates vector
arithmetic in CTFE ([dlang/dmd#21823](https://github.com/dlang/dmd/issues/21823)).
So the storage is a native vector only where it is needed and handled: always
on the device, whose compiler carries the CTFE fix, and on the host under an
LDC whose CTFE passes a probe for it. A host build switches with the
compiler, with no source change. The defects are recorded, with reproducers,
in [#676](https://github.com/PetarKirov/sparkles/issues/676). Revisit when a
released LDC carries the fix, or when DMD's vector code generation is sound.

**MD3: Packed by default.** Accepted by the owner, 2026-10-21. The default
layout is packed, the previous `Vector`'s, so the geometry types of the UI,
terminal and window libraries keep their sizes; a shader's vectors ask for the
device layout by name. The alternative, device layout by default, would have
grown every point and inset, and realigned the structs holding them.

**MD4: Column-major, as a type parameter.** Accepted by the owner, 2026-10-21.
Matrices default to column-major storage, SPIR-V's and GLSL's default, and
HLSL's too. The order is a parameter of the type, not of the build target:
the bytes matter to the host that writes a buffer, and each shading language
translates the storage it is given. What differs between HLSL and GLSL is how
they name a shape (`float3x2` is three rows; `mat3x2` three columns) and
which side they multiply a vector from, which `MM4` and the shader
vocabulary's aliases cover.

**MD5: A one-letter swizzle is the component.** `c.a` is the component, as in
GLSL, not a one-component vector; the other letters of the default names are
already members.

**MD6: A matrix is an array of vectors on the device.** LLVM's SPIR-V backend
has no matrix type to lower to, so a matrix in a block is a struct of an array
of vectors: the bytes of a column-major matrix, but not `OpTypeMatrix`, and
GLSL translated from it sees the array. A block's consumer writes the same
bytes either way; a shader that hands the matrix to GLSL code expecting `mat4`
is out of scope until the backend has a matrix type.

## Evidence

| ID        | Status   | Evidence                                                                                                                                                                                                                                                                       | Gap |
| --------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --- |
| MV1, MV2  | verified | `Vector.layout` (every layout's size and alignment, under DMD and LDC); `shaders.types.oneLayoutOnBothSides`; every device build compiles the device vectors at those sizes                                                                                                    | —   |
| MV3       | verified | `Vector.ctfe` (CTFE over both storages: a static array under DMD and stock LDC, a native vector under the dcompute compiler's host build); every device build stores native vectors (`sparkles.math.vector`)                                                                   | —   |
| MV4, MV5  | verified | `Vector.construction`, `Vector.components`, `Vector.slices`                                                                                                                                                                                                                    | —   |
| MV6, MV11 | verified | `Vector.arithmetic` (two custom-named vectors add; mixed types), `Vector.infinity`, `Vector.toString`                                                                                                                                                                          | —   |
| MV7       | verified | `Vector.equalityAndHashing` (equality across layouts; an associative-array key)                                                                                                                                                                                                | —   |
| MV8       | verified | `Vector.swizzle` (reads, writes, `rgba`, a repeated write, a mixed spelling and an unknown name rejected)                                                                                                                                                                      | —   |
| MV9       | verified | `Vector.ctfe`, `Matrix.elementWise`; the device build of every shader package                                                                                                                                                                                                  | —   |
| MV10      | verified | `dql.wsi-schema` and the input schema tests keep their component paths (`pointer.logicalPosition.x`, `resize.size.width`) and reject the storage                                                                                                                               | —   |
| MV12      | verified | the dcompute compiler's lit test [vulkan_vector_type.d](https://github.com/PetarKirov/ldc/blob/567b3bc59c38152a969798f5773d932bb57a9ad2/tests/codegen/vulkan_vector_type.d) (every interface position, `std140` offsets); the Vulkan and GL readbacks of the shader vocabulary | —   |
| MM1–MM3   | verified | `Matrix.layout`, `Matrix.indexing` (both orders)                                                                                                                                                                                                                               | —   |
| MM4, MM5  | verified | `Matrix.products` (both orders, `mul`), `Matrix.elementWise`, `Matrix.toString`                                                                                                                                                                                                | —   |
| MM6       | verified | `Matrix.elementWise` (`identity * 3` at compile time)                                                                                                                                                                                                                          | —   |
