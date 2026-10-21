/**
The project's matrix type: `Matrix!(T, R, C, order)`, `R` rows by `C`
columns.

$(B Stored as device vectors.) A column-major matrix (the default) is `C`
columns, each a `Vector!(T, R, Layout.device)`; a row-major one is `R` rows of
`Vector!(T, C, Layout.device)`. So a `float3x3` is three 16-byte columns,
48 bytes: what `std140` and `std430` give a column-major `mat3`, and what
SPIR-V and GLSL store by default. The order is the matrix's type, not the
target's: HLSL's default storage is column-major too, and what differs
between the languages is only how they name a shape and which side they
multiply a vector from.

$(B Indexed as mathematics writes it.) `m[r, c]` is the element in row `r`
and column `c` whatever the order, and the element constructor takes the
elements row by row, as a matrix is written on paper (and as HLSL's
constructor reads them).

$(B Operations.) `m * v` treats `v` as a column vector, `v * m` as a row
vector, `m * n` is the matrix product, `+`, `-` and a scalar `*` or `/` are
element-wise, `==` compares every element, and `transpose` swaps rows and
columns. `mul` spells the three products HLSL's way.
*/
@compute(CompileFor.hostAndDevice)
module sparkles.math.matrix;

import std.traits : CommonType, isNumeric;

import sparkles.math.device : compute, CompileFor;
import sparkles.math.vector : isVector, Layout, Vector;

/// The order a matrix stores its elements in.
enum MatrixOrder
{
    /// One vector per column (SPIR-V's, GLSL's and HLSL's default).
    columnMajor,
    /// One vector per row.
    rowMajor,
}

/// Whether `M` is a $(LREF Matrix).
enum bool isMatrix(M) = is(M : Matrix!(U, R, C, o), U, size_t R, size_t C, MatrixOrder o);

