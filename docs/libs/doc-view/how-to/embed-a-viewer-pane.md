# Embed a viewer pane

A `DocViewPane` is a component the way a terminal pane is: you decide where it
sits, which pane has the focus and when it closes; the pane owns the document,
its scroll, its view toggles, folding and search, and paints only inside the
rect you give it. This is how `sparkles:terminal` mounts it
(`apps/terminal/src/workspace_host.d`).

## 1. Depend on the library and on the GPU backend

```sdl
dependency "sparkles:doc-view" path="../.."
// The pane compiles where the consumer names ui-raylib itself
// (`Have_sparkles_ui_raylib`), not merely through sparkles:ui-app.
dependency "sparkles:ui-raylib" path="../.."
```

## 2. Make one environment, then panes

The environment holds what every pane shares — the grammar registry, the
highlighting cache and the loader — and is heap-owned, because the cache points
at the registry:

```d
import sparkles.doc_view.pane : chromeTheme, DocViewEnv, DocViewPane, PaneKey;
import sparkles.syntax : GrammarRegistry;

auto env = DocViewEnv.create(GrammarRegistry.fromEnvironment());
auto pane = new DocViewPane;
if (!pane.open(env, "/path/to/README.md", chromeTheme(fg, bg)))
    // Still paintable: the pane shows `pane.error` where the document would be.
    log(pane.error);
```

`chromeTheme(fg, bg)` dresses the document in your chrome's colours, with the
built-in dark or light syntax colours chosen by the background. Call
`pane.setTheme` when your colours change.

Pass a reader to `DocViewEnv.create` when files do not come from the
filesystem — the terminal on Android serves `asset:credits/…` from the APK that
way, and sets `env.pipeline.includeRoot` to keep includes inside it.

## 3. Drive it each frame

```d
// Once a second at most: reload a file changed on disk (top line kept), or
// flag one that was deleted.
bool repaint = pane.poll() || pane.needsPaint;

// Keys that are not yours.
final switch (pane.key(keyEvent))
{
    case PaneKey.ignored: /* yours after all */ break;
    case PaneKey.handled: repaint = true; break;
    case PaneKey.close:   closeThePane(); break;  // `q` or `Esc`
}

// The wheel, or a touch drag, in rows (positive: further down the document).
pane.scrollBy(rows);

// Paint at window pixels, through your host's canvas.
auto c = h.canvas;
pane.paint(c, x, y, width, height, focused: true);
```

Call `pane.release()` before the window closes: an image pane holds a texture.

## What decides whether a file opens

`sparkles.doc_view.kind.viewKindOf(path)` answers before anything is loaded:
images by extension (`png`, `gif`, `qoi`), the loader's own kinds (markdown,
DSV, diffs, twoslash payloads), and any other file by its first bytes — valid
UTF-8 without NUL opens as source, highlighted when a grammar knows the
language; binary does not. The terminal hands a file it declines to the
platform's handler.
