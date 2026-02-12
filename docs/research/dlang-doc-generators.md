# D language documentation generators: a fragmented but capable ecosystem

**D's documentation tooling centers on four actively used generators, each with distinct trade-offs—but no single tool dominates.** The built-in DDoc system remains the official standard, while community alternatives like ddox, adrdox, and harbored-mod each address its shortcomings in different ways. Doxygen and Sphinx offer poor D support, making D-native tools the clear choice. As of early 2026, **adrdox produces the highest-quality output** and is the most actively maintained community tool, while ddox serves as the semi-official generator powering parts of dlang.org. The ecosystem's core tension: DDoc is universal but spartan, and the community hasn't converged on a single replacement.

---

## DDoc: the compiler-native foundation everything builds on

DDoc is the documentation generator built directly into the DMD compiler (and shared by LDC and GDC through the common frontend). Rather than generating HTML directly, DDoc operates as a **macro-based text-substitution system**—it formats documentation into macro calls that expand into HTML by default, but can be redefined to produce any output format including man pages, LaTeX, or plain text.

**Activation is straightforward.** The `-D` flag generates documentation, `-Dd<dir>` sets the output directory, `-Df<file>` specifies an output filename, and `-o-` suppresses object file generation (useful for doc-only builds). Running `dmd -D -o- foo.d` produces `foo.html` with zero external dependencies.

DDoc recognizes three comment styles: `///` (single-line), `/** */` (multi-line), and `/++ +/` (nesting). Comments attach to the next declaration by default, or to the current declaration if placed on the same line to its right. The `ditto` keyword copies documentation from the previous declaration. Standard sections include `Params:`, `Returns:`, `Throws:`, `Examples:`, `See_Also:`, `Bugs:`, and others, all following a `Name:` convention.

The macro system provides DDoc's power and its complexity. Macros use `$(MACRO_NAME arguments)` syntax with positional arguments (`$0` for all, `$1`–`$9` for individual, `$+` for everything after the first comma). Built-in macros cover formatting (`$(B bold)`, `$(I italic)`), linking (`$(LINK2 url, text)`), HTML structure (`$(TABLE ...)`, `$(DL ...)`), and D syntax highlighting (`$(D_CODE ...)`, `$(D_KEYWORD ...)`). The critical `DDOC` macro controls the entire page template—redefining it in a `.ddoc` file passed on the command line gives complete control over HTML structure, CSS inclusion, and page layout. The dlang.org website itself demonstrates this capability, using extensive `.ddoc` theming files to produce its full site layout.

**Markdown support arrived permanently in DMD 2.101.0** (November 2022), after being introduced as a preview in 2.085.0 (March 2019) and enabled by default in 2.094.0 (September 2020). This added headings (`#`–`######`), text emphasis, inline and reference-style links, ordered and unordered lists, pipe-delimited tables, block quotes, and images—significantly modernizing the comment syntax.

One of DDoc's most distinctive features is **documented unittest blocks**: a `unittest` block preceded by a `///` comment automatically appears as an executable example in the generated documentation, guaranteeing examples stay correct since they run during testing. The dlang.org website extends this further with editable, runnable examples powered by DPaste integration.

DDoc's limitations drive the existence of every alternative tool. Output is **one HTML file per module** with no per-symbol pages. There is **no built-in search**. Cross-referencing between modules requires manual setup of `DOC_ROOT_` macros. The parenthesis-sensitive macro system makes debugging difficult—unmatched parentheses silently corrupt output, and recursive expansion has hard limits. Template and mixin documentation remains challenging, and the default unstyled HTML output is widely described as "ugly" without custom CSS. These pain points have persisted for years.

**Official specification**: https://dlang.org/spec/ddoc.html
**Compiler source**: https://github.com/dlang/dmd/blob/master/compiler/src/dmd/doc.d

---

## ddox powers dlang.org but carries technical debt

ddox is the advanced documentation engine under the official `dlang` GitHub organization, created by **Sönke Ludwig** (creator of vibe.d) with significant contributions from Martin Nowak. It consumes DMD's JSON output (`-X -Xf` flags) rather than parsing D source directly, then generates **page-per-symbol HTML** using vibe.d's Diet template engine.

