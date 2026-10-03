# Geometric Algebra Design Notes

This note captures what it would take to grow the current
[`vector.d`](./vector.d) module into a full geometric algebra layer for D.
It is intentionally a design document, not a partial implementation, because
the right public API depends heavily on which algebra family should come first.

## Current Starting Point

`sparkles.math.vector` currently provides:

- a fixed-size numeric `Vector!(T, N, fieldNames)` for grade-1 Euclidean data
- named component access and swizzles
- component-wise arithmetic
- scalar arithmetic
- dot product

That is a good low-level building block, but it is still only a dense tuple of
coordinates. A full geometric algebra implementation needs:

- a notion of metric or signature
- basis blades and grade structure
- multivector storage
- geometric, outer, and contraction products
- involutions and duality
- versors such as rotors and, depending on flavour, motors

## Main Design Decision

The first decision is not syntax. It is algebra family.

Different "classic GA" flavours produce materially different APIs and
specializations:

- Euclidean orthogonal GA: `Cl(p, q)` with non-degenerate metric
- Projective GA: typically `P(R*_{n, 0, 1})` with a degenerate basis element
- Conformal GA: usually `Cl(p + 1, q + 1)` with null basis vectors
- Spacetime algebra: a specific `Cl(1, 3)` or `Cl(3, 1)` choice

If the goal is "fully, but with a sane first implementation", the practical
order is:

1. Orthogonal `Cl(p, q)` with diagonal metric
2. Specializations for low-dimensional Euclidean cases
3. Degenerate or null-metric algebras such as PGA or CGA

That keeps the core multiplication machinery clean before adding the harder
cases.

## Recommended Core Type Model

The generic layer should be built around a compile-time algebra descriptor and
a compile-time selected multivector storage.

```d
struct OrthogonalAlgebra(size_t P, size_t Q = 0, size_t R = 0)
{
    enum dimensions = P + Q + R;
    // Metric is diagonal: +1 for P, -1 for Q, 0 for R.
}

struct BladeSet(size_t[] masks)
{
    enum bladeMasks = masks;
}

struct Multivector(T, Algebra, BladeSet blades)
{
    T[blades.bladeMasks.length] coeffs;
}
```

### Why bitmasks for blades

Each basis blade should be encoded as a bitmask over the basis vectors:

- scalar: `0b0000`
- `e1`: `0b0001`
- `e2`: `0b0010`
- `e1^e3`: `0b0101`

That gives a compact compile-time representation for:

- grade computation via popcount
- wedge product feasibility via bit overlap
- sign changes from basis swaps
- multiplication table generation at CTFE

This is the standard practical representation for templated Clifford/GA code.

## Public Type Surface

The generic type should not expose "everything is just a dense array of length
2^n" as the only storage form. That is simple, but it wastes both memory and
work for common grade-restricted objects.

Recommended aliases:

```d
alias Scalar(T, Algebra) = KVector!(T, Algebra, 0);
alias GAVector(T, Algebra) = KVector!(T, Algebra, 1);
alias Bivector(T, Algebra) = KVector!(T, Algebra, 2);
alias Trivector(T, Algebra) = KVector!(T, Algebra, 3);
alias Pseudoscalar(T, Algebra) = KVector!(T, Algebra, Algebra.dimensions);

alias EvenMultivector(T, Algebra) = GradeFilteredMultivector!(T, Algebra, "even");
alias OddMultivector(T, Algebra) = GradeFilteredMultivector!(T, Algebra, "odd");
alias FullMultivector(T, Algebra) = GradeFilteredMultivector!(T, Algebra, "all");

alias Rotor(T, Algebra) = EvenMultivector!(T, Algebra);
```

`Rotor` can start as an alias, but in practice performance-sensitive cases
usually want specialized implementations for small Euclidean algebras.

## Relationship to `sparkles.math.vector`

The current `Vector!(T, N)` should remain useful as a plain coordinate vector.

The cleanest approach is:

- keep `Vector!(T, N)` as the compact grade-1 tuple type for non-GA code
- define `GAVector!(T, Algebra)` as the algebra-aware grade-1 type
- specialize `GAVector!(T, OrthogonalAlgebra!(N, 0, 0))` for low `N` by
  reusing the storage and field names of `Vector!(T, N)`

This matters because GA vectors are not just tuples:

- they multiply under the geometric product
- they depend on the metric
- in some algebras they are not Euclidean vectors at all

So "vector aliasing" should be semantic, not just nominal.

## Required Operations

To call the implementation "full" in the ordinary GA sense, the generic layer
should support at least the following:

- grade projection: `grade!(k)(mv)`
- homogeneous grade checks: `isKVector`
- geometric product
- outer product
- left contraction
- right contraction
- scalar product
- reverse
- grade involution
- Clifford conjugation
- dual and undual
- norm or quadratic form where meaningful
- inverse where defined
- commutator and anticommutator products
- sandwich product for versor actions

Two notes:

1. "Dot product" is not enough. In GA, inner-product conventions vary.
2. "Dual" becomes flavour-sensitive once degenerate metrics enter the picture.

## A Better Generic Shape

The most flexible shape is a multivector with compile-time known support over a
subset of blade masks:

```d
struct Multivector(T, Algebra, size_t[] bladeMasks)
{
    T[bladeMasks.length] coeffs;
}
```

Useful aliases can then be derived by compile-time filtering:

```d
alias KVector(T, Algebra, size_t grade) =
    Multivector!(T, Algebra, bladesOfGrade!(Algebra, grade));

alias EvenMultivector(T, Algebra) =
    Multivector!(T, Algebra, evenBlades!Algebra);

alias FullMultivector(T, Algebra) =
    Multivector!(T, Algebra, allBlades!Algebra);
```

This gives you:

- compact storage for vectors, bivectors, rotors, and motors
- compile-time result types for many operations
- a path to specialized overloads without throwing away the generic model

## Product Machinery

For orthogonal algebras, multiplication can be generated at compile time from:

- blade bitmasks
- parity of swaps needed to reorder the basis
- metric factors contributed by repeated basis vectors

Conceptually:

```d
enum bladeProduct(maskA, maskB, Algebra) = BladeProductResult(
    sign: ...,
    mask: ...,
    metricFactor: ...
);
```

Then the geometric product becomes a statically unrolled sum over coefficient
pairs.

This is where D is a strong fit:

- CTFE can build multiplication tables
- `static foreach` can unroll fixed-size operations
- `static if` can dispatch to hand-optimized low-dimensional cases
- result blade sets can be computed at compile time

## Specialization Strategy

The generic multivector core should exist first. Specializations should then be
added for common heavy-use cases.

Recommended specializations:

- `GAVector!(T, OrthogonalAlgebra!(2, 0, 0))`
- `GAVector!(T, OrthogonalAlgebra!(3, 0, 0))`
- `GAVector!(T, OrthogonalAlgebra!(4, 0, 0))`
- `Rotor!(T, OrthogonalAlgebra!(2, 0, 0))`
- `Rotor!(T, OrthogonalAlgebra!(3, 0, 0))`
- `Bivector!(T, OrthogonalAlgebra!(3, 0, 0))`

For example:

- 2D Euclidean rotors collapse to complex-number-like pairs
- 3D Euclidean even multivectors map neatly to quaternions
- 3D bivectors can often use an axial-vector interpretation internally

For PGA:

- `Motor!(T, PGA3)` should likely be a dedicated specialization
- that specialization will look more like a dual quaternion than a generic
  even multivector

This is the important distinction:

- user-facing names can be aliases
- implementation-heavy hot paths should usually be specialized structs or
  specialized overloads behind those aliases

## Example API Direction

Something along these lines is realistic:

