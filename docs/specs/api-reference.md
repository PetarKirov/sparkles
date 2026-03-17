# API Reference Documentation System

## Vision

Generate a browsable, cross-linked API reference for Sparkles directly from D
source code, hosted as static pages alongside the hand-written documentation
site. The system should:

- Require **zero manual authoring** --- every public symbol, its signature,
  DDoc comments, and associated unittests appear automatically.
- Produce **per-symbol pages** with deep-linking, overcoming the limitation of
  DDoc's one-page-per-module output.
- Provide **automatic cross-referencing** --- type names in signatures and
  documentation link to their definitions.
- Integrate into the existing **VitePress** documentation site as a first-class
  section with sidebar navigation and unified search.
- Keep the D-specific parsing and the web presentation **decoupled** through a
  well-defined JSON intermediate format, so either side can evolve
  independently.

---

## Architecture

The system is a **two-stage pipeline**.

```
D source files
      |
      v
  Stage 1: sparkle-docs (D application)
  Invokes `dmd -X` per source file, parses the JSON AST,
  extracts DDoc comments and unittest snippets from source.
      |
      v
  Intermediate JSON (index.json, search.json, types.json)
      |
      v
  Stage 2: Node.js scripts + VitePress
  Generates Markdown stubs, sidebar config, and route map.
  Vue components render the JSON data client-side.
      |
      v
  Static HTML site (docs/.vitepress/dist/)
```

### Why two stages?

| Concern                                            | Handled by        |
| -------------------------------------------------- | ----------------- |
| D language semantics, DDoc parsing, DMD invocation | Stage 1 (D)       |
| URL routing, page generation, sidebar layout       | Stage 2 (Node.js) |
| Rendering, styling, interactivity                  | Vue components    |

This separation means the D parser can be tested and run independently of the
web tooling, the JSON files can be inspected or consumed by other tools, and
the frontend can be redesigned without touching the parser.

---

## Stage 1: sparkle-docs

### Entry point

`apps/sparkle-docs/source/main.d`

```
sparkle-docs [options] <source-paths...>
```

**CLI options** (all also settable via JSON config file with `-c`):

| Flag                | Field             | Purpose                                                   |
| ------------------- | ----------------- | --------------------------------------------------------- |
| positional args     | `sourcePaths`     | Root directories to scan for `.d` files                   |
| `-o`, `--output`    | `outputPath`      | Where to write JSON (default `docs/.vitepress/data/api/`) |
| `-c`, `--config`    | ---               | Load a `sparkle-docs.json` config file                    |
| `-p`, `--package`   | `name`            | Package name shown in docs                                |
| `--exclude`         | `excludePatterns` | Glob patterns for files to skip                           |
| `--include-private` | `includePrivate`  | Include private symbols                                   |
| `--output-compact`  | `outputCompact`   | Minified JSON                                             |
| `--source-url`      | `sourceUrl`       | Base URL for source-file hyperlinks                       |
| `--runner-url`      | `runnerUrl`       | URL for "Run" button (online compiler)                    |
| `-v`, `--verbose`   | ---               | Progress logging                                          |

Config merging: CLI values take precedence over file-based config for any
non-empty / non-default field.

### Parsing pipeline

`DmdJsonParser` in `apps/sparkle-docs/source/sparkle_docs/parser/dmd_json.d`:

1. **File discovery** --- recursively find all `.d` files under each source
   path. Filter out files matching any `--exclude` glob pattern using
   `std.path.globMatch`.

2. **DMD invocation** --- for each file, run:

   ```
   dmd -X -Xf=- -D -Df=/dev/null -o- -I<inferred-import-paths> <file>
   ```

   This produces a JSON array of `DmdDecl` nodes on stdout without generating
   object files or HTML.

3. **Import path inference** --- from the supplied source paths, the parser
   infers `-I` flags by looking for `/src/` markers in the path. For example,
   `libs/core-cli/src/sparkles/core_cli/json.d` yields `-Ilibs/core-cli/src`.

