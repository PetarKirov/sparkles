/// `sparkles:docs` — the markdown-based static documentation-site library
/// behind `hue gallery` (and the planned `hue site` / API doc generator): the
/// content-fragment builders, the page shell with its appearance toggle and
/// breadcrumbs, the mirrored site tree with per-directory indexes, the shared
/// theme stylesheet assets, the document set, and the docs-site sidebar data
/// schema (`docs/specs/hue/gallery.md` `GAL*`,
/// `docs/specs/hue/feature-requirements.md` `HTM*`).
///
/// Tests live in the feature modules (the runner does not discover
/// `package.d` unittests); this module only re-exports the public surface.
module sparkles.docs;

public import sparkles.docs.assets;
public import sparkles.docs.breadcrumbs;
public import sparkles.docs.fragment;
public import sparkles.docs.options;
public import sparkles.docs.page_shell;
public import sparkles.docs.site_tree;
public import sparkles.docs.source_set;
