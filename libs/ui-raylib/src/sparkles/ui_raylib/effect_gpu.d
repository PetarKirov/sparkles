/**
The GPU side of `EFX`: one render texture per open effect bracket, and the
shader that resolves it (`EFX11`).

$(B What a tier-1/2 effect needs that a tier-0 one does not) is somewhere to
read the rendered subtree from. So `pushEffect` redirects drawing into a
texture the size of the bracket, and `popEffect` draws that texture back
through the effect's fragment shader. A cell grid needs none of this, which is
exactly what the tier model says.

$(B Textures are pooled by (depth, size)), and are always $(I exactly) the
bracket's size. `EFX11` asks for no more than one texture per nesting level,
and pooling by depth alone would give that — but a pooled texture bigger than
the bracket is a correctness trap, not just waste: the only reliable way to
draw a render texture right-side up is to source the whole of it with a
negative height, and a bracket occupying part of a larger texture composites
back from the wrong region. It looked like the subtree had lost its bottom
half. So the size is part of the key, sharing happens between brackets that
agree on it, and the count is bounded by the distinct bracket sizes a frame
actually uses rather than by the number of brackets.

$(B The framebuffer stack is ours, because raylib has none.)
`EndTextureMode` binds the default framebuffer rather than the enclosing
target, so nesting has to be tracked here and the parent re-bound by hand.
$(LREF EffectGpu.baseTarget) is how a host that is already rendering into a
texture of its own says so — without it, closing the first bracket would drop
the rest of the frame onto the screen.
*/
module sparkles.ui_raylib.effect_gpu;

import raylib;
import raylib.rlgl : rlDisableScissorTest, rlDrawRenderBatchActive,
    rlEnableScissorTest, rlScissor;

import sparkles.ui.effect : EffectId, EffectImpl, EffectParam, EffectPass,
    EffectRecord, EffectRegistry, glslBackend, previousImage;
import sparkles.ui.geometry : Rect;

// An effect's `glsl` artifact is a complete fragment shader against raylib's
// pipeline (`fragTexCoord`/`fragColor` in, `texture0`, `finalColor` out, and
// `uExtentCells` for a tier-0 transform's cell position) — generated from the
// effect's D function by `shader-compile` for the built-ins (`EFX20`), in
// the dialect this build's GL speaks. Nothing is wrapped around it here: the
// tier is what the shader $(I does), not what this backend prepends to it.

/// One open bracket.
private struct OpenBracket
{
    Rect rect;            /// in cells, as the op carried it
    RenderTexture2D target;
    EffectId id;
    bool redirected;      /// false for a bracket we could not honour
}

/// One compiled pass, with the uniform locations it declared. A location of
/// `-1` means the shader does not read that uniform, and nothing is uploaded.
private struct Program
{
    Shader shader;
    int extentLoc = -1;     /// `uExtentCells`
    int resolutionLoc = -1; /// `uResolution`
    int timeLoc = -1;       /// `uTime`
    int[] samplerLocs;      /// `texture1`, `texture2`, … for `EffectPass.inputs`
    int[string] paramLocs;  /// by `EffectParam.name`
}

/// How one pass is run: the program, and which images it reads.
private struct Stage
{
    Program program;
    int downscale = 1;
    size_t from;            /// resolved: never `previousImage`
    size_t[] inputs;
}

/**
Compiled effect shaders and the render-texture pool, living across frames.

Borrows the registry. $(LREF release) frees every GL object and must run while
the context is alive.
*/
struct EffectGpu
{
    private
    {
        // An effect's passes, compiled. One stage for a tier-0/1 artifact.
        struct Compiled
        {
            Stage[] stages;
            bool ok;
        }

        // Keyed by nesting depth, STAGE and size: two brackets may share a
        // texture only when all agree, because a pass sources the whole of
        // it. Stage 0 is the bracket's own texture; stage k is where pass k-1
        // of a multi-pass effect renders. A nested bracket is a different
        // depth, so it can never be handed an intermediate of its parent's.
        struct PoolKey
        {
            size_t depth;
            size_t stage;
            int w;
            int h;
        }

        const(EffectRegistry)* _registry;
        Compiled[uint] _shaders;
        RenderTexture2D[PoolKey] _pool;
        OpenBracket[] _open;
        RenderTexture2D _base;
        bool _hasBase;
        float _time = 0;
    }

