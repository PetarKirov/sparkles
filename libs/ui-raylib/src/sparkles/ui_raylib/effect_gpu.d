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

import sparkles.ui.effect : EffectId, EffectRegistry, glslBackend;
import sparkles.ui.geometry : Rect;
import sparkles.ui_raylib.glsl : activePrologue;

/**
The wrapper every effect's GLSL twin is compiled into.

The twin supplies `vec3 effectColor(vec2 at, vec2 extent, vec3 color)`; this
supplies everything around it. `at` is in $(B cells), floored — the same
coordinate `Tier0Input.at` carries — so the terminal and the window run the
same transform over the same input and can be compared. Getting that wrong
would make the two halves of a twin silently disagree in a way only a
screenshot would show.
*/
private enum string effectEpilogue = q{
uniform sampler2D texture0;
uniform vec4 colDiffuse;
uniform vec2 uExtentCells;

void main()
{
    vec4 texel = SAMPLE(texture0, fragTexCoord) * colDiffuse * fragColor;
    vec2 at = floor(fragTexCoord * uExtentCells);
    OUT_COLOR = vec4(effectColor(at, uExtentCells, texel.rgb), texel.a);
}
};

/// One open bracket.
private struct OpenBracket
{
    Rect rect;            /// in cells, as the op carried it
    RenderTexture2D target;
    float savedOriginX;
    float savedOriginY;
    Shader shader;
    int extentLoc = -1;
    bool redirected;      /// false for a bracket we could not honour
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
        struct Compiled
        {
            Shader shader;
            int extentLoc = -1;
            bool ok;
        }

        // Keyed by nesting depth AND size: two brackets may share a texture
        // only when both agree, because the composite sources the whole of it.
        struct PoolKey
        {
            size_t depth;
            int w;
            int h;
        }

        const(EffectRegistry)* _registry;
        Compiled[uint] _shaders;
        RenderTexture2D[PoolKey] _pool;
        OpenBracket[] _open;
        RenderTexture2D _base;
        bool _hasBase;
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

        auto target = acquire(_open.length, w, h);
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

        _open ~= OpenBracket(rect: rectCells, target: target,
            shader: c.shader, extentLoc: c.extentLoc, redirected: true);
        return true;
    }

    /**
    Closes the innermost bracket and composites it back through its shader,
    at `(x, y)` in the enclosing target's pixels.

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
        if (_open.length)
            BeginTextureMode(_open[$ - 1].target);
        else if (_hasBase)
            BeginTextureMode(_base);

        BeginShaderMode(b.shader);
        if (b.extentLoc >= 0)
        {
            float[2] extent = [
                cast(float) b.rect.width, cast(float) b.rect.height];
            SetShaderValue(b.shader, b.extentLoc, extent.ptr,
                ShaderUniformDataType.SHADER_UNIFORM_VEC2);
        }
        // Negative source height: a render texture is stored bottom-up, and
        // drawing it the natural way puts the subtree on its head.
        const src = Rectangle(0, 0, cast(float) b.target.texture.width,
            cast(float) -b.target.texture.height);
        DrawTextureRec(b.target.texture, src,
            Vector2(cast(float) x, cast(float) y), Colors.WHITE);
        EndShaderMode();
        return true;
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
            if (c.ok)
                UnloadShader(c.shader);
        _shaders = null;
        foreach (ref t; _pool)
            if (t.id != 0)
                UnloadRenderTexture(t);
        _pool = null;
        _open = null;
    }

    private Compiled resolve(EffectId id) @system
    {
        if (auto hit = id.value in _shaders)
            return *hit;

        Compiled c;
        if (_registry !is null)
        {
            const rec = _registry.lookup(id);
            if (rec !is null)
                if (const impl = rec.implFor(glslBackend))
                {
                    const source = activePrologue ~ impl.source
                        ~ effectEpilogue ~ "\0";
                    c.shader = LoadShaderFromMemory(null, source.ptr);
                    if (c.shader.id != 0)
                    {
                        c.ok = true;
                        c.extentLoc = GetShaderLocation(c.shader,
                            "uExtentCells".ptr);
                    }
                }
        }
        // Cached either way: a shader that failed to compile must not be
        // recompiled sixty times a second for the rest of the run.
        _shaders[id.value] = c;
        return c;
    }

    // An EXACT-sized texture per (depth, size). See the note at the top of
    // this module: a texture larger than its bracket cannot be composited
    // back correctly with the one idiom that reliably un-flips a render
    // texture, so "big enough" is not good enough here.
    private RenderTexture2D acquire(size_t level, int w, int h) @system
    {
        const key = PoolKey(level, w, h);
        if (auto hit = key in _pool)
            return *hit;
        auto t = LoadRenderTexture(w, h);
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