4. **JSON-to-model conversion** --- the `DmdDecl` tree is walked recursively.
   For each declaration:
   - Identity: `name`, `qualifiedName` (built from parent chain), `kind`, `protection`
   - Signature: `returnType` extracted by splitting on first `(`
   - Parameters: copied from `DmdDecl.parameters`
   - Base types: from `DmdDecl.base` (superclass) and `DmdDecl.interfaces`
   - Alias targets: parsed from source line when `kind == "alias"`
   - DDoc: comment text split into `summary` (first paragraph) and `description`
     (full text); `Examples:` sections and fenced code blocks extracted
   - Members: recursively parsed child declarations
   - Unittests: `unittest` blocks immediately following a symbol are attached to
     it; source is extracted from the file using `line`/`endline` ranges

5. **Privacy filtering** --- symbols with `Protection.private_` are excluded
   unless `--include-private` is set.

6. **Search index** --- a flat list of `SearchIndexEntry` (qualifiedName, name,
   kind, summary, legacy URL) is built by walking all modules and their nested
   symbols.

7. **Type graph** --- a directed graph of `TypeGraphEdge` entries is built:
   - `has-part`: parent struct/class/enum to each member
   - `extends`: class to superclass, interface to parent interface
   - `implements`: class to each implemented interface
   - `aliases`: alias symbol to its target
   - `references`: other base-type relationships
     Nodes are deduplicated; edges are keyed by `from|to|relation`.

### Data model

Defined in `apps/sparkle-docs/source/sparkle_docs/model/`.

#### `Config`

```d
struct Config {
    string name;
    string version_;
    string[] sourcePaths;
    string outputPath;
    string sourceUrl;
    string runnerUrl;
    bool outputCompact;
    string[] excludePatterns;
    bool includePrivate;
    string[] ddocMacros;
    string[] customCss;
}
```

#### `Output`

```d
struct Output {
    string version_;           // Parser version (currently "0.1.0")
    string generated;          // ISO 8601 timestamp
    ModuleDoc[string] modules; // Keyed by qualified name
    SearchIndexEntry[] searchIndex;
    TypeGraph typeGraph;
}
```

#### `ModuleDoc`

```d
struct ModuleDoc {
    string qualifiedName;  // e.g. "sparkles.core_cli.json"
    string fileName;       // Filesystem path used for discovery
    string summary;        // First paragraph of module DDoc
    string description;    // Full module DDoc
    Symbol[] symbols;      // Top-level declarations
    string[] imports;
    string[] publicImports;
    string[] attributes;
    string sourceFile;     // Path reported by DMD
    size_t line;
}
```

#### `Symbol`

```d
struct Symbol {
    string qualifiedName;
    string name;
    SymbolKind kind;
    Protection protection;
    string summary;
    string description;
    string[] attributes;
    Parameter[] parameters;
    string returnType;
    TemplateParam[] templateParams;
    string[] constraints;
    string[] baseTypes;
    Symbol[] members;       // Nested declarations
    string sourceFile;
    size_t line;
    size_t column;
    ParamDoc[] paramDocs;   // From DDoc "Params:" section
    string returnsDoc;
    string[] throwsDoc;
    string[] seeAlso;
    string[] examples;      // From DDoc "Examples:" sections
    string[] unittests;     // Extracted unittest source
    string[] bugs;
    string deprecated_;
    string[] referencedBy;
    string[] references;
}
```

**`SymbolKind`**: module, package, struct, class, interface, enum, function,
variable, alias, template, enumMember, unittest, constructor, destructor,
staticDestructor, invariant, postblit, getter, setter.

**`Protection`**: private, protected, public, package, export.

**`Parameter`**: name, type, defaultValue, isVariadic, storageClass (none,
scope, ref, out, lazy, in, const, immutable, shared, return).

**`TemplateParam`**: name, type, defaultValue, spec (specialization),
isVariadic.

#### Type graph

```d
struct TypeGraph     { TypeGraphNode[] nodes; TypeGraphEdge[] edges; }
struct TypeGraphNode { string id; string label; string kind; }
struct TypeGraphEdge { string from; string to; string type; }
// Edge types: "has-part", "extends", "implements", "aliases", "references"
```

### JSON output files

Written to `outputPath` (default `docs/.vitepress/data/api/`):