    /**
    Sets the frame clock every pass reading `uTime` sees, in seconds.

    The host calls this once per frame. A capture pins it to a constant, which
    is what makes an animated effect's screenshot reproducible (`DBG1`): the
    CRT's jitter, roll and flicker all read it, and an unpinned clock made
    every byte-comparison of two captures report a difference that was not
    there.
    */
    void clock(float seconds) @safe pure nothrow @nogc
    {
        _time = seconds;
    }

    /// Binds the registry this resolves ids against. Borrowed, not owned.
    void attach(const(EffectRegistry)* registry) @safe nothrow @nogc
    {
        _registry = registry;
    }

    /**
    Declares the texture the host is already rendering into, so closing a
    bracket returns there rather than to the screen. Call with no argument at
    the end of a frame to clear it.
    */
    void baseTarget(RenderTexture2D target) @safe nothrow @nogc
    {
        _base = target;
        _hasBase = target.id != 0;
    }

    /// ditto
    void clearBaseTarget() @safe nothrow @nogc
    {
        _hasBase = false;
    }

    /// How deep the open brackets currently go — the pool's high-water mark.
    size_t depth() const @safe pure nothrow @nogc => _open.length;

    /// Whether `id` has a shader this backend can run. `false` means the
    /// bracket degrades to unaffected (`EFX3`).
    bool canHonour(EffectId id) @system
        => resolve(id).ok;

    /**
    Opens a bracket: redirects drawing into a texture the size of `rectPx`.

    Returns `false` when the effect cannot be honoured, in which case nothing
    was redirected and the caller must still pair this with $(LREF close) —
    balance is the caller's, so an `EFX17` miss cannot desynchronise the stack.
    */
    bool open(EffectId id, in Rect rectCells, int x, int y, int w, int h)
        @system
    {
        auto c = resolve(id);
        if (!c.ok || w <= 0 || h <= 0)
        {
            _open ~= OpenBracket(rect: rectCells, redirected: false);
            return false;
        }

        auto target = acquire(_open.length + 1, 0, w, h);
        if (target.id == 0)
        {
            _open ~= OpenBracket(rect: rectCells, redirected: false);
            return false;
        }

        // Leave whatever framebuffer is current and enter ours. A scissor set
        // for the enclosing target names the wrong rectangle here, so it goes
        // off until the caller re-establishes one in this target's space.
        if (_open.length || _hasBase)
            EndTextureMode();
        rlDisableScissorTest();
        BeginTextureMode(target);
        ClearBackground(Color(0, 0, 0, 0));

        _open ~= OpenBracket(rect: rectCells, target: target, id: id,
            redirected: true);
        return true;
    }

    /**
    Closes the innermost bracket and composites it back through its shader,
    at `(x, y)` in the enclosing target's pixels.

    A multi-pass effect (`EffectPass`) runs its earlier passes first, each
    into an intermediate from the pool, before the last one composites. They
    run here, after the subtree is complete and before the parent target is
    re-entered, so the intermediates never interleave with the parent's
    drawing.

    Returns `false` when the bracket was never redirected — the caller then
    has nothing to do, because the subtree already painted where it belongs.
    */
    bool close(int x, int y) @system
    {
        if (!_open.length)
            return false;
        auto b = _open[$ - 1];
        _open = _open[0 .. $ - 1];
        if (!b.redirected)
            return false;

        EndTextureMode();
        rlDisableScissorTest();

        auto c = resolve(b.id);
        const level = _open.length + 1; // this bracket's depth in the pool
        const bw = b.target.texture.width, bh = b.target.texture.height;

        // Image 0 is the bracket; image k is pass k-1's output.
        Texture2D[] images = [b.target.texture];
        foreach (i, ref st; c.stages[0 .. $ - 1])
        {
            const ow = bw / st.downscale, oh = bh / st.downscale;
            auto into = acquire(level, i + 1, ow > 0 ? ow : 1, oh > 0 ? oh : 1);
            BeginTextureMode(into);
            ClearBackground(Color(0, 0, 0, 0));
            BeginShaderMode(st.program.shader);
            upload(b, st, into.texture.width, into.texture.height, images);
            drawFlipped(images[st.from], 0, 0,
                into.texture.width, into.texture.height);
            EndShaderMode();
            EndTextureMode();
            images ~= into.texture;
        }

        if (_open.length)
            BeginTextureMode(_open[$ - 1].target);
        else if (_hasBase)
            BeginTextureMode(_base);

        auto last = &c.stages[$ - 1];
        BeginShaderMode(last.program.shader);
        upload(b, *last, bw, bh, images);
        drawFlipped(images[last.from], x, y, bw, bh);
        EndShaderMode();
        return true;
    }

