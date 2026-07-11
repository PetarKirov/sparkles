#!/usr/bin/env dub
/+ dub.sdl:
    name "manim_bezier_eval"
    targetPath "build"
+/
/**
 * Quadratic (3-point) vs cubic (4-point) Bézier curves: de Casteljau
 * evaluation, exact quadratic→cubic degree elevation, and the one-way
 * conversion cost that a single quadratic pays approximating a cubic.
 *
 * The *object & scene model* axis of the analysis spine, exercised in code.
 * The two Manim geometry camps disagree on the Bézier basis: ManimGL and
 * community's OpenGL classes store curves as **quadratic** triples
 * `(anchor, handle, anchor)`; community's Cairo classes store **cubic**
 * quads `(anchor, handle, handle, anchor)`. The choice is load-bearing for a
 * reimplementation because the conversion between the two bases is *not*
 * symmetric:
 *
 *   1. A quadratic Bézier `Q(P0,P1,P2)` elevates to a cubic `C(C0..C3)`
 *      *exactly* — `C0=P0`, `C1=P0+2/3(P1-P0)`, `C2=P2+2/3(P1-P2)`, `C3=P2` —
 *      so the two curves are pointwise identical. This probe elevates a
 *      quadratic and prints the max sample deviation (0 within fp epsilon):
 *      quadratics are a strict subset of cubics.
 *   2. The reverse is lossy: a general cubic has an inflection a single
 *      quadratic cannot follow. This probe fits the "best" single quadratic
 *      (sharing the cubic's endpoints, handle at the cubic control average)
 *      and prints the residual max deviation — the per-curve error the
 *      quadratic-canonical engines eat, and the reason a cubic-canonical
 *      store only makes the *GPU* backend lower curves (§ cubic-canonical).
 *
 * This is the concrete evidence behind the `manim-community/scene-graph.md`
 * and `manimgl.md` geometry sections, and behind the proposal's decision to
 * standardise on a cubic interchange basis.
 *
 * Companion to docs/research/manim/manim-community/scene-graph.md
 *   § "Bézier basis: cubic vs quadratic" and docs/research/manim/manimgl.md
 *   § "Quadratic curves in a structured array".
 * Run with: dub run --single bezier-eval.d
 *
 * Portability: pure computation, no external dependencies or host
 * capabilities — compiles and runs identically everywhere.
 */
module manim_bezier_eval;

import std.math : fabs, sqrt;
import std.stdio : writefln, writeln;

alias P = double[2];

P lerp(in P a, in P b, double t) @safe pure nothrow @nogc
    => [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];

/// de Casteljau for a quadratic (3 control points).
P quad(in P p0, in P p1, in P p2, double t) @safe pure nothrow @nogc
{
    const a = lerp(p0, p1, t);
    const b = lerp(p1, p2, t);
    return lerp(a, b, t);
}

/// de Casteljau for a cubic (4 control points).
P cubic(in P p0, in P p1, in P p2, in P p3, double t) @safe pure nothrow @nogc
{
    const a = lerp(p0, p1, t);
    const b = lerp(p1, p2, t);
    const c = lerp(p2, p3, t);
    const d = lerp(a, b, t);
    const e = lerp(b, c, t);
    return lerp(d, e, t);
}

double dist(in P a, in P b) @safe pure nothrow @nogc
    => sqrt((a[0] - b[0]) ^^ 2 + (a[1] - b[1]) ^^ 2);

/// Polyline arc-length estimate over `n` samples.
double arcLength(scope P delegate(double) @safe f, size_t n = 256) @safe
{
    double len = 0;
    P prev = f(0);
    foreach (i; 1 .. n + 1)
    {
        const cur = f(cast(double) i / n);
        len += dist(prev, cur);
        prev = cur;
    }
    return len;
}

int main() @safe
{
    // A quadratic and its EXACT cubic elevation.
    const P q0 = [0.0, 0.0], q1 = [1.0, 2.0], q2 = [3.0, 0.0];
    const P c0 = q0;
    const P c1 = [q0[0] + 2.0 / 3 * (q1[0] - q0[0]), q0[1] + 2.0 / 3 * (q1[1] - q0[1])];
    const P c2 = [q2[0] + 2.0 / 3 * (q1[0] - q2[0]), q2[1] + 2.0 / 3 * (q1[1] - q2[1])];
    const P c3 = q2;

    writeln("== quadratic (3-pt) vs its exact cubic (4-pt) elevation ==");
    writefln("  quadratic control: %s %s %s", q0, q1, q2);
    writefln("  elevated cubic   : %s %s %s %s", c0, c1, c2, c3);
    writefln("   t      quad(t)                 cubic(t)                 |Δ|");
    double elevMax = 0;
    foreach (i; 0 .. 11)
    {
        const t = i / 10.0;
        const a = quad(q0, q1, q2, t);
        const b = cubic(c0, c1, c2, c3, t);
        const d = dist(a, b);
        if (d > elevMax)
            elevMax = d;
        writefln("  %4.1f  (%7.4f, %7.4f)   (%7.4f, %7.4f)   %.2e", t, a[0], a[1], b[0], b[1], d);
    }
    writefln("  max elevation deviation: %.2e  (quadratics are a strict subset of cubics)", elevMax);

    // A general cubic with an inflection, and the best single quadratic
    // through its endpoints (handle at the average of the two cubic handles).
    const P g0 = [0.0, 0.0], g1 = [1.0, 3.0], g2 = [2.0, -3.0], g3 = [3.0, 0.0];
    const P h = [(g1[0] + g2[0]) / 2, (g1[1] + g2[1]) / 2];
    writeln("\n== a cubic with an inflection, approximated by ONE quadratic ==");
    writefln("  cubic control  : %s %s %s %s", g0, g1, g2, g3);
    writefln("  quad handle (avg of cubic handles): %s", h);
    double fitMax = 0;
    foreach (i; 0 .. 11)
    {
        const t = i / 10.0;
        const d = dist(cubic(g0, g1, g2, g3, t), quad(g0, h, g3, t));
        if (d > fitMax)
            fitMax = d;
    }
    writefln("  max approximation error: %.4f  (the per-curve cost a quadratic-only", fitMax);
    writefln("  store pays; a cubic store lowers to quads only on the GPU backend)");

    writefln("\n  arc length: quadratic %.4f, inflected cubic %.4f",
        arcLength((double t) @safe => quad(q0, q1, q2, t)),
        arcLength((double t) @safe => cubic(g0, g1, g2, g3, t)));
    return 0;
}
