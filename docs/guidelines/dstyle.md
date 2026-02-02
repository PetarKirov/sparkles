<!--
This document is a markdown conversion of the D Style page from the official
D Programming Language website.

Source: https://dlang.org/dstyle.html
License: Boost Software License 1.0 (https://www.boost.org/LICENSE_1_0.txt)
Copyright: © 1999-2026 The D Language Foundation
-->

# The D Style

The D Style is a set of style conventions for writing D programs. The D Style is not enforced by the compiler. It is purely cosmetic and a matter of choice. Adhering to the D Style, however, will make it easier for others to work with your code and easier for you to work with others' code. The D Style can form the starting point for a project style guide customized for your project team.

Submissions to Phobos and other official D source code will follow these guidelines.

## Whitespace

- One statement per line.
- Use spaces instead of hardware tabs.
- Each indentation level will be four columns.

## Naming Conventions

### General

Unless listed otherwise below, names should be camelCased (this includes all variables). So, names formed by joining multiple words have each word other than the first word capitalized. Also, names do not begin with an underscore `_` unless they are private.

```d
int myFunc();
string myLocalVar;

```

### Modules

Module and package names should be all lowercase, and only contain the characters `[a..z][0..9][_]`. This avoids problems when dealing with case-insensitive file systems.

```d
import std.algorithm;

```

### Classes, Interfaces, Structs, Unions, Enums, Non-Eponymous Templates

The names of user-defined types should be PascalCased, which is the same as camelCased except that the first letter is uppercase.

```d
class Foo;
struct FooAndBar;

```

### Eponymous Templates

Templates which have the same name as a symbol within that template (and instantiations of that template are therefore replaced with that symbol) should be capitalized in the same way that the inner symbol would be capitalized if it weren't in a template - e.g. types should be PascalCased and values should be camelCased.

```d
template GetSomeType(T) { alias GetSomeType = T; }
template isSomeType(T) { enum isSomeType = is(T == SomeType); }
template MyType(T) { struct MyType { ... } }
template map(fun...) { auto map(Range r) { ... } }

```

### Functions

Function names should be camelCased, so their first letter is lowercase. This includes properties and member functions.

```d
int done();
int doneProcessing();

```

### Constants

The names of constants should be camelCased just like normal variables.

```d
enum secondsPerMinute = 60;
immutable hexDigits = "0123456789ABCDEF";

```

### Enum members

The members of enums should be camelCased, so their first letter is lowercase.

```d
enum Direction { bwd, fwd, both }
enum OpenRight { no, yes }

```

### Keywords

If a name would conflict with a keyword, and it is desirable to use the keyword rather than pick a different name, a single underscore `_` should be appended to it. Names should not be capitalized differently in order to avoid conflicting with keywords.

```d
enum Attribute { nothrow_, pure_, safe }

```

### Acronyms

When acronyms are used in symbol names, all letters in the acronym should have the same case. So, if the first letter in the acronym is lowercase, then all of the letters in the acronym are lowercase, and if the first letter in the acronym is uppercase, then all of the letters in the acronym are uppercase.

```d
class UTFException;
ubyte asciiChar;

```

### User-Defined Attributes

For symbols that are only to be used as user-defined attributes the names should be camelCased, so their first letter is lowercase. This convention takes precedence over any previously mentioned conventions. This matches conventions of the built in attributes like `@safe`, `@nogc` and the special compiler recognized UDA `@selector`.

```d
struct Foo {} // this struct follows the regular naming conventions

// this struct is only intended to be used as an UDA and therefore overrides the
// regular naming conventions for structs
struct name { string value; }

@name("bar") Foo foo;

```

## Type Aliases

The D programming languages offers two functionally equivalent syntaxes for type aliases, but ...

```d
alias size_t = uint;

```

... is preferred over ...

```d
alias uint size_t;

```

... because ...

- It follows the already familiar assignment syntax instead of the inverted typedef syntax from C
- In verbose declarations, it is easier to see what is being declared

```d
alias important = someTemplateDetail!(withParameters, andValues);
alias Callback = ReturnType function(Arg1, Arg2) pure nothrow;

```

vs.

```d
alias someTemplateDetail!(withParameters, andValues) important;
alias ReturnType function(Arg1, Arg2) pure nothrow Callback;

```

Meaningless type aliases like ...

```d
alias VOID = void;
alias INT = int;
alias pint = int*;

```

... should be avoided.

## Declaration Style

Since the declarations are left-associative, left justify them:

```d
int[] x, y; // makes it clear that x and y are the same type
int** p, q; // makes it clear that p and q are the same type

```

to emphasize their relationship. Do not use the C style:

```d
int []x, y; // confusing since y is also an int[]
int **p, q; // confusing since q is also an int**

```

## Operator Overloading

Operator overloading is a powerful tool to extend the basic types supported by the language. But being powerful, it has great potential for creating obfuscated code. In particular, the existing D operators have conventional meanings, such as `+` means 'add' and `<<` means 'shift left'. Overloading operator `+` with a meaning different from 'add' is arbitrarily confusing and should be avoided.

## Hungarian Notation

Using Hungarian notation to denote the type of a variable is a bad idea. However, using notation to denote the purpose of a variable (that cannot be expressed by its type) is often a good practice.

## Properties

Functions should be property functions whenever appropriate. In particular, getters and setters should generally be avoided in favor of property functions. And in general, whereas functions should be verbs, properties should be nouns, just like if they were member variables. Getter properties should not alter state.

## Property syntax

Do not use UFCS or Optional Parentheses outside of their intended use cases. Omitting parentheses is useful in generic code that does not care whether a member is a field or a function, for example the range primitive `front`. It can also make a chain of range functions more compact. However, when a simple call is made to a function with side effects, prefer 'regular' function call syntax.

```d
import std.range, std.stdio;

void main()
{
    // good
    writeln();
    writeln("hello");
    iota(0, 10).dropOne.array.front.writeln;

    // bad
    writeln;
    "hello".writeln;
    writeln = "hello";
}

```

## Documentation

All public declarations will be documented in Ddoc format and should have at least Params and Returns sections.

## Unit Tests

As much as practical, all functions will be exercised by unit tests using unittest blocks immediately following the function to be tested. Every path of code should be executed at least once, verified by the code coverage analyzer.

## Additional Requirements for Phobos

In general, this guide does not try to recommend or require that code conform to any particular formatting guidelines. The small section on whitespace at the top contains its only formatting guidelines. However, for Phobos and other official D source code, there are additional requirements:

### Brackets

Braces should be on their own line. There are a few exceptions to this (such as when declaring lambda functions), but with any normal function block or type definition, the braces should be on their own line.

```d
void func(int param)
{
    if (param < 0)
    {
        ...
    }
    else
    {
        ...
    }
}

```

Avoid unnecessary parentheses:

```d
(a == b) ? "foo" : "bar"; // NO
a == b ? "foo" : "bar";   // OK

```

### Line length

Lines have a soft limit of 80 characters and a hard limit of 120 characters. This means that most lines of code should be no longer than 80 characters long but that they can exceed 80 characters when appropriate. However, they can never exceed 120 characters.

### Whitespace

Put a space after `for`, `foreach`, `if`, `while`, and `version`:

```d
for (…) { … }
foreach (…) { … }
static foreach (…) { … }
if (x) { … }
static if (x) { … }
while (…) { … }
do { … } while (…);
version (…) { … }

```

Chains containing `else if (…)`, `else static if (…)` or `else version (…)` should set the keywords on the same line:

```d
if (…)
{
    …
}
else if (…)
{
    …
}

```

Put a space between binary operators, assignments, cast, and lambdas:

```d
a + b
a / b
a == b
a && b
arr[1 .. 2]
int a = 100;
b += 1;
short c = cast(short) a;
filter!(a => a == 42);

```

Put no space between unary operators, after assert, function calls:

```d
a = !a && !(2 == -1);
bool b = ~a;
auto d = &c;
e++;
assert(*d == 42);
callMyFancyFunction("hello world");

```

### Imports

- Local, selective imports should be preferred over global imports
- Selective imports should have a space before and after the colon (:) like `import std.range : zip`
- Imports should be sorted lexicographically.

### Return type

The return type should be stated explicitly wherever possible, as it makes the documentation and source code easier to read. Function-nested structs (aka Voldemort types) should be preferred over public structs.

### Attributes

Non-templated functions should be annotated with matching attributes (`@nogc`, `@safe`, `pure`, `nothrow`). If the template arguments for a templated function affect whether an attribute is appropriate, then the function should not be annotated with that attribute so that the compiler can infer it. However, if the attribute is not affected by the template arguments (and thus would always be inferred), then the function should be explicitly annotated with that attribute just like a non-templated function would be. Attributes should be listed in alphabetical ordering, e.g. `const @nogc nothrow pure @safe` (the ordering should ignore the leading `@`). Every unittest should be annotated (e.g. `pure nothrow @nogc @safe unittest { ... }`) to ensure the existence of attributes on the templated function.

### Templates

unittest blocks should be avoided in templates. They will generate a new unittest for each instance, hence tests should be put outside of the template.

### Declarations

Constraints on declarations should have the same indentation level as their declaration:

```d
void foo(R)(R r)
if (R == 1)

```

Pre and post contracts should have the same indentation level as their declaration. The expression-based syntax should be preferred when the equivalent long-form syntax would have a single assert statement. Put a space after in/out similar to if constraints:

```d
// Prefer:
T transmogrify(T)(T value)
if (isIntegral!T)
in (value % 7 == 0)
out (result; result % 11 == 0)
{
    // ...
}

// over this:
T transmogrify(T)(T value)
if (isIntegral!T)
in
{
    assert(value % 7 == 0);
}
out (result)
{
    assert(result % 11 == 0);
}
do
{
    // ...
}

```

Invariants should use the expression-based syntax when the equivalent long-form syntax would have a single assert statement. Put a space between invariant and the opening parentheses:

```d
struct S
{
    int x;
    invariant (x > 0);
}

```

### Class/Struct Field Declarations

In structs and classes, there should only be one space between the type of the field and its name. This avoids problems with future changes generating a larger git diff than necessary.

```d
class MyClass
{
    // bad
    int      a;
    double   b;

    // good
    int x;
    double y;
}

```

### Documentation

Every public symbol should be exposed in the documentation:

```d
/// A public symbol
enum myFancyConstant;

```

Every public function should have a Ddoc description and documented `Params:` and `Returns:` sections (if applicable):

```d
/**
Checks whether a number is positive. `0` isn't considered as positive number.

Params:
    number = number to be checked
Returns:
    `true` if the number is positive, `0` otherwise.
See_Also:
    $(LREF isNegative)
*/
bool isPositive(int number)
{
    return number > 0;
}

```

- Text in sections (e.g. Params:, Returns:, See_Also) should be indented by one level if it spans more than the line of the section.
- Documentation comments should not use more than two stars `/**` or two pluses `/++` in the header line. Either Block comments (`/**`) or nesting block comments (`/++`) should be used except when the ddoc comment is a ditto comment such as `///`
- Ditto Documentation comments should not have leading stars on each line.
- Text example blocks should use three dashes (`---`) only.

We are not necessarily recommending that all code follow these rules. They're likely to be controversial in any discussion on coding standards. However, they are required in submissions to Phobos and other official D source code.
