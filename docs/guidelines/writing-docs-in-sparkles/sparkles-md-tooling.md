# Sparkles MD Tooling

## Pre-commit Hooks (docs-related)

| Hook                           | Purpose                                    | Files  |
| ------------------------------ | ------------------------------------------ | ------ |
| `editorconfig-checker`         | Whitespace / indentation consistency       | All    |
| `end-of-file-fixer`            | Ensure trailing newline                    | Text   |
| `fix-markdown-reference-links` | Convert inline links → reference-style     | `*.md` |
| `prettier`                     | Format markdown, tables, spacing           | Text   |
| `lychee`                       | Validate all URLs (internal + external)    | `*.md` |
| `verify-md-examples`           | Compile/run D code blocks and check output | `*.md` |

All hooks run automatically on `git commit`. To run manually:

```bash
pre-commit run --files docs/path/to/file.md
pre-commit run lychee --files docs/path/to/file.md
```

---

## Runnable D Examples in Markdown

### Structure

Embed D code examples as dub single-file programs inside fenced `d` code blocks:

````markdown
```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "readme_my_feature"
    dependency "sparkles:core-cli" version="*"
+/

import sparkles.core_cli.my_module;

void main()
{
    // Example usage
}
```
````

Follow the code block with a bare fenced output block (no language tag) showing the expected output:

````markdown
```
Expected output here
```
````

### Dependencies

- In **README.md / docs/** examples: use `version="*"` for sparkles dependencies
- In **libs/\*/examples/\*.d** files: use `path="../../../"` to point to the repo root (avoids resolving against published registry versions)

### Dynamic Output with `<!-- md-example-expected -->`

When output contains dynamic values (timestamps, paths, durations), add an HTML comment directive between the code block and the output block:

<div v-pre>

````markdown
<!-- md-example-expected
[ {{_}} | info | {{_}} ]: Server started
-->

```
[ 14:32:01 | info | app.d:12 ]: Server started
```
````

- `{{_}}` matches any non-empty text
- The HTML comment is invisible in rendered markdown
- `--verify` uses the wildcard pattern; the literal block is preserved for readers

</div>

### Verifying Examples

```bash
# Verify all examples match expected output
./scripts/run_md_examples.d --verify README.md

# Update output blocks with actual output (golden snapshot)
./scripts/run_md_examples.d --update README.md

# Just run and display
./scripts/run_md_examples.d README.md

# Find and verify all markdown files
./scripts/run_md_examples.d --verify --glob='**/*.md'
```
