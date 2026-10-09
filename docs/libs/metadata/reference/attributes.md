# Attribute reference

Import the vocabulary with:

```d
import sparkles.metadata;
```

| Attribute     | Purpose                                                                                                                                |
| ------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `WireName`    | A member's or field's name; `@WireName("x")` applies under every format that uses wire names, `@WireName!F("x")` under format `F` only |
| `WireCase`    | The case a type's names are recased into, per format                                                                                   |
| `WireRepr`    | An enum written by name or by underlying value, per format                                                                             |
| `Aliases`     | Additional accepted names in preference order                                                                                          |
| `Label`       | Short human-facing label                                                                                                               |
| `Description` | Human-facing explanatory prose                                                                                                         |
| `Range`       | Numeric lower bound, upper bound, and optional step                                                                                    |

The format tags live beside them: `AnyFormat`, and the identifier formats
`Pretty` and `DSource`, which spell members by their D identifiers unless
annotated for themselves (`NameSource`). `CaseStyle` is here too, so
`sparkles:base` can resolve names through the vocabulary; the resolution rule is
`sparkles.base.text.wire_names`.

Consumers decide where each attribute is valid and how it affects behavior.
For example, the property tree enforces `Range`, while a query schema may use
the same value only for generated documentation.
