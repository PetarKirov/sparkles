#!/usr/bin/env dub
/+ dub.sdl:
    name "manim_affine_transform"
    targetPath "build"
+/
/**
 * 2D affine transforms as 3×3 homogeneous matrices: compose translate ·
 * rotate · scale into ONE matrix, apply it to a Bézier control polygon, and
 * verify that the single composed matrix equals applying the three transforms
 * sequentially.
 *
 * The *object & scene model* axis (coordinate space) of the analysis spine.
 * Every mobject carries a model transform; `Transform`/`ApplyMatrix` and the
 * camera all reduce to affine maps on control points. The load-bearing fact a
 * reimplementation must respect is composition order: `M = T·R·S` applied once
 * is identical to scaling, then rotating, then translating each point in turn
 * — matrix multiply *is* function composition, right-to-left. This probe
 * proves it numerically (max deviation 0 within fp epsilon), which is why the
 * proposal builds a single `Affine2` compose primitive rather than mutating
 * points per operation.
 *
 * It also exercises exactly the `Matrix`/`Affine2` primitive M1 of the
 * proposal adds to `libs/math` on top of the existing `Vector` type.
 *
 * Companion to docs/research/manim/concepts.md § "Affine transform" and
 *   docs/research/manim/manim-community/scene-graph.md § "Coordinate space".
 * Run with: dub run --single affine-transform.d
 *
 * Portability: pure computation, no external dependencies — runs everywhere.
 */
module manim_affine_transform;

import std.math : cos, PI, sin, sqrt;
import std.stdio : writefln, writeln;

/// Row-major 3×3 affine matrix.
struct Mat3
{
    double[3][3] m;

    static Mat3 identity() @safe pure nothrow @nogc
        => Mat3([[1.0, 0, 0], [0.0, 1, 0], [0.0, 0, 1]]);

    static Mat3 translate(double tx, double ty) @safe pure nothrow @nogc
        => Mat3([[1.0, 0, tx], [0.0, 1, ty], [0.0, 0, 1]]);

    static Mat3 scale(double sx, double sy) @safe pure nothrow @nogc
        => Mat3([[sx, 0, 0], [0.0, sy, 0], [0.0, 0, 1]]);

    static Mat3 rotate(double rad) @safe pure nothrow @nogc
    {
        const c = cos(rad), s = sin(rad);
        return Mat3([[c, -s, 0], [s, c, 0], [0.0, 0, 1]]);
    }

    /// Matrix product `this · rhs`.
    Mat3 mul(in Mat3 rhs) const @safe pure nothrow @nogc
    {
        Mat3 r;
        foreach (i; 0 .. 3)
            foreach (j; 0 .. 3)
            {
                double acc = 0;
                foreach (k; 0 .. 3)
                    acc += m[i][k] * rhs.m[k][j];
                r.m[i][j] = acc;
            }
        return r;
    }

    /// Apply to a 2D point (homogeneous w = 1).
    double[2] apply(in double[2] p) const @safe pure nothrow @nogc
        => [m[0][0] * p[0] + m[0][1] * p[1] + m[0][2],
            m[1][0] * p[0] + m[1][1] * p[1] + m[1][2]];
}

double dist(in double[2] a, in double[2] b) @safe pure nothrow @nogc
    => sqrt((a[0] - b[0]) ^^ 2 + (a[1] - b[1]) ^^ 2);

int main() @safe
{
    const T = Mat3.translate(2.0, -1.0);
    const R = Mat3.rotate(PI / 6); // 30°
    const S = Mat3.scale(1.5, 0.5);
    const M = T.mul(R).mul(S); // T·R·S — scale first, then rotate, then translate

    // A cubic control polygon.
    const double[2][4] poly = [[0.0, 0], [1.0, 2], [2.0, -1], [3.0, 0]];

    writeln("== M = T·R·S applied once vs S→R→T applied in sequence ==");
    writefln("   control point      via M            via sequence      |Δ|");
    double maxDev = 0;
    foreach (p; poly)
    {
        const viaM = M.apply(p);
        const viaSeq = T.apply(R.apply(S.apply(p)));
        const d = dist(viaM, viaSeq);
        if (d > maxDev)
            maxDev = d;
        writefln("  (%4.1f,%4.1f)   (%7.4f,%7.4f)   (%7.4f,%7.4f)   %.2e",
            p[0], p[1], viaM[0], viaM[1], viaSeq[0], viaSeq[1], d);
    }
    writefln("  max deviation: %.2e  (matrix product = right-to-left composition)", maxDev);

    // Order matters: T·S != S·T.
    const ts = Mat3.translate(2, 0).mul(Mat3.scale(3, 3)).apply([1.0, 0]);
    const st = Mat3.scale(3, 3).mul(Mat3.translate(2, 0)).apply([1.0, 0]);
    writeln("\n== non-commutativity: translate·scale vs scale·translate on (1,0) ==");
    writefln("  T·S (scale then translate): (%.1f, %.1f)", ts[0], ts[1]);
    writefln("  S·T (translate then scale): (%.1f, %.1f)", st[0], st[1]);
    writeln("  (they differ — order is part of the transform, not incidental)");
    return 0;
}
