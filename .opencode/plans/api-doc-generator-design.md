# API Reference Doc Generator Design

**Status:** Draft
**Last Updated:** 2026-02-12
**Version:** 0.1.1

This document describes the architecture and implementation plan for a cutting-edge VitePress-based API reference documentation generator for D projects.

---

## Executive Summary

**Goal:** Create a modern API documentation system that combines:

- **adrdox-quality parsing** (complete coverage via AST analysis)
- **VitePress's modern tooling** (Vue components, fast builds, built-in search)
- **Cutting-edge features** (signature explorer, runnable examples, type diagrams)

**Architecture:** Two-phase system:

1. **Phase 1 (D)**: `sparkle-docs` CLI tool parses D source code and outputs JSON
2. **Phase 2 (VitePress)**: Vue components consume JSON and render interactive documentation

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              BUILD TIME                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   D Source Files                sparkle-docs (D)              JSON Output   │
│   ┌──────────────┐              ┌──────────────┐             ┌───────────┐  │
│   │ smallbuffer.d│──┐           │              │             │symbols.json│  │
│   │ prettyprint.d│──┼──────────▶│  DMD -X or   │────────────▶│search.json │  │
│   │ term_style.d │──┤           │  libdparse   │             │toc.json    │  │
│   │     ...      │──┘           │              │             │types.json  │  │
│   └──────────────┘              └──────────────┘             └───────────┘  │
│                                         │                                    │
│                                         │                                    │
│                                         ▼                                    │
│                                ┌──────────────┐                             │
│                                │  dmd.doc or  │                             │
│                                │  libddoc     │                             │
│                                │  (DDoc parse)│                             │
│                                └──────────────┘                             │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
                                         │
                                         ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                            RUNTIME (VitePress)                               │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   docs/.vitepress/                                                          │
│   ├── config.mts                                                            │
│   ├── theme/                                                                │
│   │   ├── index.mts                                                         │
│   │   └── custom.css                                                        │
│   ├── components/          # Vue components for API rendering               │
│   │   ├── ApiSymbol.vue    # Single symbol page                             │
│   │   ├── Signature.vue    # Interactive signature explorer                 │
│   │   ├── TypeDiagram.vue  # Mermaid-based type diagrams                    │
│   │   ├── ExampleRunner.vue# Runnable code examples                         │
│   │   └── ApiIndex.vue     # Search/filter interface                        │
│   └── data/                # Generated JSON consumed by components          │
│       └── api/                                                               │
│           ├── symbols.json                                                   │
│           ├── search.json                                                    │
│           └── ...                                                            │
│                                                                              │
│   Output: docs/.vitepress/dist/ → Static site deployment                    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Phase 1: `sparkle-docs` (D Tool)

### Purpose

Parse D source code and extract API information into structured JSON for VitePress consumption.

### Location

```
apps/
└── sparkle-docs/
    ├── dub.sdl
    └── source/
        └── sparkle_docs/
            ├── main.d              # CLI entry point
            ├── config.d            # Configuration
            ├── parser/
            │   ├── package.d       # Parser module
            │   ├── dmd_json.d      # DMD -X JSON parser (Phase 1a)
            │   └── libdparse.d     # Direct AST parsing (Phase 1b)
            ├── ddoc/
            │   ├── package.d       # DDoc processing
            │   ├── parser.d        # Comment parsing
            │   ├── macros.d        # Macro expansion
            │   └── markdown.d      # Markdown processing
            ├── model/
            │   ├── package.d       # Data models
            │   ├── symbol.d        # Symbol types
            │   ├── module.d        # Module representation
            │   └── comment.d       # Comment structure
            └── output/
                ├── package.d       # Output generation
                └── search_index.d  # Search index builder
```

### Dependencies

The `sparkle-docs` tool will depend on `sparkles:core-cli` for JSON serialization:

```d
import sparkles.core_cli.json;

// Serialize model structs to JSON
auto json = symbol.toJSON();
writeJsonFile(moduleData, "docs/.vitepress/data/api/symbols.json");

// Deserialize config file
auto config = tryDeserializeFromJsonFile!Config("sparkle-docs.json");
```

The `sparkles.core_cli.json` module provides:

- `toJSON!T(T value)` - Serialize any struct/array/AA to JSONValue
- `fromJSON!T(JSONValue)` - Deserialize JSONValue to D types
- `writeJsonFile!T(T value, path)` - Write serialized JSON to file
- `tryDeserializeFromJsonFile!T(path)` - Read and deserialize from file