The tool's feature set directly addresses DDoc's biggest gaps. ddox provides automatic cross-referencing between symbols, a generated search database and sitemap, source code linking to GitHub file/line locations, symbol filtering by name patterns and protection level (`--min-protection Public`), and an integrated local web server for previewing documentation. It is natively integrated into DUB: running `dub build -b ddox` or `dub run -b ddox` generates and optionally serves documentation for any DUB project with zero additional configuration.

**ddox generates the official D standard library documentation** at dlang.org in a dual setup. The primary Phobos documentation at `dlang.org/phobos` uses traditional DDoc (one file per module), while `dlang.org/library` serves the ddox build (one file per symbol). The dlang.org Makefile explicitly notes that transitioning fully from DDoc to ddox is "a long-lasting effort" that has **stalled for years**, with blocking issues tracked at github.com/dlang/dlang.org/pull/1526.

The tool's dependence on DMD's JSON output creates inherited limitations. **User-defined attributes (UDAs) don't appear** in documentation. Declarations inside `static if` blocks are invisible. Modules lacking a documented `module` declaration are silently omitted. Complex types occasionally fail to parse, breaking cross-linking. These issues, many open since the project's early days, reflect DMD JSON output limitations that ddox cannot work around.

**Maintenance is semi-active.** The latest DUB release is v0.16.24 (October 2025), and the repository shows recent commits from both `s-ludwig` (Sönke Ludwig) and `thewilsonator`. With **457,165 total DUB downloads** and ~124 downloads/day, it remains heavily used. However, **68 open issues** signal a maintenance backlog.

**Repository**: https://github.com/dlang/ddox
**DUB package**: https://code.dlang.org/packages/ddox

---

## adrdox delivers the best output quality through direct source parsing

adrdox, created and maintained by **Adam D. Ruppe**, takes a fundamentally different architectural approach: it **directly parses D source code** using a bundled copy of DScanner's libdparse library, giving it access to the full AST rather than depending on DMD's limited JSON output. This design decision enables it to document constructs that ddox misses—public imports, postblits, destructors, anonymous enums, and inline parameter documentation.

The tool uses a **hybrid DDoc + Markdown syntax** with substantial extensions. Cross-referencing uses Wikipedia-inspired `[symbol]` bracket syntax (with `[symbol|alt text]` for custom labels). Code blocks support multi-language syntax highlighting for D, C, C++, Python, JavaScript, and others. **LaTeX/KaTeX math** is supported via `--tex-math`. Side-by-side code comparisons use `$(SIDE_BY_SIDE $(COLUMN ...))`. Rich table formats include pipe tables and reStructuredText-inspired list tables.

Search is a first-class feature: the `-i` flag generates a full-text search index that works client-side via JavaScript or server-side through the bundled `locate.d` component. Output is customizable through `skeleton.html` templates and `style.css` files. A `--blog-mode` flag repurposes the tool as a static site generator.

adrdox powers **dpldocs.info**, the unofficial documentation site that automatically generates and hosts documentation for any DUB package. Visiting `packagename.dpldocs.info` produces adrdox-rendered documentation on demand. This covers a large portion of the D package ecosystem. In community forum discussions, users who have tested multiple tools consistently rate adrdox as producing **the most visually appealing and navigable output**. GtkD uses it for official documentation, and Adam Ruppe is known for rapid bug-fix turnaround.

The tool has **zero external dependencies**—it bundles everything needed, and building from source requires only `make`. It's also available via DUB (`dub fetch adrdox`) and as an Arch Linux/Manjaro package. The latest release is **v2.6.0** (September 2024), with 153 total commits and 12 open issues.

**Repository**: https://github.com/adamdruppe/adrdox
**Live output**: http://dpldocs.info/
**Syntax reference**: http://dpldocs.info/experimental-docs/adrdox.syntax.html

---

## Harbored and harbored-mod: a lineage of diminishing activity

**Harbored**, created by Brian Schott (also the author of D-Scanner), was an early community documentation generator that parsed D source directly via libdparse. Its GitHub repository at github.com/economicmodeling/harbored has just 9 stars and **has been effectively unmaintained since May 2016**.

**Harbored-mod** is a fork by Ferdinand Majerech (Kiith-Sa), now under the dlang-community GitHub organization, that added significant improvements. Its headline feature is **dual DDoc and Markdown support** in documentation comments, with DDoc syntax taking precedence where both are valid. It generates one file per module/class/struct/enum by default (a middle ground between DDoc's one-per-module and ddox's one-per-symbol). Automatic cross-referencing works in code blocks and inline code. The tool is JavaScript-optional (NoScript-compatible), supports module/package exclusion, and reads configuration from an `hmod.cfg` file.

