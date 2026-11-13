# Source views

`sparkles:source-view` turns source highlighting and Markdown into shared UI
widgets. It also supplies revision-aware highlighting and background language
discovery for editors. See the [library documentation](../../docs/libs/source-view/index.md).

Language discovery keeps filesystem work off the frame thread. This example
uses an empty registry so it runs without an installed grammar bundle; use
`GrammarRegistry.fromEnvironment()` for the desktop bundle.

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_source_view_languages"
    dependency "sparkles:source-view" version="*"
+/

import core.thread : Thread;
import core.time : msecs;
import std.stdio : writeln;
import sparkles.source_view.language_catalog : LanguageCatalog;
import sparkles.syntax.ts.registry : GrammarRegistry;

void main()
{
    auto catalog = new LanguageCatalog(GrammarRegistry.fromDirs([]));
    scope (exit) catalog.shutdown();
    while (!catalog.ready)
    {
        catalog.poll();
        if (catalog.busy) Thread.sleep(1.msecs);
    }
    if (catalog.error.length) throw new Exception(catalog.error);
    writeln(catalog.names.length, " languages; Plain text is always available.");
}
```

```ansi
0 languages; Plain text is always available.
```
