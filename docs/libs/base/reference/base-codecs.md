# Base codecs (`sparkles.base.text.base_codecs`)

Binary-to-text codecs for the power-of-two "base" family (RFC 4648
Base16/Base32/Base32hex/Base64/Base64url and alphabet-compatible relatives),
plus the `Alphabet` digit-vocabulary machinery shared with the scalar
numeral conversions in `readers.d` / `writers.d`.

> The code blocks on this page use APIs introduced after the latest
> registry release; they become runnable (verified) examples once the next
> version is tagged.

## `Alphabet`

```d
struct Alphabet
{
    string digits;                  // index == symbol value; radix == digits.length
    bool   caseInsensitive = false; // decode accepts either case
    string aliases = "";            // decode-only (aliasChar, canonicalDigit) pairs
    char   padding = '\0';          // '\0' == none; '=' for RFC base32/base64

    ubyte radix() const;
}
```

`Alphabet` is a template **value** parameter: every per-base behavior — bits
per character, group size, padding length, the 256-entry reverse table
(`makeDecodeTable`) — derives from it at compile time. Anonymous literals
bind too: `encodeBase!(Alphabet(digits: "01"))` is a working base-2 codec.

### Presets

| Preset      | Radix | Padding | Notes                                                                               |
| ----------- | ----- | ------- | ----------------------------------------------------------------------------------- |
| `base16`    | 16    | none    | RFC 4648 §8; upper-case, decodes either case                                        |
| `base32`    | 32    | `=`     | RFC 4648 §6                                                                         |
| `base32hex` | 32    | `=`     | RFC 4648 §7 (encoded order sorts like the bytes)                                    |
| `base64`    | 64    | `=`     | RFC 4648 §4                                                                         |
| `base64url` | 64    | `=`     | RFC 4648 §5 (URL- and filename-safe)                                                |
| `zbase32`   | 32    | none    | z-base-32 (human-oriented)                                                          |
| `alnum`     | 36    | none    | `0-9a-z`, case-insensitive — the digit source for the scalar radix 2–36 conversions |

## Encoding and decoding

```d
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text : encodeBase64, decodeBase64;
import std.string : representation;

SmallBuffer!(char, 64) text;
encodeBase64(text, "Man".representation);
assert(text[] == "TWFu");

SmallBuffer!(ubyte, 64) bytes;
auto r = decodeBase64(bytes, text[]);
assert(r.value == 3 && bytes[] == "Man".representation);
```

The generic spellings are `encodeBase!alphabet` / `decodeBase!alphabet`;
the presets ship as true aliases (`encodeBase16`, `decodeBase16`,
`encodeBase32`, `decodeBase32`, `encodeBase32Hex`, `decodeBase32Hex`,
`encodeBase64`, `decodeBase64`, `encodeBase64Url`, `decodeBase64Url`,
`encodeZBase32`, `decodeZBase32`).

Each name is one overload set with two forms:

- **Streaming** — `encodeBase!a(w, data)` writes chars to any output range;
  `decodeBase!a(w, text)` writes `ubyte`s and returns
  `ParseExpected!size_t` (bytes written). Attributes infer: with a
  `SmallBuffer` writer both are `@safe pure nothrow @nogc`.
- **Fixed-length** — when the byte count `N` is compile-time-known:

  ```d
  ubyte[32] digest = /* … */;
  char[encodedLen(base64, 32)] text = void;
  encodeBase64(digest, text);          // unrolled straight-line code

  ubyte[32] back = void;
  auto ok = decodeBase64(text, back);  // ParseExpected!void
  ```

  `encodedLen(a, n)` is the CTFE output-size helper. Fixed-length output is
  byte-identical to streaming (differential-tested).

### Decode strictness

The decoder is strict per RFC 4648 §3.5. Failures are `ParseError`s with a
machine-readable code and the byte offset:

| Condition                            | `ParseErrorCode`                                       | Offset        |
| ------------------------------------ | ------------------------------------------------------ | ------------- |
| character outside the alphabet       | `unexpectedCharacter`                                  | the character |
| data character after padding began   | `unexpectedCharacter` (context `"data after padding"`) | the character |
| final group too short to hold a byte | `unexpectedEnd`                                        | `text.length` |
| unused trailing bits not zero        | `nonCanonicalTrailing`                                 | `text.length` |
| wrong padding character count        | `paddingMismatch`                                      | `text.length` |

See [the explanation page](../explanation/base-codecs.md) for why these
three checks exist and what a future lax mode will relax.

## Line wrapping

Framing stays out of the kernels; wrap by decorating the writer:

```d
auto lw = lineWrapWriter(w, 76, "\r\n"); // MIME base64
encodeBase64(lw, data);
// PEM: lineWrapWriter(w, 64) — default newline is "\n"
```

Lines are at most `width` chars; no trailing newline is emitted. (This
wraps codec output — single-column ASCII. Prose wrapping by terminal cell
width lives in `sparkles.base.text.wrap`.)

## Scalar radix conversions (`readers.d` / `writers.d`)

The same `Alphabet` machinery backs the whole-integer numeral conversions,
generalized to any radix 2–36 (defaults stay decimal):

```d
ParseExpected!T readInteger(T, ubyte radix = 10)(ref scope const(char)[] s);
void writeInteger(ubyte radix = 10)(ref Writer w, const T val);
void writeIntegerPadded(ubyte radix = 10)(ref Writer w, const T val, size_t minDigits);
```

For `radix >= 11`, `readInteger` accepts letter digits in either case;
`writeInteger` emits lower-case (consistent with `writeHexByte`). Named
shorthands are aliases: `readHex!T` / `writeHex`, `readBinary!T` /
`writeBinary`, `readOctal!T` / `writeOctal`.

```d
const(char)[] s = "DeadBEEF";
assert(readHex!uint(s).value == 0xDEADBEEF);

SmallBuffer!(char, 16) buf;
writeHex(buf, 0xDEADu);
assert(buf[] == "dead");
```
