# Passive metadata and policy

The shared vocabulary deliberately excludes behavioral attributes.

`Name("delete")` says that a declaration has a canonical token. It does not
say whether that token is a CLI value, a query value, or a display identifier.
The consumer supplies that policy.

Format-specific serialization names remain `sparkles:wired` policy. CLI
`Option` and `Command` attributes remain `sparkles:core-cli` policy. Property
visibility and editing attributes remain `sparkles:ui` policy. Keeping those
separate prevents an annotation intended for one domain from silently changing
another domain's behavior.

Compatibility aliases such as input's former `WireName` and property-tree's
`Doc` refer to these canonical types. They are aliases rather than duplicate
structs because D UDA lookup depends on type identity.