| File                      | Content                                                                            |
| ------------------------- | ---------------------------------------------------------------------------------- |
| `index.json`              | Full `Output` struct --- all modules with nested symbols, search index, type graph |
| `search.json`             | `{ "index": SearchIndexEntry[] }` --- flat symbol list                             |
| `types.json`              | `{ "graph": TypeGraph }` --- type relationship graph                               |
| `<module_qualified>.json` | `{ "module_": ModuleDoc }` --- per-module file (dots replaced with underscores)    |

---

## Stage 2: Page generation

Three Node.js scripts orchestrate the VitePress integration.

### `build-api.mjs`

Orchestrator. Runs `api-data.mjs` then `generate-api-pages.mjs` sequentially.
Accepts an optional source-path argument forwarded to `api-data.mjs`.

### `api-data.mjs`

1. Determines source path: CLI arg > `$DOCS_API_SOURCE` env var > `libs/core-cli/src`.
2. Runs `dub run :sparkle-docs -- <sourcePath> -o docs/.vitepress/data/api`.
3. Reads the three output JSON files and writes `docs/.vitepress/generated/api-manifest.json`
   with metadata: source path, timestamps, module/symbol/type-edge counts.

### `generate-api-pages.mjs`

Reads `index.json` and `search.json`, then generates:

#### Markdown pages

All generated Markdown files are thin stubs that delegate to Vue components:

```markdown
---
title: sparkles.core_cli.json.fromJSON
---

<ApiSymbolPage qualified-name="sparkles.core_cli.json.fromJSON" />
```

Three kinds:

| Page        | Location                                              | Component                                |
| ----------- | ----------------------------------------------------- | ---------------------------------------- |
| API index   | `docs/api/index.md`                                   | `<ApiIndexPage />`                       |
| Module page | `docs/api/modules/sparkles/core_cli/json/index.md`    | `<ApiModulePage module-name="..." />`    |
| Symbol page | `docs/api/symbols/sparkles.core_cli.json.fromjson.md` | `<ApiSymbolPage qualified-name="..." />` |

Module pages mirror the dot-separated module name as directory segments.
Symbol pages are placed flat under `docs/api/symbols/` with the qualified name
lowercased and sanitized as the filename.

#### Route collision resolution

Because D is case-sensitive but URLs are case-insensitive, qualified names can
collide after lowercasing (e.g. `args.cliOption` the template vs
`args.CliOption` the struct).

Resolution cascade:

1. `/api/symbols/{sanitizedQualifiedName}` --- try base route.
2. `/api/symbols/{base}--{kind}` --- append symbol kind as suffix.
3. `/api/symbols/{base}--{kind}-{hash8}` --- append 8-char DJB2 hash of the
   original qualified name.
4. `/api/symbols/{base}--{kind}-{hash8}-{counter}` --- increment counter up
   to 1000.

Sanitization rules:

- `sanitizeQualifiedName`: lowercase, replace non-`[A-Za-z0-9._-]` with `-`,
  collapse consecutive dashes, strip leading/trailing dashes, max 220 chars.
- `sanitizeSegment`: replace non-`[A-Za-z0-9_-]` with `-`, same cleanup, max
  80 chars.

Conflict detection also prevents one route from being a prefix of another
(directory vs file ambiguity).

#### Generated config files

| File                | Format                                    | Purpose                                                      |
| ------------------- | ----------------------------------------- | ------------------------------------------------------------ |
| `api-sidebar.mjs`   | ES module exporting `apiSidebar`          | VitePress sidebar config for `/api/` section                 |
| `api-routes.json`   | `{ "symbols": { qualifiedName: route } }` | Collision-safe route lookup for Vue components               |
| `api-manifest.json` | JSON                                      | Build metadata (updated with page count and collision stats) |

The sidebar structure:

```
API
  Index (/api/)
sparkles.core_cli.args (collapsed)
  cliOption (template)
  CliOption (struct)
  ...
sparkles.core_cli.json (collapsed)
  fromJSON (function)
  ...
```

---

## VitePress integration

### Config (`docs/.vitepress/config.mts`)

- `ignoreDeadLinks: [/\.d$/]` --- documentation references `.d` source files
  that don't exist as web pages.