This eliminates the need for a custom `output/json.d` module.

### Parsing Strategy

#### Phase 1a: DMD JSON Output (Initial Implementation)

Use DMD's `-X` flag to generate JSON, then process:

```bash
dmd -X -Xf=module.json -o- source/module.d
sparkle-docs --input module.json --output docs/.vitepress/data/api/
```

**Pros:**

- Simple, compiler-driven
- Handles semantic analysis (types resolved)

**Cons:**

- No UDAs in output
- `static if` branches invisible
- Some template info missing

#### Phase 1b: Direct AST Parsing (Future Enhancement)

Use libdparse (like harbored-mod) or DMD as library:

```d
// Option 1: libdparse (from harbored-mod)
import dparse.lexer;
import dparse.parser;
import dparse.ast;

auto tokens = getTokensForParser(source, config, &cache);
Module ast = parseModule(tokens, path, &allocator, &errorHandler);

// Option 2: DMD as library
import dmd.doc;
import dmd.module;
// Use gendocfile or access AST directly
```

**Pros:**

- Complete AST coverage
- No compiler dependency at runtime
- Can document anything in source

**Cons:**

- More complex implementation
- May miss semantic info

### Data Model

```d
/// Symbol types for categorization
enum SymbolKind
{
    module,
    package_,
    struct_,
    class_,
    interface_,
    enum_,
    function_,
    variable,
    alias_,
    template_,
    enumMember,
    unittest_,
}

/// Protection level
enum Protection
{
    private_,
    protected_,
    public_,
    package_,
    export_,
}

/// A documented API symbol
struct Symbol
{
    string qualifiedName;    // e.g., "sparkles.core_cli.smallbuffer.SmallBuffer"
    string name;             // e.g., "SmallBuffer"
    string kind;             // "struct", "function", etc.
    Protection protection;

    string summary;          // First paragraph
    string description;      // Full description (HTML)
    string[] attributes;     // ["@safe", "pure", "nothrow", "@nogc"]

    // For functions
    Parameter[] parameters;
    string returnType;
    string[] templateParams;
    string[] constraints;    // Template constraints

    // For aggregates
    string[] baseTypes;      // Inheritance
    Symbol[] members;        // Nested symbols

    // Source location
    string sourceFile;
    size_t line;
    size_t column;

    // DDoc sections
    ParamDoc[] paramDocs;
    string returnsDoc;
    string[] throwsDoc;
    string[] seeAlso;
    string[] examples;       // Documented unittests
    string[] bugs;
    string deprecated;

    // Cross-references
    string[] referencedBy;   // Symbols that link here
    string[] references;     // Symbols this links to
}

struct Parameter
{
    string name;
    string type;
    string defaultValue;
    bool isVariadic;
    StorageClass storageClass;
}

struct ParamDoc
{
    string name;
    string description;
}

struct Module
{
    string qualifiedName;
    string summary;
    string description;
    Symbol[] symbols;
    string[] imports;
    string[] publicImports;
}
```

### JSON Output Schema

```json
{
  "version": "0.1.0",
  "generated": "2026-02-12T10:30:00Z",
  "modules": {
    "sparkles.core_cli.smallbuffer": {
      "qualifiedName": "sparkles.core_cli.smallbuffer",
      "summary": "...",
      "symbols": [
        {
          "qualifiedName": "sparkles.core_cli.smallbuffer.SmallBuffer",
          "name": "SmallBuffer",
          "kind": "struct",
          "protection": "public",
          "summary": "A dynamic array with small buffer optimization",
          "attributes": ["@safe", "pure"],
          "members": [
            {
              "qualifiedName": "sparkles.core_cli.smallbuffer.SmallBuffer.~this",
              "name": "~this",
              "kind": "destructor",
              ...
            },
            {
              "qualifiedName": "sparkles.core_cli.smallbuffer.SmallBuffer.opOpAssign",
              "name": "opOpAssign",
              "kind": "function",
              "parameters": [
                {"name": "items", "type": "T[]", "defaultValue": null}
              ],
              "returnType": "void",
              ...
            }
          ]
        }
      ]
    }
  },
  "searchIndex": [
    {
      "qualifiedName": "sparkles.core_cli.smallbuffer.SmallBuffer",
      "name": "SmallBuffer",
      "kind": "struct",
      "summary": "A dynamic array with small buffer optimization",
      "url": "/api/core_cli/smallbuffer/SmallBuffer.html"
    }
  ],
  "typeGraph": {
    "nodes": [
      {"id": "SmallBuffer", "kind": "struct"},
      {"id": "OutputRange", "kind": "interface"}
    ],
    "edges": [
      {"from": "SmallBuffer", "to": "OutputRange", "type": "implements"}
    ]
  }
}
```

