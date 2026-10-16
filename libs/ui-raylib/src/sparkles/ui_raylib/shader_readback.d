/**
Host/device agreement on a real GL driver (`sparkles:shaders` `SHV7`, `SHF4`).

A probe package (`tests/shader-readback/`) — one fragment entry point per
group of built-ins — is compiled by `shader-compile` exactly as a consumer's
shaders are. Each probe reads its
arguments from a float input texture, one sample per texel, so the device sees
precisely the inputs the host does, and writes its results to a float render
target. The host evaluates the same `sparkles.shaders` functions on the same
inputs, and each result must agree within the bound
[`decisions.md`](../../../../../../docs/specs/shaders/decisions.md) `D12` sets
for that operation. Both dialects the step writes are read back, GLSL 3.30
and GLSL ES 1.00.

Test-only. It needs a GL context (a display — a virtual one in CI) and the
device toolchain, and skips without either.
*/
module sparkles.ui_raylib.shader_readback;

version (unittest):

import std.file : exists, readText, rmdirRecurse, tempDir;
import std.format : format;
import std.math : abs, fabs, nextUp, PI;
import std.path : buildNormalizedPath, buildPath, dirName;
import std.process : environment, execute;

import raylib;
import raylib.rlgl;

import sparkles.base.text.cstring : toTempStringz;
import sparkles.shaders : clamp, cos, dot, exp, floor, fract, length, luma, max, min, mix,
    mod, pow, sin, smoothstep, sqrt, step, v2, v3;
import sparkles.test_runner.skip : skipTest;

private enum repoRoot = __FILE_FULL_PATH__.dirName.buildNormalizedPath("..", "..", "..", "..", "..");

/// Samples per probe: one texel each, in a single row, so the render
/// target's vertical flip cannot reorder them.
private enum size_t samples = 256;

/// What the host computes for one probe, from the sample `a`.
private alias HostFn = float[] function(float[4] a) @safe pure nothrow;

/// How a device result may differ from the host's (`D12`).
private enum Bound : ubyte
{
    unused,     /// the channel carries nothing
    exact,      /// identical bits
    ulps8,      /// a few correctly rounded operations: 8 ULP of the largest of result, arguments and 1
    sinCos,     /// absolute 2^-11, inside [-π, π]
    exp,        /// (3 + 2|x|) ULP
    pow,        /// relative 2^-17, for x in [0.5, 4], y in [-2, 2]
}

private struct Probe
{
    string entry;
    HostFn host;
    Bound[4] bounds;
    /// Fills sample `i` of `n` with this probe's arguments.
    float[] function(size_t i, size_t n) @safe pure nothrow input;
    /// Sets the probe's uniforms, if it has any.
    void function(Shader) @system uniforms;
}

