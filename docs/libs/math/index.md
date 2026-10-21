# sparkles:math

The project's one vector type and its matrix type. A cell on a terminal's
grid, a window's size, a GUI's insets and a shader's colour are all
`Vector`s, so a value crosses from one library to another without a
conversion. The contract is the [specification](../../specs/math/SPEC.md).

```d
import sparkles.math;

alias Cell = Vector!(ushort, 2, Layout.packed, ["col", "row"]);
alias float4 = Vector!(float, 4, Layout.device);

enum Cell origin = Cell(col: 1, row: 1);   // a compile-time value
static assert(origin.row == 1);

auto c = float4(0.25f, 0.5f, 0.75f, 1);
c.rgb = c.bgr;                              // swizzles, read and written
assert(c == float4(0.75f, 0.5f, 0.25f, 1)); // one bool

const m = Matrix!(float, 2, 2)( // row by row
    0, -1,
    1, 0);
assert(m * Vec2f(1, 0) == Vector!(float, 2, Layout.device)(0, 1));
```

## Vectors

`Vector!(T, N, layout, names)` holds `N` components of `T`.

- **Names.** `x`, `y`, `z`, `w` by default, or the domain's own
  (`["width", "height"]`). Each is a `ref` accessor, and a constructor takes
  the components by position or by name. `v[i]` and `v.array` reach them by
  index.
- **Layout.** `Layout.packed`, the default, is the components back to back.
  `Layout.device` is how a GPU lays a vector out: two components take twice a
  component's size and alignment, three and four take four times, so a
  device `float3` is 16 bytes.
- **Arithmetic.** `+ - * /` work component-wise against a vector of the same
  length, whatever its names or layout, or against a scalar on either side.
  `==` is one `bool`, and a vector hashes, so it can key an associative array.
  `dot(a, b)` is the dot product.
- **Swizzles.** For one-letter names: `v.yx`, `v.xxz`, and `rgba` for the
  default names. A swizzle may be assigned to, if it names each component
  once. A name that is not a swizzle is a plain "no property" error.
- **Compile time.** Everything above works in CTFE, under DMD and LDC.

A device vector of `float`, `int` or `uint` stores a native `__vector` where
the compiler needs one and handles it: always in a shader build, and on the
host under an LDC whose compile-time evaluator supports vector operations.
Its storage is otherwise a static array, under DMD always. Nothing but the
generated code depends on which.

## Matrices

`Matrix!(T, R, C, order)` is `R` rows by `C` columns, at most four by four.

- **Storage.** Column-major by default, as its columns, each a device vector.
  A `float3x3` is 48 bytes, the bytes of a column-major `mat3` under `std140`
  and `std430`. `MatrixOrder.rowMajor` stores the rows instead.
- **Indexing and construction.** `m[r, c]` and the element constructor read
  as mathematics writes a matrix, row by row, whatever the order.
  `fromColumns`, `fromRows`, `column(c)`, `row(r)`, `identity` and
  `transpose` cover the rest.
- **Products.** `m * v` multiplies by a column vector, `v * m` by a row
  vector, and `m * n` is the matrix product. `mul` spells all three as HLSL
  does. `+`, `-` and a scalar `*` or `/` work element-wise.

For a shader, [`sparkles:shaders`](../shaders/index.md) names these types
`float4`, `float4x4`, `vec4`, `mat4` and so on.
