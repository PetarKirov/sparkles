module example.com/cli

go 1.24

// In workspace mode this requirement resolves to ../greeter on disk (it is a
// `use`d main module), so no version is fetched and no `replace` is needed.
// Outside the workspace (GOWORK=off) this would need a real tagged version.
require example.com/greeter v0.0.0