/// `probeUniforms`' uniforms, set by name as a host binds them: an `int`, and
/// the members of a struct holding an `int` and a `vec3` (`SHF2`, `SHF5`).
private void setLight(Shader shader) @system
{
    void set(T)(string name, T value, ShaderUniformDataType type)
    {
        const at = GetShaderLocation(shader, name.toTempStringz.ptr);
        assert(at >= 0, "probeUniforms has no uniform `" ~ name ~ "`");
        SetShaderValue(shader, at, &value, type);
    }

    set("count", -3, ShaderUniformDataType.SHADER_UNIFORM_INT);
    set("light.gain", 2.5f, ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
    set("light.bias", 7, ShaderUniformDataType.SHADER_UNIFORM_INT);
    float[3] tint = [0.25f, 0.5f, 0.75f];
    set("light.tint", tint, ShaderUniformDataType.SHADER_UNIFORM_VEC3);
}

private float lerp(float lo, float hi, size_t i, size_t n) @safe pure nothrow @nogc
    => lo + (hi - lo) * (i + 0.37f) / n; // off the grid, so no sample sits on a step

private immutable Probe[] probes = [
    Probe("probeSample", (a) => a.dup, [Bound.exact, Bound.exact, Bound.exact, Bound.exact],
        (i, n) => [lerp(-5, 5, i, n), lerp(0, 1, i, n), lerp(-1e6, 1e6, i, n), lerp(1e-6, 1e-3, i, n)]),
    Probe("probeTranscendental",
        (a) => [sin(a[0]), cos(a[0]), exp(a[1]), sqrt(a[2])],
        [Bound.sinCos, Bound.sinCos, Bound.exp, Bound.ulps8],
        (i, n) => [lerp(-PI, PI, i, n), lerp(-10, 10, i, n), lerp(0, 100, i, n), 0.0f]),
    Probe("probePow", (a) => [pow(a[0], a[1]), pow(a[2], a[3]), 0.0f, 1.0f],
        [Bound.pow, Bound.pow, Bound.unused, Bound.unused],
        (i, n) => [lerp(0.5f, 4, i, n), lerp(-2, 2, (i * 7) % n, n),
            lerp(0.5f, 4, (i * 13) % n, n), lerp(-2, 2, i, n)]),
    Probe("probeRounding", (a) => [floor(a[0]), fract(a[0]), abs(a[0]), mod(a[0], a[1])],
        [Bound.exact, Bound.ulps8, Bound.exact, Bound.ulps8],
        // x/y is at least a quarter away from an integer, where one rounding
        // of the quotient would move floor() by one and mod by a whole y.
        (i, n) => [(cast(int) (i % 12) - 6 + 0.25f + 0.5f * ((i * 7) % n) / n) * 1.75f, 1.75f,
            0.0f, 0.0f]),
    Probe("probeSelect", (a) => [min(a[0], a[1]), max(a[0], a[1]), clamp(a[0], -1.0f, 1.0f),
            step(a[1], a[0])],
        [Bound.exact, Bound.exact, Bound.exact, Bound.exact],
        (i, n) => [lerp(-3, 3, i, n), lerp(3, -3, (i * 5) % n, n), 0.0f, 0.0f]),
    Probe("probeCompound", (a) => [mix(a[0], a[1], a[2]), smoothstep(-1.0f, 1.0f, a[0]),
            dot(v2(a[0], a[1]), v2(a[2], a[3])), length(v2(a[0], a[1]))],
        [Bound.ulps8, Bound.ulps8, Bound.ulps8, Bound.ulps8],
        (i, n) => [lerp(-2, 2, i, n), lerp(5, -5, (i * 3) % n, n), lerp(0, 1, (i * 11) % n, n),
            lerp(-1, 1, (i * 17) % n, n)]),
    Probe("probeLuma", (a) => [luma(v3(a[0], a[1], a[2])), 0.0f, 0.0f, 1.0f],
        [Bound.ulps8, Bound.unused, Bound.unused, Bound.unused],
        (i, n) => [lerp(0, 1, i, n), lerp(1, 0, (i * 3) % n, n), lerp(0, 1, (i * 7) % n, n), 1.0f]),
    // The per-component forms with vector and widened scalar arguments.
    Probe("probeVectorForms", (a) => [
            step(0.5f, a[1]) + step(0.0f, a[3]),
            smoothstep(-2.0f, 2.0f, a[3]),
            mix(a[1], a[3], 0.75f),
            clamp(a[0], -1.0f, 1.0f) + min(a[3], 0.5f) + mod(a[1], 1.5f) + smoothstep(-1.0f, 1.0f, a[2])],
        [Bound.exact, Bound.ulps8, Bound.ulps8, Bound.ulps8],
        // the mod argument stays a quarter away from a multiple of 1.5
        (i, n) => [lerp(-2, 2, i, n), (cast(int) (i % 3) - 1 + 0.25f + 0.5f * ((i * 7) % n) / n) * 1.5f,
            lerp(-2, 2, (i * 11) % n, n), lerp(-1, 1, (i * 3) % n, n)]),
    // count + bias = 4; gain 2.5; tint (0.25, 0.5, 0.75)
    Probe("probeUniforms", (a) => [a[0] * 2.5f + 4.0f, a[1] * 0.5f, 0.75f, 1.0f],
        [Bound.ulps8, Bound.exact, Bound.exact, Bound.unused],
        (i, n) => [lerp(-10, 10, i, n), lerp(-1, 1, (i * 3) % n, n), 0.0f, 0.0f], &setLight),
];

/// The size of one unit in the last place at `x`.
private float ulp(float x) @safe pure nothrow @nogc
{
    const m = fabs(x);
    return nextUp(m) - m;
}

/// Whether `device` agrees with `host` under `b`: `x` is `exp`'s argument, and
/// `scale` the largest argument magnitude (at least 1).
private bool agrees(Bound b, float device, float host, float x, float scale = 1)
    @safe pure nothrow @nogc
{
    final switch (b)
    {
        case Bound.unused: return true;
        case Bound.exact: return device == host || (device != device && host != host);
        case Bound.ulps8: return fabs(device - host) <= 8 * ulp(max(fabs(host), scale));
        case Bound.sinCos: return fabs(device - host) <= 1.0f / 2048;
        case Bound.exp: return fabs(device - host) <= (3 + 2 * fabs(x)) * ulp(host);
        case Bound.pow: return fabs(device - host) <= fabs(host) / (1 << 17);
    }
}

///
@("ui_raylib.shader_readback.boundsAcceptTheirLimitAndNoMore")
@safe pure nothrow @nogc unittest
{
    assert(agrees(Bound.exact, 1.5f, 1.5f, 0) && !agrees(Bound.exact, 1.5f, nextUp(1.5f), 0));
    assert(agrees(Bound.sinCos, 0.5f + 1.0f / 4096, 0.5f, 0));
    assert(!agrees(Bound.sinCos, 0.5f + 1.0f / 1024, 0.5f, 0));
    assert(agrees(Bound.ulps8, 1.0f + 8 * ulp(1.0f), 1.0f, 0));
    assert(!agrees(Bound.ulps8, 1.0f + 9 * ulp(1.0f), 1.0f, 0));
    assert(agrees(Bound.exp, 100.0f + 23 * ulp(100.0f), 100.0f, 10));
    assert(!agrees(Bound.exp, 100.0f + 24 * ulp(100.0f), 100.0f, 10));
}

/// The two dialects the build step writes, each read back on the same
/// driver. GLSL links only shaders of one dialect, so the GLSL ES 1.00 output
/// is paired with a GLSL ES vertex stage that hands it `fragTexCoord` under
/// raylib's attribute names; the GLSL 3.30 output takes raylib's own.
private struct Dialect
{
    string suffix;
    string vertex;

    enum desktop = Dialect(".frag", null);
    enum es = Dialect(".es.frag", q{#version 100
        attribute vec3 vertexPosition;
        attribute vec2 vertexTexCoord;
        uniform mat4 mvp;
        varying highp vec2 fragTexCoord;
        void main()
        {
            fragTexCoord = vertexTexCoord;
            gl_Position = mvp * vec4(vertexPosition, 1.0);
        }
    });
}

/// Compiles the probe package (`tests/shader-readback/`) with `shader-compile`,
/// in place; the directory holding `<entry>.frag`.
private string compileProbes(string root)
{
    const out_ = root.buildPath("generated");
    // Asked for, the readback must run: a missing tool is the step's to name
    // (exit 3), and a failure here, not a skip.
    const r = execute(["dub", "run", "-q", "--temp-build", "--root=" ~ repoRoot.buildPath("apps", "shader-compile"),
        "--", "--package=" ~ repoRoot.buildPath("libs", "ui-raylib", "tests", "shader-readback"),
        "--out=" ~ out_, "--quiet"]);
    assert(r.status == 0, "SPARKLES_GPU_READBACK=1, but the probes did not compile:\n" ~ r.output);
    return out_;
}

@("ui_raylib.shader_readback.hostAndDeviceAgree")
@system unittest
{
    import core.stdc.stdlib : free;
    import std.process : thisProcessID;

    if (environment.get("SPARKLES_GPU_READBACK", "") != "1")
        return skipTest("a GPU readback is opt-in: SPARKLES_GPU_READBACK=1, under a display");
    const root = buildPath(tempDir, format("sparkles-shader-readback-%s", thisProcessID));
    if (root.exists)
        root.rmdirRecurse;
    scope (exit) root.rmdirRecurse;
    const glsl = compileProbes(root);

    SetTraceLogLevel(TraceLogLevel.LOG_WARNING);
    SetConfigFlags(ConfigFlags.FLAG_WINDOW_HIDDEN);
    InitWindow(cast(int) samples, 1, "sparkles shader readback");
    if (!IsWindowReady())
        assert(false, "SPARKLES_GPU_READBACK=1, but no GL context could be created (a display, and a GL driver?)");
    scope (exit) CloseWindow();

    enum fmt = PixelFormat.PIXELFORMAT_UNCOMPRESSED_R32G32B32A32;
    const target = rlLoadTexture(null, cast(int) samples, 1, fmt, 1);
    const fbo = rlLoadFramebuffer();
    rlFramebufferAttach(fbo, target, rlFramebufferAttachType.RL_ATTACHMENT_COLOR_CHANNEL0,
        rlFramebufferAttachTextureType.RL_ATTACHMENT_TEXTURE2D, 0);
    assert(rlFramebufferComplete(fbo), "a float render target is required");
    scope (exit) { rlUnloadFramebuffer(fbo); rlUnloadTexture(target); }
    auto rt = RenderTexture2D(fbo, Texture2D(target, cast(int) samples, 1, 1, fmt));

    string[] failures;
    size_t checked;
    foreach (dialect; [Dialect.desktop, Dialect.es])
    foreach (ref p; probes)
    {
        float[samples * 4] input;
        foreach (i; 0 .. samples)
            input[i * 4 .. i * 4 + 4] = p.input(i, samples);
        const inTex = rlLoadTexture(input.ptr, cast(int) samples, 1, fmt, 1);
        scope (exit) rlUnloadTexture(inTex);
        const source = glsl.buildPath(p.entry ~ dialect.suffix).readText;
        const z = source.toTempStringz;
        const vz = dialect.vertex.toTempStringz;
        auto shader = LoadShaderFromMemory(dialect.vertex is null ? null : vz.ptr, z.ptr);
        assert(IsShaderValid(shader), p.entry ~ dialect.suffix ~ ": the generated shader did not link");
        scope (exit) UnloadShader(shader);
        if (p.uniforms !is null)
            p.uniforms(shader);

        BeginTextureMode(rt);
        ClearBackground(Colors.BLANK);
        BeginShaderMode(shader);
        // No blending: the probe writes its results, and alpha blending would
        // scale every channel by the fourth.
        rlDisableColorBlend();
        DrawTexturePro(Texture2D(inTex, cast(int) samples, 1, 1, fmt),
            Rectangle(0, 0, samples, 1), Rectangle(0, 0, samples, 1), Vector2(0, 0), 0, Colors.WHITE);
        rlDrawRenderBatchActive();
        rlEnableColorBlend();
        EndShaderMode();
        EndTextureMode();

        auto pixels = cast(float*) rlReadTexturePixels(target, cast(int) samples, 1, fmt);
        assert(pixels !is null, "readback failed");
        scope (exit) free(pixels);
        foreach (i; 0 .. samples)
        {
            const a = input[i * 4 .. i * 4 + 4];
            const want = p.host(a[0 .. 4]);
            float scale = 1;
            foreach (v; a)
                scale = max(scale, fabs(v));
            foreach (c; 0 .. 4)
            {
                const got = pixels[i * 4 + c];
                if (p.bounds[c] == Bound.unused)
                    continue;
                ++checked;
                if (!agrees(p.bounds[c], got, want[c], a[1], scale) && failures.length < 20)
                    failures ~= format("%s%s[%s].%s: device %.9g host %.9g (args %s, bound %s)",
                        p.entry, dialect.suffix, i, "xyzw"[c], got, want[c], a, p.bounds[c]);
            }
        }
    }
    assert(failures.length == 0, format("%s disagreements of %s checked:\n%-(%s\n%)",
        failures.length, checked, failures));
}
