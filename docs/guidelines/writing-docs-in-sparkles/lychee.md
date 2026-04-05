# Lychee

Link checking with [lychee][] ensures all URLs in documentation are reachable.

## Configuration

- Config file: `lychee.toml`
- Shared exclusions: `lychee.exclude` (always applied)
- CI-only exclusions: `lychee.ci.exclude` (flaky endpoints in GitHub Actions)
- `fallback_extensions = ["md", "html"]` — links without extensions resolve to `.md` or `.html`
- `include_verbatim = false` — URLs inside code blocks are not checked
- `include_fragments = false` — anchor fragments are not checked
- GitHub blob/tree URLs are rewritten to the Contents API to avoid rate limiting
- Caching is enabled (`--cache` flag); the `.lycheecache` file is gitignored
- The hook is restricted to `\.md$` files to avoid false positives in source code

## Adding Exclusions

- **Permanently broken or paywalled URLs** → add to `lychee.exclude`
- **URLs that work locally but fail in CI** (rate limits, geo-blocks) → add to `lychee.ci.exclude`
- **Deleted repositories** → add specific URL to `lychee.exclude` and mark the link in docs with strikethrough: `~~[repo](URL)~~ (deleted)`
- **Academic publishers** (`doi.org`, `dl.acm.org`, `link.springer.com`) → already excluded globally
- Use anchored regexes: `^https://example\.com/path$`

## Fixing Broken Links

When lychee reports a broken link:

1. **Moved resource** → update URL to the new canonical location
2. **Deleted page** → replace with a stable alternative (project README, conference talk, Web Archive snapshot, or Gist mirror)
3. **Deleted repository** → mark as `~~[name](url)~~ (deleted)`, add URL to `lychee.exclude`
4. **Flaky in CI only** → add to `lychee.ci.exclude`
5. Always verify the replacement URL is live before committing

## Running Locally

```bash
lychee docs/path/to/file.md
```

[lychee]: https://lychee.cli.rs/
