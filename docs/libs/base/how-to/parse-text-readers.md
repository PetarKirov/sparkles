# Parse text with readers

Use low-level slice-advancing readers and generic `Expected`-based error handling to parse text safely and reliably without GC allocation.

## Slice-Advance Pattern

Each reader takes the input as a `ref scope const(char)[]` cursor. On success, it advances the cursor past the consumed characters.

The readers are designed as parsing mechanisms rather than rules. They return mechanical parse outcomes via `ParseExpected!T` (which is an alias to `Expected!(T, ParseError)`).

Common reading and navigation primitives:

- `readInteger`: Parse leading decimal digits into an unsigned integer type, returning `ParseExpected!T`.
- `skipWhile`: Advance past leading characters satisfying a predicate.
- `skipSpaces`: Advance past ASCII spaces and tabs.
- `tryConsume`: Consume a specific character if present and return `true`.
- `tryConsumeAny`: Consume any character in a given set if present and return `true`.
- `readUntil`: Consume characters up to a specific delimiter, returning the consumed slice.

## Parser Example

Here is a complete example of a parser that reads a structured coordinate pair `(X, Y)`. It implements `@safe pure nothrow @nogc` error handling and reports error positions using ANSI styling:

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "base_parse_text_readers"
    dependency "sparkles:base" version="*"
+/
import sparkles.base.text : readInteger, skipSpaces, tryConsume, ParseExpected, ParseErrorCode, parseErr, parseOk;
import sparkles.base.styled_template : styledWriteln;

struct Point
{
    uint x;
    uint y;
}

@safe pure nothrow @nogc
ParseExpected!Point parsePoint(ref scope const(char)[] s)
{
    skipSpaces(s);
    if (!tryConsume(s, '('))
        return parseErr!Point(ParseErrorCode.unexpectedCharacter, 0);

    skipSpaces(s);
    auto xResult = readInteger!uint(s);
    if (!xResult.hasValue)
        return parseErr!Point(xResult.error);

    skipSpaces(s);
    if (!tryConsume(s, ','))
        return parseErr!Point(ParseErrorCode.unexpectedCharacter, 0);

    skipSpaces(s);
    auto yResult = readInteger!uint(s);
    if (!yResult.hasValue)
        return parseErr!Point(yResult.error);

    skipSpaces(s);
    if (!tryConsume(s, ')'))
        return parseErr!Point(ParseErrorCode.unexpectedCharacter, 0);

    return parseOk(Point(xResult.value, yResult.value));
}

void main()
{
    // 1. Success case
    const(char)[] successInput = " (10, 20) ";
    const(char)[] successCursor = successInput;
    auto res1 = parsePoint(successCursor);

    if (res1.hasValue)
        styledWriteln(i"Parsed: {green Point(x: $(res1.value.x), y: $(res1.value.y))}");

    // 2. Error case (missing comma)
    const(char)[] errorInput = " (10 20) ";
    const(char)[] errorCursor = errorInput;
    auto res2 = parsePoint(errorCursor);

    if (!res2.hasValue)
    {
        styledWriteln(i"{red Error: $(res2.error.code) at offset $(res2.error.offset)}");
    }
}
```

```ansi
Parsed: [32mPoint(x: 10, y: 20)[39m
[31mError: 1 at offset 0[39m
```