/// A matrix of `R` rows and `C` columns of `T`, stored in `order`.
struct Matrix(T, size_t R, size_t C, MatrixOrder order = MatrixOrder.columnMajor)
if (isNumeric!T && R >= 1 && R <= 4 && C >= 1 && C <= 4)
{
    /// The element type, the shape and the order.
    alias Element = T;
    /// ditto
    enum size_t rows = R;
    /// ditto
    enum size_t columns = C;
    /// ditto
    enum MatrixOrder storageOrder = order;

    /// A column, and a row, as a vector.
    alias Column = Vector!(T, R, Layout.device);
    /// ditto
    alias Row = Vector!(T, C, Layout.device);

    private enum bool byColumn = order == MatrixOrder.columnMajor;

    // The storage: the columns, or the rows.
    static if (byColumn)
        private Column[C] _m;
    else
        private Row[R] _m;

    /// The element in row `r` and column `c`.
    ref inout(T) opIndex(size_t r, size_t c) inout return
    {
        static if (byColumn)
            return _m[c][r];
        else
            return _m[r][c];
    }

    /// Column `c`, and row `r`.
    Column column(size_t c) const
    {
        static if (byColumn)
            return _m[c];
        else
        {
            Column v;
            static foreach (r; 0 .. R)
                v[r] = _m[r][c];
            return v;
        }
    }

    /// ditto
    Row row(size_t r) const
    {
        static if (!byColumn)
            return _m[r];
        else
        {
            Row v;
            static foreach (c; 0 .. C)
                v[c] = _m[c][r];
            return v;
        }
    }

    /// Constructs a matrix from its elements, row by row.
    this(T[R * C] elements...)
    {
        static foreach (r; 0 .. R)
            static foreach (c; 0 .. C)
                this[r, c] = elements[r * C + c];
    }

    /// A matrix of the given columns, and of the given rows.
    static Matrix fromColumns(const Column[C] cols...)
    {
        Matrix m;
        static foreach (c; 0 .. C)
            static foreach (r; 0 .. R)
                m[r, c] = cols[c][r];
        return m;
    }

    /// ditto
    static Matrix fromRows(const Row[R] rs...)
    {
        Matrix m;
        static foreach (r; 0 .. R)
            static foreach (c; 0 .. C)
                m[r, c] = rs[r][c];
        return m;
    }

    static if (R == C)
    {
        /// The identity matrix.
        enum Matrix identity = () {
            Matrix m;
            static foreach (i; 0 .. R)
                m[i, i] = 1;
            return m;
        }();
    }

    /// The transpose: rows and columns swapped, in the same order.
    Matrix!(T, C, R, order) transpose() const
    {
        Matrix!(T, C, R, order) t;
        static foreach (r; 0 .. R)
            static foreach (c; 0 .. C)
                t[c, r] = this[r, c];
        return t;
    }

    /// The product with `v` as a column vector: a vector of `R`.
    Column opBinary(string op : "*", V)(const V v) const
    if (isVector!V && V.dimension == C)
    {
        static if (byColumn)
        {
            Column r = _m[0] * cast(T) v[0];
            static foreach (c; 1 .. C)
                r += _m[c] * cast(T) v[c];
            return r;
        }
        else
        {
            Column r;
            static foreach (i; 0 .. R)
                static foreach (c; 0 .. C)
                    r[i] = r[i] + _m[i][c] * cast(T) v[c];
            return r;
        }
    }

    /// The product with `v` as a row vector: a vector of `C`.
    Row opBinaryRight(string op : "*", V)(const V v) const
    if (isVector!V && V.dimension == R)
    {
        static if (!byColumn)
        {
            Row r = _m[0] * cast(T) v[0];
            static foreach (i; 1 .. R)
                r += _m[i] * cast(T) v[i];
            return r;
        }
        else
        {
            Row r;
            static foreach (c; 0 .. C)
                static foreach (i; 0 .. R)
                    r[c] = r[c] + _m[c][i] * cast(T) v[i];
            return r;
        }
    }

    /// The matrix product, in this matrix's order.
    Matrix!(T, R, K, order) opBinary(string op : "*", U, size_t K, MatrixOrder o)(
        in Matrix!(U, C, K, o) rhs) const
    {
        Matrix!(T, R, K, order) p;
        static foreach (k; 0 .. K)
        {{
            const Column col = this * rhs.column(k);
            static foreach (r; 0 .. R)
                p[r, k] = col[r];
        }}
        return p;
    }

    /// Element-wise sum and difference.
    Matrix opBinary(string op, U, MatrixOrder o)(const Matrix!(U, R, C, o) rhs) const
    if (op == "+" || op == "-")
    {
        Matrix m;
        static foreach (r; 0 .. R)
            static foreach (c; 0 .. C)
                m[r, c] = cast(T) mixin("this[r, c] " ~ op ~ " rhs[r, c]");
        return m;
    }

    /// Element-wise product and quotient with a scalar, on either side.
    Matrix opBinary(string op, U)(const U s) const
    if ((op == "*" || op == "/") && isNumeric!U)
    {
        Matrix m;
        static foreach (i; 0 .. _m.length)
            m._m[i] = mixin("_m[i] " ~ op ~ " cast(T) s");
        return m;
    }

    /// ditto
    Matrix opBinaryRight(string op : "*", U)(const U s) const
    if (isNumeric!U)
        => this * s;

    /// Whether every element equals the one of `rhs`.
    bool opEquals(U, MatrixOrder o)(const Matrix!(U, R, C, o) rhs) const
    {
        bool same = true;
        static foreach (r; 0 .. R)
            static foreach (c; 0 .. C)
                same = same & (this[r, c] == rhs[r, c]);
        return same;
    }

    version (LDC_DCompute) {} else
    {
        /// The hash of the elements.
        size_t toHash() const @safe pure nothrow @nogc
        {
            T[R * C] e;
            static foreach (r; 0 .. R)
                static foreach (c; 0 .. C)
                    e[r * C + c] = this[r, c];
            return hashOf(e);
        }
    }

    /// Writes the matrix row by row: `[(1, 0), (0, 1)]`.
    void toString(Writer)(ref Writer w) const
    {
        import std.range.primitives : put;

        put(w, "[");
        static foreach (r; 0 .. R)
        {
            static if (r > 0)
                put(w, ", ");
            row(r).toString(w);
        }
        put(w, "]");
    }
}

/// The matrix product with `v` as a column vector, HLSL's `mul(m, v)`.
auto mul(M, V)(const M m, const V v)
if (isMatrix!M && isVector!V)
    => m * v;

/// The product with `v` as a row vector, HLSL's `mul(v, m)`.
auto mul(V, M)(const V v, const M m)
if (isVector!V && isMatrix!M)
    => v * m;

/// The matrix product, HLSL's `mul(a, b)`.
auto mul(A, B)(const A a, const B b)
if (isMatrix!A && isMatrix!B)
    => a * b;