    // Everything a pass reads besides `texture0`, uploaded while its program
    // is ACTIVE — a uniform or sampler set before `BeginShaderMode` binds to
    // whichever program was current, which is the trap the CRT's bloom
    // sampler fell into and did nothing for a commit.
    private void upload(in OpenBracket b, ref Stage st, int outW, int outH,
        Texture2D[] images) @system
    {
        auto p = &st.program;
        if (p.extentLoc >= 0)
        {
            float[2] extent = [cast(float) b.rect.width, cast(float) b.rect.height];
            SetShaderValue(p.shader, p.extentLoc, extent.ptr,
                ShaderUniformDataType.SHADER_UNIFORM_VEC2);
        }
        if (p.resolutionLoc >= 0)
        {
            float[2] res = [cast(float) outW, cast(float) outH];
            SetShaderValue(p.shader, p.resolutionLoc, res.ptr,
                ShaderUniformDataType.SHADER_UNIFORM_VEC2);
        }
        if (p.timeLoc >= 0)
        {
            float t = _time;
            SetShaderValue(p.shader, p.timeLoc, &t,
                ShaderUniformDataType.SHADER_UNIFORM_FLOAT);
        }
        foreach (k, img; st.inputs)
            if (p.samplerLocs[k] >= 0)
                SetShaderValueTexture(p.shader, p.samplerLocs[k], images[img]);
        uploadParams(b.id, *p);
    }

    // Draws a render texture's contents into `(x, y, w, h)` of the current
    // target. Negative source height: a render texture is stored bottom-up,
    // and drawing it the natural way puts the subtree on its head. Every pass
    // draws its source this way, so every intermediate has the same
    // orientation as the bracket and a pass may sample any of them at the
    // same `fragTexCoord`.
    private static void drawFlipped(Texture2D t, int x, int y, int w, int h)
        @system
    {
        DrawTexturePro(t,
            Rectangle(0, 0, cast(float) t.width, cast(float) -t.height),
            Rectangle(cast(float) x, cast(float) y, cast(float) w, cast(float) h),
            Vector2(0, 0), 0.0f, Colors.WHITE);
    }

    /**
    Reports the innermost open bracket's rect, and whether it was actually
    redirected into a texture.

    A caller needs this $(I before) $(LREF close), because the position to
    composite at is in the enclosing target's coordinates and the caller has
    to restore its own origin first.
    */
    bool peek(out Rect rect) const @safe pure nothrow @nogc
    {
        if (!_open.length)
            return false;
        rect = _open[$ - 1].rect;
        return _open[$ - 1].redirected;
    }

    /// The pixel width of the target currently being drawn into, or `0` on
    /// the screen.
    int currentTargetWidth() const @safe pure nothrow @nogc
    {
        foreach_reverse (ref const b; _open)
            if (b.redirected)
                return b.target.texture.width;
        return _hasBase ? _base.texture.width : 0;
    }

    /// The pixel height of the target currently being drawn into, which
    /// `rlScissor` needs and `GetScreenHeight` cannot give inside a texture.
    int currentTargetHeight() const @safe pure nothrow @nogc
    {
        foreach_reverse (ref const b; _open)
            if (b.redirected)
                return b.target.texture.height;
        return _hasBase ? _base.texture.height : 0;
    }

    /// Frees every shader and pooled texture. Call while the context is alive.
    void release() @system
    {
        foreach (ref c; _shaders)
            foreach (ref st; c.stages)
                if (st.program.shader.id != 0)
                    UnloadShader(st.program.shader);
        _shaders = null;
        foreach (ref t; _pool)
            if (t.id != 0)
                UnloadRenderTexture(t);
        _pool = null;
        _open = null;
    }

    // `EFX21`: the values the artifact reads, refreshed every frame by the
    // application. Uploaded after `BeginShaderMode`, because a uniform binds
    // to the ACTIVE program — the same trap the CRT's bloom sampler fell into.
    private void uploadParams(EffectId id, ref Program p) @system
    {
        if (_registry is null)
            return;
        const rec = _registry.lookup(id);
        if (rec is null || rec.params.length == 0)
            return;
        foreach (ref prm; rec.params)
        {
            const loc = prm.name in p.paramLocs;
            if (loc is null || *loc < 0)
                continue;
            float[4] v = prm.value;
            const type = prm.arity >= 4
                ? ShaderUniformDataType.SHADER_UNIFORM_VEC4
                : prm.arity == 3 ? ShaderUniformDataType.SHADER_UNIFORM_VEC3
                : prm.arity == 2 ? ShaderUniformDataType.SHADER_UNIFORM_VEC2
                : ShaderUniformDataType.SHADER_UNIFORM_FLOAT;
            SetShaderValue(p.shader, *loc, v.ptr, type);
        }
    }

