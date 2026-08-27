# Attribute reference

Import the vocabulary with:

```d
import sparkles.metadata;
```

| Attribute     | Purpose                                                      |
| ------------- | ------------------------------------------------------------ |
| `Name`        | Canonical machine-readable name independent of a wire format |
| `Aliases`     | Additional accepted names in preference order                |
| `Label`       | Short human-facing label                                     |
| `Description` | Human-facing explanatory prose                               |
| `Range`       | Numeric lower bound, upper bound, and optional step          |

Consumers decide where each attribute is valid and how it affects behavior.
For example, the property tree enforces `Range`, while a query schema may use
the same value only for generated documentation.
