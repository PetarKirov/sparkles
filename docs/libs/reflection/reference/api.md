# API reference

Module `sparkles.reflection.kind`

| Symbol               | Kind     | Purpose                                                                                                                                                                                                     |
| -------------------- | -------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `TypeKind`           | enum     | The closed structural kinds: `opaque`, `null_`, `boolean`, `character`, `signedInteger`, `unsignedInteger`, `floating`, `text`, `enumeration`, `pointer`, `sequence`, `associative`, `aggregate`, `sumType` |
| `typeKindOf!T`       | template | The one total ladder from a D type to its `TypeKind`                                                                                                                                                        |
| `isScalarKind(kind)` | function | The leaf kinds a value writer or query sink consumes directly                                                                                                                                               |

Module `sparkles.reflection.member`

| Symbol                   | Kind      | Purpose                                                       |
| ------------------------ | --------- | ------------------------------------------------------------- |
| `fieldCount!T`           | enum      | Declared fields, nested context pointer excluded              |
| `fieldType!(T, i)`       | alias     | Declared type of field `i`                                    |
| `fieldIdentifier!(T, i)` | enum      | Declared identifier of field `i`                              |
| `isPropertyGetter!s`     | enum      | Zero-argument `@property` getter returning non-`void`         |
| `isPublic!s`             | enum      | Declared `public` or `export`                                 |
| `isConstReadable!(T, g)` | enum      | Getter `g` callable on a `const` view of `T`                  |
| `propertyGetters!T`      | alias seq | Public zero-argument `@property` getters, one per member name |
| `hasPublicFields!T`      | enum      | At least one public declared field                            |
| `valueLikeGetter!T`      | alias     | The single scalar getter of a fieldless value type, or `void` |
| `firstDuplicate(names)`  | function  | CTFE uniqueness check helper                                  |
