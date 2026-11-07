/**
The one seam between hue's window code and the arm that draws it (`P2.B4`).

`gui.d` reads its window — size, frame time, title, pointer, a screenshot,
what its input offers, the soft keyboard and the clipboard — its cell font's
metrics, and makes canvases, and nothing else of the backend: this module is
that list. A phone is one more target behind it: the native host knows its
touchscreen, keyboard and insets; on the raylib APK this module stands in for
what raylib lacks there (`version (Android)` in the raylib half only). The Vulkan arm (`HueGuiVulkan`, the
default `application` configuration) wraps the native host and its canvas;
the raylib arm (the `raylib` configuration) wraps the window, the face set
and the effect backend the arm publishes. Either way `GuiCanvas` satisfies the canvas concept
(`isCanvas`) plus the pixel fill hue's chrome takes (`fillPixels`).

The CRT is `sparkles.ui.crt`'s effect on both: the raylib arm's effect backend
runs its GLSL passes, the native canvas its SPIR-V ones (`UVK15`), and each
arm hides the window system's pointer while the tube draws its own.
*/
module gui_surface;

version (HueGui):

import sparkles.base.buffer : SharedBuffer;
import sparkles.base.term_color : RgbColor;
import sparkles.base.term_control : PointerShape;
import sparkles.input.capability : InputCapabilities, mousePointer, touchPointer;