- `themeConfig.sidebar["/api/"]` imports `apiSidebar` from generated config.
- Navigation bar includes an "API" link to `/api/`.

### Theme (`docs/.vitepress/theme/index.mts`)

Extends VitePress `DefaultTheme`. Registers three global Vue components:
`ApiIndexPage`, `ApiModulePage`, `ApiSymbolPage`.

### Data layer (`docs/.vitepress/components/api/api-data.ts`)

Client-side TypeScript module that imports the JSON data files and builds
in-memory indexes:

- `modulesRecord` --- modules keyed by qualified name
- `symbolMap` --- every symbol (including nested members) keyed by qualified name,
  built by recursively walking all module symbol trees
- `moduleBySymbol` --- reverse lookup: symbol qualified name to its containing
  module
- `searchEntries` --- flat sorted list of all search index entries
- `symbolRoutes` --- collision-safe route map from `api-routes.json`
- `uniqueBySimpleName` --- tracks which simple names are globally unique (used
  for unqualified reference resolution)
- `relatedTypeEdges` --- type graph edges grouped by `from` node

**Exported functions:**

| Function                                      | Purpose                             |
| --------------------------------------------- | ----------------------------------- |
| `modulePath(moduleName)`                      | Module name to URL path             |
| `symbolPath(qualifiedName)`                   | Symbol to URL (throws if missing)   |
| `trySymbolPath(qualifiedName)`                | Nullable version                    |
| `resolveSymbolReference(ref, contextModule?)` | Multi-strategy reference resolution |
| `linkifyTypeText(text, contextModule?)`       | Split text into linkified parts     |

**Reference resolution** (`resolveSymbolReference`) tries three strategies in
order:

1. **Direct lookup** --- check the generated route map for the exact qualified
   name.
2. **Module-relative** --- if the reference is unqualified and a context module
   is provided, prepend the module name and look up again.
3. **Unique simple name** --- if the simple name is globally unique across the
   entire codebase, resolve to that symbol.

Returns `null` if none match.

**Type linkification** (`linkifyTypeText`) tokenizes text using
`/[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*/g`, resolves each token via
`resolveSymbolReference`, and returns an array of `{ text, href?,
qualifiedName? }` parts.

### Vue components

#### `ApiIndexPage`

Displays total module and symbol counts, a list of all modules (linked, with
summaries), and a flat list of all symbols with kind badges.

#### `ApiModulePage`

Props: `moduleName`. Shows module summary, description, source file path,
import lists (public imports are linked to their module pages), and a symbol
table for all symbols whose qualified name starts with `{moduleName}.`.

#### `ApiSymbolPage`

Props: `qualifiedName`. Renders a comprehensive symbol page with these
sections (each conditional on data availability):

1. **Breadcrumb** --- link to containing module
2. **Name** --- `<h1>` with the simple name
3. **Kind and protection** --- e.g. "function | public"
4. **Signature** --- with linkified type names
5. **Summary and description** --- from DDoc
6. **Source location** --- `file:line:col`
7. **Attributes** --- `@safe`, `@nogc`, etc.
8. **Constraints** --- template constraints
9. **Base types** --- linked when resolvable
10. **Signature parameters** --- with linkified types, default values
11. **Parameter docs** --- from DDoc `Params:` section
12. **Returns** --- from DDoc `Returns:`
13. **Throws** --- from DDoc `Throws:`
14. **DDoc examples** --- from `Examples:` sections
15. **Unittests** --- extracted source of associated unittest blocks
16. **Members** --- linked list of nested symbols
17. **References** --- symbols this one uses
18. **Referenced by** --- symbols that use this one
19. **See also** --- from DDoc `See_Also:`
20. **Type graph links** --- outgoing edges from the type graph

---

## npm scripts

| Script           | Purpose                                       |
| ---------------- | --------------------------------------------- |
| `docs:api`       | Run the full pipeline (data + pages)          |
| `docs:api:data`  | Run only Stage 1 (invoke sparkle-docs)        |
| `docs:api:pages` | Run only page generation                      |
| `predocs:dev`    | Auto-runs `docs:api` before `vitepress dev`   |
| `predocs:build`  | Auto-runs `docs:api` before `vitepress build` |
| `docs:dev`       | Start VitePress dev server                    |
| `docs:build`     | Production VitePress build                    |
| `docs:preview`   | Preview production build                      |

