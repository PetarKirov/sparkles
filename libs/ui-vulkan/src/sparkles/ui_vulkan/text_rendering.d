/**
How the canvas renders text, chosen at run time: how glyph coverage meets
the background, how outlines meet the pixel grid, and whether clusters are
shaped — with a loupe that shows the result pixel for pixel.

These are plain values with no device in sight, so an application that
offers them as settings (a text lab, a preferences pane) names them without
depending on Vulkan.
*/
module sparkles.ui_vulkan.text_rendering;

@safe pure nothrow @nogc:

/// How a glyph's coverage meets what is under it.
enum Compositing : ubyte
{
    /// Coverage as alpha, blended in gamma-encoded space: what stb_truetype
    /// and the raylib arm do. Light text on dark looks thin, dark on light heavy.
    gamma,
    /// Blended in linear light against the text's background: physically
    /// right, and as heavy one way round as the other.
    linear,
    /// Linear, with the coverage's contrast raised by `TextRendering.contrast`:
    /// strokes keep their weight at small sizes.
    linearCorrected,
}

/// How a glyph's outline meets the pixel grid: `sparkles:font`'s own choice.
public import sparkles.font.hinting : Hinting;

/// The settings, together.
struct TextRendering
{
    Compositing compositing = Compositing.linearCorrected; ///
    Hinting hinting = Hinting.light;                       ///
    bool shaping = true; /// clusters shaped where a shaper is available
    /// For `linearCorrected`: how far coverage is pushed from mid-grey, 0–1.
    float contrast = 0.25f;
}

/**
A loupe: the target's pixels in `source` drawn `scale` times larger with
their top-left at (`x`, `y`), after everything else — each pixel a
`scale` × `scale` block, exactly as it was composited. Both are in pixels
from the frame's origin, as a pixel fill's are.
*/
struct Loupe
{
    bool shown; ///
    int sourceX, sourceY, sourceWidth, sourceHeight; ///
    int x, y;      ///
    int scale = 8; ///
}