version (HueGuiVulkan)
{
    import sparkles.ui.geometry : Size;
    import sparkles.ui_app.native_loop : NativeCanvas, NativeHost;
    import sparkles.ui_vulkan.painter : rgba;

    /**
    The native canvas at a pixel origin: hue anchors some chrome to a pixel
    that is not a whole cell (a panel hung off the window's bottom edge, a
    popup beside the pointer). Every call is forwarded, the origin applied
    around it as a pixel offset, so a primitive the canvas lacks is one this
    value lacks too — the painter's introspection sees the same set.
    */
    struct GuiCanvas
    {
        NativeCanvas* canvas;
        int originX, originY; /// pixels

        /// A solid rectangle in window pixels (the origin does not apply:
        /// chrome is window-positioned).
        void fillPixels(int x, int y, int w, int h, RgbColor c, ubyte a = 0xFF) @system
        {
            if (w > 0 && h > 0)
                canvas.fillPx(x, y, w, h, rgba(c, a));
        }

        /// The run's extent in cells.
        Size measure(scope const(char)[] text) @system => canvas.measure(text);

        auto opDispatch(string name, Args...)(auto ref Args args)
            if (name != "measure" && name != "fillPixels")
        {
            const shifted = originX != 0 || originY != 0;
            if (shifted)
                canvas.pushOffsetPx(originX, originY);
            scope (exit)
                if (shifted)
                    canvas.popOffsetPx();
            return mixin("canvas." ~ name ~ "(args)");
        }
    }

    /// The native host's window, cell font and canvas.
    struct GuiSurface
    {
        NativeHost* host;

        int width() const @system => host.pixels.width;
        int height() const @system => host.pixels.height;
        float frameSeconds() const @system => host.frameSeconds;
        void title(in char[] t) @system { host.title(t); }
        /// The frame's ground: a fill over the whole window.
        void clear(RgbColor c) @system
        {
            if (auto canvas = host.canvas)
                canvas.fillPx(0, 0, width, height, rgba(c, 0xFF));
        }
        /// Drops every clip the frame has open: what the raylib arm's global
        /// scissor reset is, for chrome painted over a pane that clipped.
        void resetClip() @system
        {
            if (auto canvas = host.canvas)
                canvas.resetClips();
        }
        void toggleFullscreen() @system { host.toggleFullscreen(); }
        void screenshot(in char[] path) @system { host.screenshot(path); }
        void pointerShape(PointerShape shape) @system { host.pointerShape(shape); }
        void pointerVisible(bool on) @system { host.pointerVisible(on); }

        int cellW() const @system => host.cellWidth;
        int cellH() const @system => host.cellHeight;
        int size() const @system => host.fontSizePx;
        void reload(int px) @system { host.fontSize(px); }
        /// The raylib arm grows its atlas after a frame; this arm's glyphs
        /// are prepared as they are drawn, so nothing waits.
        bool flushPending() @system => false;

        void clipboard(in char[] text) @system { host.clipboard(text); }
        /// Reading the clipboard is a request answered by an event on this
        /// arm (`INP25`): the text arrives as `PasteEvent`s carrying `request`.
        void readClipboard(uint request) @system { host.readClipboard(request); }
        /// Every window system this arm opens on streams the clipboard.
        enum clipboardReadable = true;

        /// What the target's input offers (`TGT5`): a touchscreen on a phone.
        InputCapabilities capabilities() const @system => host.capabilities;
        /// Asks for the soft keyboard or puts it away: the host's text input,
        /// whose commits arrive as typed keys.
        void softKeyboard(bool show) @system { host.textInput(show); }
        /// The height the layout fills. The host's surface already ends
        /// above whatever covers it, the soft keyboard included (`EDI9`).
        int visibleHeight(bool keyboardUp) const @system => height;

        GuiCanvas canvasAt(float x = 0, float y = 0, bool effects = false) @system
            => GuiCanvas(host.canvas, cast(int) x, cast(int) y);
    }
}
else
{
    import sparkles.raylib_text : FontSet;
    import sparkles.ui_raylib : RaylibCanvas, Window;
    import sparkles.ui_raylib.effect_gpu : EffectGpu;

    alias GuiCanvas = RaylibCanvas;

    /// The raylib arm's window, face set and effect backend.
    struct GuiSurface
    {
        Window* window;
        FontSet* fonts;
        EffectGpu* fx;
        SharedBuffer!(char, 4096)* buf;

        int width() const @system => window.width;
        int height() const @system => window.height;
        float frameSeconds() const @system => window.frameSeconds;
        void title(in char[] t) @system { window.title(t); }
        void clear(RgbColor c) @system { window.clear(c); }
        void resetClip() @system { window.resetClip(); }
        void toggleFullscreen() @system { window.toggleFullscreen(); }
        void screenshot(in char[] path) @system { window.screenshot(path); }
        void pointerShape(PointerShape shape) @system { window.pointerShape(shape); }
        void pointerVisible(bool on) @system { window.pointerVisible(on); }

        int cellW() const @system => fonts.cellW();
        int cellH() const @system => fonts.cellH();
        int size() const @system => fonts.size();
        void reload(int px) @system { fonts.reload(px); }
        bool flushPending() @system => fonts.flushPending();

        /// raylib's Android SetClipboardText is an unimplemented no-op (a
        /// TRACELOG warning — see rcore_android.c), so the APK goes through
        /// the JNI ClipboardManager bridge instead.
        void clipboard(in char[] text) @system
        {
            version (Android)
            {
                import android_glue : setClipboardText;
                import sparkles.base.logger : warning;

                if (!setClipboardText(text))
                    warning(i"copy: JNI clipboard bridge failed");
            }
            else
                window.clipboard(text);
        }
        string clipboardText() @system => window.clipboardText();
        /// The APK's bridge only writes, so a field there offers no paste
        /// chord (`EDI5`).
        version (Android)
            enum clipboardReadable = false;
        else
            enum clipboardReadable = true;

        /// What the target's input offers (`TGT5`): raylib reports the APK's
        /// first finger as its mouse, and hue reads that as a touchscreen.
        InputCapabilities capabilities() const @system
        {
            version (Android)
                return touchPointer;
            else
                return mousePointer;
        }

        /// Asks for the soft keyboard or puts it away (the APK's JNI field;
        /// a desktop window has none to ask for).
        void softKeyboard(bool show) @system
        {
            version (Android)
            {
                import sparkles.android.soft_input : hideSoftKeyboard, showSoftKeyboard;

                if (show)
                    cast(void) showSoftKeyboard();
                else
                    hideSoftKeyboard();
            }
        }

        /// The window's height above the soft keyboard while an editor has it
        /// up (`EDI9`). The APK's window is full-screen, so the input method
        /// does not resize it; its inset says how much of the bottom it covers.
        int visibleHeight(bool keyboardUp) const @system
        {
            version (Android)
            {
                import sparkles.android.window_metrics : windowInsets;

                if (keyboardUp)
                {
                    const insets = windowInsets();
                    const covered = insets.known ? insets.keyboard[3] : 0;
                    if (covered > 0 && covered < height)
                        return height - covered;
                }
            }
            return height;
        }

        /// A canvas whose cell column 0 is at pixel `(x, y)`; with `effects`,
        /// one that paints through the effect backend (the CRT's bracket).
        GuiCanvas canvasAt(float x = 0, float y = 0, bool effects = false) @system
        {
            auto c = RaylibCanvas(fonts, buf, fonts.cellW(), fonts.cellH(), x, y);
            if (effects)
                c.fx = fx;
            return c;
        }
    }
}