### CLI Interface

```bash
sparkle-docs [options] <source-paths...>

Options:
  -o, --output <dir>     Output directory for JSON files (default: docs/.vitepress/data/api/)
  -c, --config <file>    Configuration file (sparkle-docs.json)
  -p, --package <name>   Package name for docs
  --exclude <pattern>    Exclude files matching pattern
  --include-private      Include private symbols
  --source-url <url>     Base URL for source links (e.g., GitHub)
  --runner-url <url>     URL for runnable examples service
  --format <format>      Output format: json, msgpack (default: json)
  -v, --verbose          Verbose output
  -h, --help             Show help

Examples:
  sparkle-docs libs/core-cli/src -o docs/.vitepress/data/api/
  sparkle-docs --config sparkle-docs.json
```

### Configuration File (sparkle-docs.json)

```json
{
  "name": "sparkles",
  "version": "0.1.0",
  "sourcePaths": ["libs/core-cli/src", "libs/test-utils/src"],
  "outputPath": "docs/.vitepress/data/api/",
  "sourceUrl": "https://github.com/PetarKirov/sparkles/blob/main/{file}#L{line}",
  "runnerUrl": "https://run.dlang.io",
  "exclude": ["**/test_*.d", "**/*_test.d"],
  "includePrivate": false,
  "ddocMacros": ["docs/ddoc/macros.ddoc"],
  "customCss": ["docs/ddoc/custom.css"]
}
```

---

## Phase 2: VitePress Integration

### Directory Structure

```
docs/
├── .vitepress/
│   ├── config.mts
│   ├── theme/
│   │   ├── index.mts
│   │   └── custom.css
│   └── components/
│       └── api/
│           ├── ApiSymbol.vue       # Main symbol page component
│           ├── Signature.vue       # Interactive signature display
│           ├── SignatureExplorer.vue # Collapsible overload browser
│           ├── TypeDiagram.vue     # Mermaid type hierarchy
│           ├── ExampleRunner.vue   # Runnable code examples
│           ├── ApiIndex.vue        # Symbol search/filter page
│           ├── Breadcrumbs.vue     # Navigation breadcrumbs
│           ├── MemberList.vue      # Table of members
│           ├── SourceLink.vue      # Link to source code
│           └── DeprecationBanner.vue # Deprecated warning
├── api/
│   ├── index.md                    # API index page
│   └── [package]/
│       └── [module]/
│           └── [symbol].md         # Dynamic routes for symbols
└── data/
    └── api/
        ├── index.json              # Module/symbol index
        ├── symbols.json            # All symbols (split by module)
        ├── search.json             # Search index
        └── types.json              # Type graph for diagrams
```

### VitePress Configuration

```typescript
// docs/.vitepress/config.mts
import { defineConfig } from "vitepress";
import { apiSidebar } from "./api-sidebar";

export default defineConfig({
  title: "Sparkles API",
  description: "D library for building CLI applications",

  // Enable dynamic routes for API pages
  rewrites: {
    "api/:package/:module/:symbol.md": "api/:package/:module/:symbol.md",
  },

  themeConfig: {
    nav: [
      { text: "Docs", link: "/overview" },
      { text: "API", link: "/api/" },
      { text: "Guide", link: "/guidelines/code-style" },
    ],

    sidebar: {
      "/api/": apiSidebar, // Generated from symbols.json
      // ... other sidebars
    },

    search: {
      provider: "local", // VitePress built-in search
      // Or use Algolia for better search
    },

    outline: {
      level: [2, 3],
      label: "On this page",
    },
  },

  markdown: {
    lineNumbers: true,
    // Custom highlight for D code
    config: (md) => {
      // Add D language support
    },
  },

  // Build hooks for generating API pages
  async buildEnd() {
    // Generate dynamic routes from JSON
    await generateApiRoutes();
  },
});
```

### Key Vue Components

#### ApiSymbol.vue

Main component for rendering a symbol page:

```vue
<template>
  <div class="api-symbol">
    <DeprecationBanner v-if="symbol.deprecated" :message="symbol.deprecated" />

    <Breadcrumbs :path="symbol.qualifiedName" />

    <header>
      <h1>
        <code>{{ symbol.name }}</code>
        <span class="kind-badge" :class="symbol.kind">{{ symbol.kind }}</span>
      </h1>
      <SignatureExplorer v-if="isCallable" :overloads="overloads" />
      <Signature v-else :symbol="symbol" />
    </header>

    <section class="attributes">
      <span v-for="attr in symbol.attributes" :key="attr" class="attribute">
        {{ attr }}
      </span>
    </section>

    <section class="summary">
      <p v-html="symbol.summary" />
    </section>

    <section v-if="symbol.description" class="description">
      <div v-html="symbol.description" />
    </section>

    <section v-if="symbol.parameters.length" class="parameters">
      <h2>Parameters</h2>
      <ParamTable :params="symbol.parameters" :docs="symbol.paramDocs" />
    </section>

    <section v-if="symbol.returnType" class="returns">
      <h2>Returns</h2>
      <p v-html="symbol.returnsDoc || 'No description.'" />
      <code>{{ symbol.returnType }}</code>
    </section>

    <section v-if="symbol.examples.length" class="examples">
      <h2>Examples</h2>
      <ExampleRunner
        v-for="(example, i) in symbol.examples"
        :key="i"
        :code="example"
        :runner-url="config.runnerUrl"
      />
    </section>

    <section v-if="symbol.members.length" class="members">
      <h2>Members</h2>
      <MemberList :members="symbol.members" />
    </section>

    <TypeDiagram v-if="hasTypeHierarchy" :symbol="symbol" />

    <footer>
      <SourceLink :file="symbol.sourceFile" :line="symbol.line" />
      <SeeAlso :links="symbol.seeAlso" />
    </footer>
  </div>
</template>
```

#### SignatureExplorer.vue

Interactive overload browser:

```vue
<template>
  <div class="signature-explorer">
    <div class="overload-tabs">
      <button
        v-for="(overload, i) in overloads"
        :key="i"
        :class="{ active: activeOverload === i }"
        @click="activeOverload = i"
      >
        <code>{{ overloadSignature(overload) }}</code>
      </button>
    </div>

    <div class="signature-detail">
      <Signature :symbol="overloads[activeOverload]" expanded />
      <div v-html="overloads[activeOverload].summary" />
    </div>
  </div>
</template>

<script setup>
import { ref, computed } from "vue";

const props = defineProps(["overloads"]);
const activeOverload = ref(0);

function overloadSignature(overload) {
  // Generate compact signature: "foo(T)(T arg)" or "foo(int arg)"
  return `${overload.name}${templateParams(overload)}(${params(overload)})`;
}
</script>
```

#### ExampleRunner.vue

Runnable code examples (like Rust Playground):

```vue
<template>
  <div class="example-runner">
    <div class="code-block">
      <code-editor v-model="code" language="d" :readonly="!editable" />
    </div>

    <div class="actions">
      <button @click="runCode" :disabled="running">
        {{ running ? "Running..." : "Run" }}
      </button>
      <button @click="resetCode">Reset</button>
    </div>

    <div v-if="output" class="output">
      <pre>{{ output }}</pre>
    </div>

    <div v-if="error" class="error">
      <pre>{{ error }}</pre>
    </div>
  </div>
</template>

<script setup>
import { ref } from "vue";

const props = defineProps(["code", "runnerUrl"]);
const code = ref(props.code);
const output = ref("");
const error = ref("");
const running = ref(false);

async function runCode() {
  running.value = true;
  try {
    const response = await fetch(props.runnerUrl, {
      method: "POST",
      body: JSON.stringify({ code: code.value }),
    });
    const result = await response.json();
    output.value = result.output;
    error.value = result.error || "";
  } finally {
    running.value = false;
  }
}
</script>
```

#### TypeDiagram.vue

Mermaid-based type hierarchy visualization:

```vue
<template>
  <div class="type-diagram">
    <h2>Type Hierarchy</h2>
    <MermaidDiagram :code="mermaidCode" />
  </div>
</template>

<script setup>
import { computed } from "vue";

const props = defineProps(["symbol"]);

const mermaidCode = computed(() => {
  const nodes = [];
  const edges = [];

  // Build graph from type data
  buildTypeGraph(props.symbol, nodes, edges);

  return `graph TD