    private Compiled resolve(EffectId id) @system
    {
        if (auto hit = id.value in _shaders)
            return *hit;

        Compiled c;
        if (_registry !is null)
            if (const rec = _registry.lookup(id))
                if (const impl = rec.implFor(glslBackend))
                    c = compile(*rec, *impl);
        // Cached either way: a shader that failed to compile must not be
        // recompiled sixty times a second for the rest of the run.
        _shaders[id.value] = c;
        return c;
    }

    // One program per pass, or the one `source` for a single-pass artifact.
    // A pass that fails to compile fails the whole effect — half a bloom is
    // not a degradation anyone declared — and unloads what did compile.
    private static Compiled compile(in EffectRecord rec, in EffectImpl impl)
        @system
    {
        const(EffectPass)[] passes = impl.passes.length
            ? impl.passes : [EffectPass(impl.source)];

        Compiled c;
        foreach (i, ref pass; passes)
        {
            const from = pass.from == previousImage ? i : pass.from;
            bool inRange = from <= i;
            foreach (img; pass.inputs)
                inRange = inRange && img <= i;
            Program p;
            if (inRange)
                p = link(pass.source, pass.inputs.length, rec.params);
            if (p.shader.id == 0)
            {
                foreach (ref st; c.stages)
                    UnloadShader(st.program.shader);
                return Compiled.init;
            }
            size_t[] inputs;
            foreach (img; pass.inputs)
                inputs ~= img;
            c.stages ~= Stage(program: p,
                downscale: pass.downscale ? pass.downscale : 1,
                from: from, inputs: inputs);
        }
        c.ok = c.stages.length > 0;
        return c;
    }

    // Compiles one fragment shader and resolves the locations it declares.
    // Locations are fixed for the life of a program, so this is the only
    // place they are looked up.
    private static Program link(string source, size_t samplers,
        in EffectParam[] params) @system
    {
        Program p;
        const z = source ~ "\0";
        p.shader = LoadShaderFromMemory(null, z.ptr);
        if (p.shader.id == 0)
            return p;
        p.extentLoc = GetShaderLocation(p.shader, "uExtentCells".ptr);
        p.resolutionLoc = GetShaderLocation(p.shader, "uResolution".ptr);
        p.timeLoc = GetShaderLocation(p.shader, "uTime".ptr);
        foreach (k; 0 .. samplers)
        {
            char[16] name = 0;
            const n = "texture".length;
            name[0 .. n] = "texture";
            name[n] = cast(char)('1' + k);
            p.samplerLocs ~= GetShaderLocation(p.shader, name.ptr);
        }
        foreach (ref prm; params)
            p.paramLocs[prm.name] = GetShaderLocation(p.shader, (prm.name ~ "\0").ptr);
        return p;
    }

    // An EXACT-sized texture per (depth, size). See the note at the top of
    // this module: a texture larger than its bracket cannot be composited
    // back correctly with the one idiom that reliably un-flips a render
    // texture, so "big enough" is not good enough here.
    private RenderTexture2D acquire(size_t level, size_t stage, int w, int h)
        @system
    {
        const key = PoolKey(level, stage, w, h);
        if (auto hit = key in _pool)
            return *hit;
        auto t = LoadRenderTexture(w, h);
        // An intermediate is usually smaller than what samples it — bloom's
        // run at half size and are stretched back over the bracket — and a
        // nearest-texel lookup turns that into a halftone of 2×2 blocks.
        // The bracket's own texture (stage 0) is composited at exactly its
        // size, where the filter cannot matter, so it keeps the default.
        if (stage > 0 && t.id != 0)
            SetTextureFilter(t.texture, TextureFilter.TEXTURE_FILTER_BILINEAR);
        _pool[key] = t;
        return t;
    }
}

/// Sets the scissor correctly inside a render target of `targetHeight`
/// pixels — `BeginScissorMode` flips Y against the SCREEN, which is the wrong
/// height whenever a bracket is open.
void scissorInTarget(int x, int y, int w, int h, int targetHeight) @system
{
    // Flush first, as `BeginScissorMode` does: quads already queued were
    // drawn under the OLD scissor and must not inherit this one.
    rlDrawRenderBatchActive();
    rlEnableScissorTest();
    rlScissor(x, targetHeight - (y + h), w, h);
}
