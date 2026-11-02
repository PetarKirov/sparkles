/**
Recipe resolution (build-graph SPEC §2): a recipe, a configuration, a build
type and a platform, to the resolved settings of every target, as dub
resolves them.
*/
module sparkles.build_primitives.resolve;

public import sparkles.build_primitives.resolve.configure;
public import sparkles.build_primitives.resolve.driver;
public import sparkles.build_primitives.resolve.dub_versions;
public import sparkles.build_primitives.resolve.hidden_edges;
public import sparkles.build_primitives.resolve.libraries;
public import sparkles.build_primitives.resolve.platform;
public import sparkles.build_primitives.resolve.project;
public import sparkles.build_primitives.resolve.recipe;
public import sparkles.build_primitives.resolve.registry;
public import sparkles.build_primitives.resolve.settings;