${nodes.map((n) => `  ${n.id}["${n.label}"]`).join("\n")}
${edges.map((e) => `  ${e.from} --> ${e.to}`).join("\n")}
`;
});
</script>
```

---

## Cutting-Edge Features

### 1. Signature Explorer

**Problem:** D supports function overloading and template constraints. Displaying all variants clearly is challenging.

**Solution:** Tabbed interface showing each overload with:

- Compact signature in tab
- Full signature + docs when selected
- Template constraints highlighted
- Parameter documentation in context

**Implementation:**

- Group symbols by name within a module
- Present as tabs for overloaded functions
- Show template parameters in separate styling
- Highlight constraints like `if (isInputRange!R)`

### 2. Runnable Examples

**Problem:** Static code examples can become outdated. Users want to experiment.

**Solution:** Integrate with a D code runner service:

Options:

1. **run.dlang.io** - Official D playground (limited to stdlib)
2. **Self-hosted** - Containerized D compiler + sandbox
3. **WASM-based** - Client-side compilation (experimental)

**Implementation:**

- Extract `///` documented unittests
- Add "Run" button to code blocks
- POST to runner service
- Display output inline
- Allow editing for experimentation

### 3. Type Hierarchy Diagrams

**Problem:** Understanding inheritance and interface relationships requires mental modeling.

**Solution:** Auto-generated Mermaid diagrams showing:

- Class inheritance chains
- Interface implementations
- Template parameter constraints

**Implementation:**

- Analyze `baseTypes` from symbol data
- Build graph structure
- Render with Mermaid.js or D3.js
- Make nodes clickable to navigate

### 4. API Index & Search

**Problem:** Large APIs are hard to navigate. Users need to find symbols quickly.

**Solution:** Dedicated API index page with:

**Filtering:**

- By kind (struct, function, enum, etc.)
- By module
- By attributes (@safe, @nogc, etc.)
- By protection level

**Search:**

- Fuzzy matching on symbol names
- Search within summaries
- Quick navigation with keyboard

**Implementation:**

- Use VitePress's built-in local search
- Enhance with custom Vue component
- Build search index from JSON
- Add filters as URL parameters

---

## DDoc Processing

### Supported Sections

| Section       | Rendering                                    |
| ------------- | -------------------------------------------- |
| `Params:`     | Parameter table                              |
| `Returns:`    | Returns section                              |
| `Throws:`     | Exception list                               |
| `See_Also:`   | Cross-reference links                        |
| `Examples:`   | Code blocks (documented unittests preferred) |
| `Bugs:`       | Warning callout                              |
| `Deprecated:` | Banner + migration guide                     |
| `Authors:`    | Footer metadata                              |
| `License:`    | Footer metadata                              |
| `Copyright:`  | Footer metadata                              |

### Cross-Reference Resolution

DDoc macros are processed and converted to links:

| DDoc Macro                | Output                                 |
| ------------------------- | -------------------------------------- |
| `$(LREF symbol)`          | Internal link to symbol in same module |
| `$(REF symbol, pkg, mod)` | Link to symbol in another module       |
| `$(MREF pkg, mod)`        | Link to module page                    |
| `[symbol]`                | Auto-link if symbol exists             |
| `[text](url)`             | External link                          |

### Markdown Integration

DDoc now supports Markdown. Processing flow:

1. Extract comment text
2. Process DDoc macros
3. Convert DDoc sections to structured data
4. Apply remaining Markdown (headings, lists, tables)
5. Output as HTML or structured data

---

## Implementation Phases

### Phase 1: Foundation (Week 1-2)

**Goal:** Basic JSON output from D source

1. Create `apps/sparkle-docs/` structure
2. Add dependency on `sparkles:core-cli` for JSON serialization
3. Implement DMD JSON parser (`-X` output)
4. Define data model (`Symbol`, `Module`, etc.)
5. Output basic JSON using `sparkles.core_cli.json.writeJsonFile`
6. VitePress page that loads and displays JSON

**Deliverable:** Can generate and view simple struct/function docs

### Phase 2: DDoc Processing (Week 2-3)

**Goal:** Full DDoc comment support

1. Integrate `libddoc` for DDoc parsing
2. Process standard sections (Params, Returns, etc.)
3. Implement macro expansion
4. Cross-reference resolution
5. Markdown processing