Harbored-mod has notable Markdown adaptations for D: `---` does not produce horizontal rules (reserved for DDoc code blocks; use `- - -` instead), and `_` does not create emphasis (which would break `snake_case` identifiers). With **410 commits and 19 stars**, it's more substantial than the original, but maintenance has slowed. The repository still uses Travis CI rather than GitHub Actions, and carries **39 open issues with zero open pull requests**—suggesting declining active development.

A companion project, **DDocs.org** (github.com/kiith-sa/ddocs.org), used harbored-mod to generate documentation for all DUB packages as a static site, though dpldocs.info (powered by adrdox) has effectively superseded this role.

**harbored-mod repository**: https://github.com/dlang-community/harbored-mod
**DUB package**: https://code.dlang.org/packages/harbored-mod

---

## Doxygen and Sphinx offer poor D support—D-native tools are essential

Doxygen lists D among its supported languages but qualifies this as supporting D only **"to some extent"**—a caveat not applied to C, C++, Java, or Python. D support was added around 2005, and a comprehensive GitHub issue (#1560, opened by Stewart Gordon) tracking deficiencies has remained open for two decades.

Doxygen handles basic constructs resembling C/C++: classes, structs, functions, enums with standard comment blocks. But it **fails on most D-specific features**:

- **Template syntax** (`T!args`): not understood
- **`alias` declarations**: not supported
- **Attribute blocks** (`@safe:`, `@nogc:`): not recognized
- **`function`/`delegate` keywords**: not recognized
- **`debug`/`version` conditionals**: not supported
- **Nested `/+ +/` comments**: not supported
- **Mixins, string mixins, CTFE**: not supported
- **Contracts** (`in`/`out`/`invariant`): not supported
- **`unittest` blocks as documentation**: not extracted
- **UDAs, eponymous templates, `static if`/`static foreach`**: all unsupported

There is **no `OPTIMIZE_OUTPUT_FOR_D` Doxyfile setting** (unlike for C, Java, Fortran, and VHDL), and no established D-specific input filter exists. The D community consistently redirects users asking about Doxygen toward D-native tools.

**Sphinx has no D domain.** The sphinx-contrib repository includes domains for Ada, CoffeeScript, Erlang, PHP, Ruby, and others—but not D. No tools generate Sphinx-compatible `.rst` output from D source, and no Breathe-like bridge exists. Since Breathe works by consuming Doxygen XML output, Doxygen's limited D support makes this path doubly unviable.

---

## Supporting tools and infrastructure round out the ecosystem

Several additional tools support D documentation without being full generators:

**libddoc** is a library for parsing D documentation comments, used as a dependency by D-Scanner and potentially available for custom tooling. **D-Scanner** (github.com/dlang-community/D-Scanner) is primarily a linter and static analysis tool with 150,000+ downloads, but it shares infrastructure (libdparse, libddoc) with Harbored and other generators. It can output syntax-highlighted source and CTAGS/ETAGS.

**serve-d** (github.com/Pure-D/serve-d), the D Language Server Protocol implementation, provides hover documentation, completion with doc comments, and go-to-definition in editors—extracting DDoc comments for live IDE display without generating standalone documentation. It supports VS Code (via code-d), Vim/Neovim, Emacs, and Sublime Text.

**CandyDoc** was a historical project that applied CSS and JavaScript enhancements to DDoc's raw output, functioning as a DDoc skin rather than an independent generator. It is no longer actively maintained.

For **CI/CD integration**, the standard approach uses the `dlang-community/setup-dlang@v2` GitHub Action to install DMD/LDC/GDC, then runs `dub -b ddox` or `dmd -D` for documentation generation. Static HTML output from any generator deploys cleanly to GitHub Pages. DUB natively supports ddox as a build type, making `dub -b ddox` the lowest-friction CI documentation command for DUB projects.

---

## How every tool compares across key dimensions

| Dimension                | DDoc (built-in)         | ddox                 | adrdox                     | harbored-mod              | Doxygen             |
| ------------------------ | ----------------------- | -------------------- | -------------------------- | ------------------------- | ------------------- |
| **Active maintenance**   | ✅ Core compiler        | ⚠️ Semi-active       | ✅ Active                  | ⚠️ Low activity           | ✅ (D not priority) |
| **Parsing approach**     | Compiler-integrated     | DMD JSON output      | Direct source (libdparse)  | Direct source (libdparse) | Own parser          |
| **DDoc syntax**          | Native                  | Full compatibility   | Hybrid DDoc + extensions   | DDoc + Markdown           | ❌ Own syntax       |
| **Markdown support**     | ✅ Since 2.094.0        | ❌ DDoc macros only  | ✅ Extended subset         | ✅ Full support           | ✅ Own Markdown     |
| **Output granularity**   | One file per module     | One file per symbol  | One file per symbol        | One file per type         | One file per type   |
| **Search**               | ❌ None                 | ✅ Auto-generated    | ✅ Full-text (JS + server) | ❌ None (JS-optional)     | ✅ Built-in         |
| **Cross-referencing**    | ⚠️ Limited/manual       | ✅ Automatic         | ✅ Automatic + `[bracket]` | ✅ Automatic              | ⚠️ Basic            |
| **Source linking**       | ❌                      | ✅ GitHub file/line  | ✅ Annotated source HTML   | ❌                        | ✅ Source browser   |
| **Theming**              | .ddoc macro files + CSS | Diet templates + CSS | skeleton.html + CSS        | CSS classes               | Doxyfile + CSS      |
| **Templates/mixins**     | ⚠️ Partial              | ⚠️ DMD JSON limits   | ✅ Best support            | ⚠️ libdparse limits       | ❌ Not supported    |
| **Contracts display**    | ⚠️ Partial              | ⚠️ Partial           | ✅ Supported               | ⚠️ Partial                | ❌ Not supported    |
| **Unittest as examples** | ✅ Native               | ✅ Via JSON          | ✅ Via source parsing      | ✅ Via libdparse          | ❌ Not supported    |
| **Math/LaTeX**           | ❌                      | ❌                   | ✅ KaTeX                   | ❌                        | ✅ MathJax          |
| **DUB integration**      | Manual flags            | ✅ `dub -b ddox`     | Manual (`doc2 -i`)         | `hmod` command            | Manual Doxyfile     |
| **Dependencies**         | None (compiler)         | vibe.d (heavy)       | None (self-contained)      | libdparse                 | None (standalone)   |
| **GitHub stars**         | N/A (part of DMD)       | 70                   | 46                         | 19                        | 5,800+ (all langs)  |
| **Total DUB downloads**  | N/A                     | ~457K                | ~6.4K                      | N/A                       | N/A                 |
| **Used by dlang.org**    | ✅ Primary              | ✅ Secondary         | ❌ (powers dpldocs.info)   | ❌                        | ❌                  |

---

## Practical recommendations depend on project needs and scale

The D documentation ecosystem in 2025–2026 has settled into a stable but fragmented state. **DDoc remains the universal baseline**—every D compiler supports it, it requires zero dependencies, and Markdown support has significantly modernized its comment syntax. For small projects or quick internal documentation, `dmd -D -o-` with a custom `.ddoc` theme file is the fastest path.

**For DUB projects wanting minimal setup**, `dub -b ddox` provides one-command documentation generation with page-per-symbol layout and search. ddox's integration into DUB makes it the default choice for many projects, despite its semi-active maintenance and inherited DMD JSON limitations.

**For the highest-quality documentation output**, adrdox is the community's clear recommendation. Its direct source parsing avoids the JSON output limitations that plague ddox, its hybrid syntax offers the most expressive comment format, and dpldocs.info demonstrates production-quality results at scale. The trade-off is slightly more manual setup—no native `dub` build type integration, though CI/CD workflows are straightforward.

The long-stalled transition from DDoc to ddox on dlang.org reflects a broader ecosystem truth: **D's documentation tooling works but lacks the consolidation seen in languages like Rust (rustdoc) or Go (godoc)**. The D Language Foundation has not designated a single canonical third-party generator, and community energy has split across multiple tools. Recent DDoc improvements—Markdown syntax, bracket-style symbol references—suggest the compiler-native path is slowly absorbing features pioneered by community tools, which may eventually reduce the need for alternatives.

For teams evaluating tools today: use adrdox for public-facing API documentation, ddox via DUB for quick internal docs, and avoid Doxygen entirely for D-specific codebases.