```d
alias E3 = OrthogonalAlgebra!(3, 0, 0);

alias Scalar3f = Scalar!(float, E3);
alias GAVec3f = GAVector!(float, E3);
alias Bivec3f = Bivector!(float, E3);
alias Rotor3f = Rotor!(float, E3);
alias Mv3f = FullMultivector!(float, E3);

auto a = GAVec3f(1, 0, 0);
auto b = GAVec3f(0, 1, 0);

auto gp = a * b;
auto wedge = a ^ b;
auto rotor = exp(-(theta / 2) * e12);
auto rotated = rotor.sandwich(a);
```

The public syntax is manageable. The real complexity is in compile-time blade
set propagation and efficient specialized implementations.

## Open API Choices That Need To Be Decided

These choices affect the design enough that implementation should wait for
answers.

### 1. Which algebra family comes first

If you want a staged build-out, pick one of these first:

- Euclidean `Cl(n, 0)` for `n = 2, 3, 4`
- general orthogonal `Cl(p, q)`
- projective GA
- conformal GA
- spacetime algebra

### 2. Which inner-product convention

There is no single universally accepted "dot" in GA libraries. Choices include:

- Hestenes inner product
- left contraction as the primary inner product
- right contraction as the primary inner product
- scalar product only, with contractions kept explicit

This affects both naming and operator overloading.

### 3. Whether degenerate metrics are in scope for phase 1

If yes, the generic machinery needs to account for zero-square basis vectors
from the beginning.

If no, the generic machinery can be much cleaner and still cover ordinary
Euclidean and pseudo-Euclidean Clifford algebras.

### 4. Whether symbolic basis constants are part of the first API

Examples:

```d
enum e1 = basisVector!(E3, 0);
enum e2 = basisVector!(E3, 1);
enum e12 = e1 ^ e2;
```

This is attractive, but it pushes more work into CTFE and public naming
decisions early.

## Suggested Implementation Phases

### Phase 1: Orthogonal generic core

- add `OrthogonalAlgebra!(P, Q, R = 0)`
- add compile-time blade-mask utilities
- add `Multivector!(T, Algebra, bladeMasks...)`
- implement geometric product, wedge, projections, involutions
- implement `KVector`, `EvenMultivector`, `FullMultivector`

### Phase 2: Euclidean specializations

- wire low-dimensional grade-1 vectors to `sparkles.math.vector`
- specialize 2D and 3D rotors
- add fast sandwich product for `E2` and `E3`
- add norms and inverse helpers for common cases

### Phase 3: Public ergonomics

- basis constants
- aliases such as `Rotor3f`, `Bivec3d`, `Mv3f`
- DDoc examples and unit tests
- conversions between plain `Vector!(T, N)` and `GAVector!(T, E_n)`

### Phase 4: Non-orthogonal extensions

- PGA or CGA, whichever is actually desired
- motors, translators, null basis support
- meet and join operators where appropriate

## What It Would Take In Practice

This is not a one-file extension of `vector.d`.

A serious implementation likely needs at least:

- one module for algebra descriptors and metric logic
- one module for blade-mask and grade meta-programming
- one module for generic multivector storage and operators
- one module for low-dimensional specializations
- one module for public aliases and basis constants

So the actual work is roughly:

1. define the algebra descriptors and compile-time blade representation
2. build the generic multivector kernel
3. decide operator semantics carefully
4. specialize the small hot-path cases
5. connect the grade-1 Euclidean story to the existing `Vector!(T, N)` type

## Recommendation

If the target is a practical, fast, "classic" GA for graphics-like work, the
best first milestone is:

- generic orthogonal `Cl(p, q)`
- first-class `Cl(2, 0)` and `Cl(3, 0)` specializations
- grade-restricted storage
- `Rotor` as a public alias with specialized `E2` and `E3` internals

That keeps the generic design honest while still giving you the optimized
vector, bivector, and rotor paths you actually care about.

## Question To Resolve Before Implementation

Which flavour do you want as the first-class target:

- Euclidean `Cl(n, 0)`
- general orthogonal `Cl(p, q)`
- projective GA
- conformal GA
- spacetime algebra

If you answer that, the next step can be a real module skeleton instead of a
design note.