**Deliverable:** Full documentation with all sections rendered

### Phase 3: VitePress Components (Week 3-4)

**Goal:** Professional API pages

1. `ApiSymbol.vue` - Main page component
2. `Signature.vue` - Code signature display
3. `MemberList.vue` - Tables of members
4. `Breadcrumbs.vue` - Navigation
5. Dynamic route generation
6. Sidebar generation from JSON

**Deliverable:** Complete, navigable API documentation

### Phase 4: Advanced Features (Week 4-6)

**Goal:** Cutting-edge features

1. `SignatureExplorer.vue` - Overload browser
2. `ExampleRunner.vue` - Runnable examples
3. `TypeDiagram.vue` - Type hierarchy
4. `ApiIndex.vue` - Search/filter page
5. Enhance search index

**Deliverable:** Interactive, feature-rich documentation

### Phase 5: Polish & Integration (Week 6-7)

**Goal:** Production-ready

1. Styling refinements
2. Dark mode support
3. Mobile responsiveness
4. CI/CD integration
5. Documentation
6. Testing

**Deliverable:** Deployable documentation site

---

## Integration with Existing Project

### Build Process

Add to `dub.sdl`:

```sdl
subPackage "apps/sparkle-docs"
```

Add npm script to `package.json`:

```json
{
  "scripts": {
    "docs:api": "dub run :sparkle-docs -- libs/core-cli/src libs/test-utils/src",
    "docs:build": "npm run docs:api && vitepress build docs",
    "docs:dev": "npm run docs:api && vitepress dev docs"
  }
}
```

### CI/CD

Add to `.github/workflows/ci.yml`:

```yaml
- name: Generate API docs
  run: npm run docs:api

- name: Build docs
  run: npm run docs:build

- name: Deploy to GitHub Pages
  uses: peaceiris/actions-gh-pages@v3
  with:
    github_token: ${{ secrets.GITHUB_TOKEN }}
    publish_dir: docs/.vitepress/dist
```

---

## Technical Decisions Log

| Decision           | Choice                      | Rationale                                            |
| ------------------ | --------------------------- | ---------------------------------------------------- |
| Initial parser     | DMD JSON (`-X`)             | Simpler to implement, semantic info included         |
| Future parser      | libdparse or DMD as library | Complete AST coverage when needed                    |
| Output format      | JSON                        | Native VitePress/JavaScript support                  |
| JSON serialization | `sparkles.core_cli.json`    | Existing in-house module with struct/AA/enum support |
| Page granularity   | One page per symbol         | Clean URLs, better SEO, targeted linking             |
| Search             | VitePress local search      | Built-in, fast, customizable                         |
| Diagrams           | Mermaid.js                  | Simple, integrates well, editable                    |
| Code runner        | run.dlang.io initially      | Official, no hosting needed                          |

---

## Open Questions

1. **Symbol versioning:** How to handle multiple versions of the API?
   - Option A: Generate separate JSON per version
   - Option B: Single JSON with version metadata
2. **External dependencies:** How to document packages that depend on other DUB packages?
   - Need to resolve and link to external docs
   - Consider integration with dpldocs.info
3. **Incremental builds:** Only regenerate changed modules?
   - Track file hashes
   - Cache parsed AST
4. **Custom theming:** Allow users to customize the VitePress theme?
   - Expose theme config
   - Provide CSS variables

---

## References

- [DDoc Specification](https://dlang.org/spec/ddoc.html)
- [dmd.doc Module](https://dlang.org/phobos/dmd_doc.html)
- [Harbored-mod Architecture](../../research/dlang-doc-generators.md#harbored-mod)
- [VitePress Documentation](https://vitepress.dev/)
- [Mermaid.js Documentation](https://mermaid.js.org/)
- [libdparse](https://code.dlang.org/packages/libdparse)
- [libddoc](https://code.dlang.org/packages/libddoc)
- [sparkles.core_cli.json](../libs/core-cli/src/sparkles/core_cli/json.d) - JSON serialization module

---

## Changelog

### 2026-02-12 - v0.1.1

- Added dependency on `sparkles.core_cli.json` for JSON serialization
- Removed `output/json.d` from module structure (using existing module)
- Updated technical decisions and implementation phases

### 2026-02-12 - v0.1.0

- Initial design document
- Defined two-phase architecture
- Outlined data model and JSON schema
- Specified Vue components
- Created implementation roadmap