---

## File layout

```
sparkles-docs-api-reference/
  apps/sparkle-docs/
    source/
      main.d                           # CLI entry point
      sparkle_docs/
        model/
          config.d                     # Config, Output
          module_.d                    # ModuleDoc
          symbol.d                     # Symbol, Parameter, TypeGraph, ...
          package.d
        parser/
          dmd_json.d                   # DmdJsonParser
          package.d
        output/
          generator.d                  # OutputGenerator
          package.d
        tests/
          doc_coverage_fixture.d       # Integration tests
  docs/
    .vitepress/
      config.mts                       # VitePress config
      theme/index.mts                  # Theme with component registration
      components/api/
        ApiIndexPage.vue
        ApiModulePage.vue
        ApiSymbolPage.vue
        api-data.ts                    # Client-side data layer
      scripts/
        build-api.mjs                  # Orchestrator
        api-data.mjs                   # Invokes sparkle-docs
        generate-api-pages.mjs         # Markdown + sidebar + routes
      generated/                       # Build artifacts (gitignored)
        api-manifest.json
        api-sidebar.mjs
        api-routes.json
      data/api/                        # Parser output (gitignored)
        index.json
        search.json
        types.json
    api/                               # Generated Markdown pages
      index.md
      modules/sparkles/core_cli/.../index.md
      symbols/sparkles.core_cli.*.md
  apps/doc-coverage-fixture/
    sparkle-docs.json                  # Test config file
    src/doc_coverage/...               # Test fixture D sources
  package.json                         # npm scripts
```

---

## Current metrics

From the latest `api-manifest.json` for `libs/core-cli/src`:

| Metric                    | Value                                               |
| ------------------------- | --------------------------------------------------- |
| Modules                   | 20                                                  |
| Symbols                   | 266                                                 |
| Generated pages           | 273 (1 index + 20 module + 252 symbol, after dedup) |
| Route collisions resolved | 3                                                   |
| Type graph nodes          | 257                                                 |
| Type graph edges          | 164                                                 |

---

## Design decisions and rationale

### DMD's `-X` JSON output as the parser input

Rather than writing a full D parser, sparkle-docs delegates semantic analysis
to the D compiler itself. `dmd -X` produces a JSON representation of every
declaration including type information, protection levels, and comment text.
This gives accurate results for all valid D code at the cost of requiring a
working DMD installation and being limited by what DMD chooses to expose (e.g.
UDAs and `static if` contents are absent from the JSON output).

### Source-level unittest extraction

DMD's JSON output records the line range of unittest blocks but not their
source text. The parser reads the original source file and extracts the text
between the opening and closing braces. Unittests are associated with the
**preceding documented symbol**, matching D's convention of placing tests
immediately after the function they exercise.

### Client-side rendering via Vue components

Generated Markdown files contain only front-matter and a component tag. All
rendering happens in the browser from the JSON data. This keeps the generated
Markdown trivial and avoids duplicating content, but means search engines will
only see the `<title>` until JavaScript executes.

### Collision-safe routing

D identifiers are case-sensitive (`CliOption` vs `cliOption`) but filesystem
paths and URLs often are not. The multi-tier collision resolution (kind suffix,
hash, counter) ensures every symbol gets a unique, stable URL. The route map
(`api-routes.json`) is the single source of truth for symbol-to-URL mapping;
Vue components always look up routes from this map rather than computing them.

### JSON as the interface contract

The three JSON files (`index.json`, `search.json`, `types.json`) form a stable
interface between stages. This enables:

- Running the D parser independently for CI validation or API diffing.
- Swapping in a different parser (e.g. one based on libdparse or tree-sitter)
  without changing the frontend.
- Building additional consumers (IDE plugins, changelog generators) from the
  same data.

### Hierarchical vs flat data

`index.json` preserves the full nesting (modules contain symbols, symbols
contain members), while `search.json` flattens everything into a single list.
The redundancy is deliberate: the nested form is needed for module pages and
member navigation, while the flat form serves search and sidebar generation.
