# Conventions

## Conventional Commits for Docs

```
docs(<scope>): <description>
```

### Scopes

- `guidelines` — for guideline/idiom articles
- `research` — for research survey pages
- `specs` — for specification documents
- Topic-specific scopes are also valid: `docs(markdown): ...`

### Examples

```
docs(guidelines): add forced named arguments idiom
docs(research): expand Vulkan binding safety research
docs(guidelines): update code style with new DIP1030 examples
```

---

## Symlinks for Library Ergonomics

When a spec or doc is canonical under `docs/`, create symlinks from the library directory:

```bash
ln -s ../../docs/specs/markdown/SPEC.md libs/markdown/SPEC.md
```

This keeps docs browsable from both the library root and the VitePress site.
