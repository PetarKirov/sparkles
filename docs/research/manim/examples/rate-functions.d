#!/usr/bin/env dub
/+ dub.sdl:
    name "manim_rate_functions"
    targetPath "build"
+/
/**
 * Rate functions (easing) — the reshaping every `Animation` applies to its
 * `[0,1]` time parameter before interpolation, plus the `lag_ratio`
 * staggering that spreads a group of sub-animations across the window.
 *
 * The *animation & timing* axis of the analysis spine, exercised in code.
 * A Manim `Animation` maps wall-clock progress `alpha ∈ [0,1]` through a
 * `rate_func` and then lerps the mobject; composition (`AnimationGroup`,
 * `LaggedStart`) additionally offsets each submobject by `lag_ratio` so they
 * start in sequence. This probe reimplements the community rate functions and
 * the `get_sub_alpha` stagger formula so the timing model is grounded in
 * runnable numbers rather than prose:
 *
 *   - `linear(t)   = t`
 *   - `smootherstep(t) = 6t⁵ − 15t⁴ + 10t³`  (zero 1st AND 2nd derivative at
 *                    both ends). NOTE the fork divergence: this quintic is
 *                    ManimGL's default `smooth` (rate_functions.py — "Equivalent
 *                    to bezier([0,0,0,1,1,1])"), but Manim **community**'s default
 *                    `smooth` is instead a normalized logistic **sigmoid**
 *                    (`inflection = 10`), and it keeps the quintic under the
 *                    separate name `smootherstep`. Both are ease-in-out S-curves;
 *                    this probe prints both so the divergence is visible.
 *   - `smoothSigmoid(t)` — community's default `smooth`: a logistic sigmoid
 *                    rescaled to hit exactly 0 and 1 at the endpoints.
 *   - `rush_into(t)= 2·smootherstep(t/2)`      (ease-in only)
 *   - `rush_from(t)= 2·smootherstep(t/2 + ½) − 1` (ease-out only)
 *   - `there_and_back(t)` — out to 1 at t=½, back to 0 at t=1
 *   - the `lag_ratio` sub-window map:
 *        full = (n−1)·lag + 1;  sub_alpha_i = alpha·full − i·lag
 *     (Manim clamps this to `[0,1]` one call deeper, inside the `unit_interval`
 *     decorator wrapping each rate function; this probe clamps it directly.)
 *
 * The eased tables and the stagger matrix here are the evidence behind
 * `concepts.md` § easing / § lag_ratio and the `manim-community/index.md`
 * timing section.
 *
 * Companion to docs/research/manim/concepts.md § "Rate function / easing"
 *   and § "lag_ratio / stagger".
 * Run with: dub run --single rate-functions.d
 *
 * Portability: pure computation, no external dependencies — runs everywhere.
 */
module manim_rate_functions;

import std.algorithm : clamp;
import std.math : exp;
import std.stdio : write, writefln, writeln;

/// The smootherstep quintic — ManimGL's default `smooth`, community's `smootherstep`.
double smootherstep(double t) @safe pure nothrow @nogc
{
    // 6t^5 - 15t^4 + 10t^3
    return t * t * t * (t * (t * 6 - 15) + 10);
}

/// Community's default `smooth`: a logistic sigmoid rescaled to [0,1] on [0,1].
double smoothSigmoid(double t, double inflection = 10.0) @safe pure nothrow @nogc
{
    double sig(double x) => 1.0 / (1.0 + exp(-x));
    const err = sig(-inflection * 0.5); // value at t=0, subtracted off
    return clamp((sig(inflection * (t - 0.5)) - err) / (1 - 2 * err), 0.0, 1.0);
}

double linear(double t) @safe pure nothrow @nogc => t;
double rushInto(double t) @safe pure nothrow @nogc => 2 * smootherstep(t / 2);
double rushFrom(double t) @safe pure nothrow @nogc => 2 * smootherstep(t / 2 + 0.5) - 1;

double thereAndBack(double t) @safe pure nothrow @nogc
    => t < 0.5 ? smootherstep(2 * t) : smootherstep(2 * (1 - t));

/// Manim's `get_sub_alpha`: submobject `i` of `n` under a given `lag_ratio`.
double subAlpha(double alpha, size_t i, size_t n, double lag) @safe pure nothrow @nogc
{
    const full = (n - 1) * lag + 1;
    return clamp(alpha * full - i * lag, 0.0, 1.0);
}

int main() @safe
{
    alias Fn = double function(double) @safe pure nothrow @nogc;
    const Fn[5] fns = [&linear, &smootherstep, &rushInto, &rushFrom, &thereAndBack];
    immutable string[5] names = ["linear", "smoother", "rushInto", "rushFrom", "there&back"];

    writeln("== rate functions over t in [0, 1] ==");
    writefln("   t    %-9s  %-9s  %-9s  %-9s  %-9s", names[0], names[1], names[2], names[3], names[4]);
    foreach (i; 0 .. 11)
    {
        const t = i / 10.0;
        writefln("  %4.1f  %8.4f   %8.4f   %8.4f   %8.4f   %8.4f",
            t, fns[0](t), fns[1](t), fns[2](t), fns[3](t), fns[4](t));
    }

    writeln("\n== fork divergence: ManimGL/community `smootherstep` vs community default `smooth` (sigmoid) ==");
    writeln("   t     smootherstep   smooth (sigmoid)   |Δ|");
    foreach (i; 0 .. 11)
    {
        const t = i / 10.0;
        const a = smootherstep(t), b = smoothSigmoid(t);
        writefln("  %4.1f    %8.4f       %8.4f       %6.4f", t, a, b, a > b ? a - b : b - a);
    }

    writeln("\n== smootherstep(t) as an ASCII curve (x = t, height = eased value) ==");
    foreach_reverse (row; 0 .. 11)
    {
        const level = row / 10.0;
        write("  ");
        foreach (col; 0 .. 41)
        {
            const t = col / 40.0;
            write(smootherstep(t) >= level - 0.05 && smootherstep(t) <= level + 0.05 ? '*' : ' ');
        }
        writefln(" %.1f", level);
    }
    writeln("  " ~ "----------------------------------------- t");

    writeln("\n== lag_ratio stagger: sub_alpha for 4 submobjects, lag_ratio 0.5 ==");
    writeln("  alpha  sub0     sub1     sub2     sub3");
    foreach (i; 0 .. 11)
    {
        const alpha = i / 10.0;
        writefln("  %4.1f   %6.3f   %6.3f   %6.3f   %6.3f", alpha,
            subAlpha(alpha, 0, 4, 0.5), subAlpha(alpha, 1, 4, 0.5),
            subAlpha(alpha, 2, 4, 0.5), subAlpha(alpha, 3, 4, 0.5));
    }
    writeln("  (lag_ratio 0 = all together; 1 = strict succession; 0.5 = overlap)");
    return 0;
}
