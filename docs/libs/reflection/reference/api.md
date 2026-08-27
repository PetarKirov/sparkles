# API reference

Module `sparkles.reflection.kind`

| Symbol               | Kind     | Purpose                                                                                                                                                                                                     |
| -------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TypeKind`           | enum     | The closed structural kinds: `opaque`, `null_`, `boolean`, `character`, `signedInteger`, `unsignedInteger`, `floating`, `text`, `enumeration`, `pointer`, `sequence`, `associative`, `aggregate`, `sumType` |
| `typeKindOf!T`       | template | The one total ladder from a D type to its `TypeKind`                                                                                                                                                        |
| `isScalarKind(kind)` | function | The leaf kinds a value writer or query sink consumes directly                                                                                                                                               |

Module `sparkles.reflection.member`

| Symbol                        | Kind      | Purpose                                                       |
| ----------------------------- | --------- | ------------------------------------------------------------- |
| `fieldCount!T`                | enum      | Declared fields, nested context pointer excluded              |
| `fieldType!(T, i)`            | alias     | Declared type of field `i`                                    |
| `fieldSymbol!(T, i)`          | alias     | Compile-time symbol of field `i`                              |
| `fieldIdentifier!(T, i)`      | enum      | Declared identifier of field `i`                              |
| `isPropertyGetter!s`          | enum      | Zero-argument `@property` getter returning non-`void`         |
| `isPublic!s`                  | enum      | Declared `public` or `export`                                 |
| `propertyGetters!T`           | alias seq | Public zero-argument `@property` getters, one per member name |
| `hasPublicFields!T`           | enum      | At least one public declared field                            |
| `valueLikeGetter!T`           | alias     | The single scalar getter of a fieldless value type, or `void` |
| `aliasThisMembers!T`          | alias seq | Names exposed through `alias this`                            |
| `fieldTable!(T, reduce)`      | template  | One-pass CTFE table reduced per field index                   |
| `enumMemberTable!(E, reduce)` | template  | One-pass CTFE table reduced per enum member name              |
| `firstDuplicate(names)`       | function  | CTFE uniqueness check helper                                  |

Module `sparkles.reflection.visit`

| Symbol              | Kind     | Purpose                                           |
| ------------------- | -------- | ------------------------------------------------- |
| `VisitControl`      | enum     | `descend` / `skip` for the compile-time walk      |
| `ValueControl`      | enum     | `descend` / `skip` / `stop` for the runtime walk  |
| `NoopVisitor`       | struct   | The baseline visitor: no hooks, plain traversal   |
| `visitType!(T, V)`  | function | Compile-time structural walk with cycle detection |
| `visitValue!(T, V)` | function | Runtime value walk; returns `false` on `stop`     |

## Type-visitor hooks (all optional)

| Hook                                          | Receives                              | Default when absent                                      |
| --------------------------------------------- | ------------------------------------- | -------------------------------------------------------- |
| `enterType!T()`                               | the type                              | descend; a `VisitControl` return may `skip`              |
| `leaveType!T()`                               | the type                              | nothing; fires for every type                            |
| `includeField!(T, i)()`                       | enclosing type, field index           | include; must be `static` (compile-time decision)        |
| `enterField!(T, i)()` / `leaveField!(T, i)()` | enclosing type, field index           | nothing                                                  |
| `leaf!T()`                                    | a scalar/text/enum leaf type          | nothing                                                  |
| `property!getter()`                           | a public `@property` getter symbol    | nothing                                                  |
| `sumAlternative!(V, i)()`                     | alternative type and index            | nothing                                                  |
| `sequenceElement!(A, E)()`                    | array type, element type              | nothing; a `VisitControl` return decides element descent |
| `associativeEntry!(K, V)()`                   | key and value types                   | nothing                                                  |
| `cycle!T()`                                   | a type re-entered on one descent path | nothing                                                  |

Cycle detection is per descent path: two sibling fields of the same type both
visit; a self-referential chain reports `cycle` and stops that branch.

## Value-visitor hooks (all optional)

| Hook                                           | Receives                                 | Default when absent                         |
| ---------------------------------------------- | ---------------------------------------- | ------------------------------------------- |
| `enter(T)(ref T value)`                        | every value                              | descend; a `ValueControl` return is honored |
| `scalar(T)(ref T value)`                       | a leaf value (non-enum)                  | nothing                                     |
| `enumeration(E)(ref E value)`                  | an enum leaf value                       | nothing                                     |
| `absent(T)(ref T value)`                       | a null pointer or null associative array | nothing                                     |
| `sumAlternative(V)(ref V value, size_t index)` | the active alternative                   | nothing                                     |
| `field(F)(ref F value, size_t i)`              | a declared field, by ref                 | nothing                                     |
| `element(E)(ref E value, size_t i)`            | a sequence element, by ref               | nothing                                     |
| `entry(K, V)(ref K key, ref V value)`          | an associative-array entry, by ref       | nothing                                     |

Attribute inference is anchored: the shells are explicitly `@safe`, so hook
methods must be `@safe` for their probes to match.
