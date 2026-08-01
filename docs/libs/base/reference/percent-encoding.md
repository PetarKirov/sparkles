# Percent-encoding (`sparkles.base.text.percent`)

RFC 3986 percent-encoding ("URL encoding") and its
`application/x-www-form-urlencoded` variant.

Percent-encoding is an _escape_ encoding, not a bit-regrouping codec: safe
bytes pass through unchanged and every other byte becomes `%XX`. The only
thing that varies between contexts is **which bytes are safe**, so that is
the only thing parameterized — a `PercentSet` bound as a template value
parameter, exactly as [`Alphabet`](./base-codecs.md) is for the RFC 4648
family.

> The code blocks on this page use APIs introduced after the latest
> registry release; they become runnable (verified) examples once the next
> version is tagged.

## `PercentSet`

```d
struct PercentSet
{
    string extraUnreserved = "-._~"; // beyond ASCII alphanumerics
    bool   spaceAsPlus     = false;  // form-urlencoded: ' ' ⇄ '+'

    bool isConsistent() const;
}
```

ASCII letters and digits are always safe (every real encode set keeps
them); `extraUnreserved` names the additional punctuation the context
allows. Every other byte — including all non-ASCII — is escaped.

### Presets

| Preset                  | Unescaped beyond alnum | Notes                                                   |
| ----------------------- | ---------------------- | ------------------------------------------------------- |
| `percentComponent`      | `-._~`                 | RFC 3986 §2.3 unreserved; safe for any single component |
| `percentPathSegment`    | `-._~!$&'()*+,;=:@`    | RFC 3986 `pchar`; `/` is escaped                        |
| `percentQuery`          | `pchar` + `/?`         | a whole query string (`&` and `=` pass through)         |
| `percentFormUrlencoded` | `*-._`, space → `+`    | WHATWG URL §5.2                                         |

A `spaceAsPlus` set must escape both `' '` and `'+'`, or `'+'` would be
ambiguous on decode; the CTFE `PercentSet.isConsistent` predicate enforces
this with a `static assert` at instantiation, mirroring
[`Alphabet.isConsistent`](./base-codecs.md).

## Encoding

```d
import sparkles.base.smallbuffer : SmallBuffer;
import sparkles.base.text : encodePercentComponent;

SmallBuffer!(char, 64) buf;
encodePercentComponent(buf, "café / 100%");
assert(buf[] == "caf%C3%A9%20%2F%20100%25");
```

Hex digits are upper-case (RFC 3986 §2.1). Non-ASCII text encodes as its
UTF-8 bytes — the `const(char)[]` overload is the "encode as UTF-8, then
percent-encode" path; the `const(ubyte)[]` overload is the primitive.

The same input under each preset shows the whole difference between them:

| Input `a/b?c&d=e:f@g h+i` | Output                              |
| ------------------------- | ----------------------------------- |
| `percentComponent`        | `a%2Fb%3Fc%26d%3De%3Af%40g%20h%2Bi` |
| `percentPathSegment`      | `a%2Fb%3Fc&d=e:f@g%20h+i`           |
| `percentQuery`            | `a/b?c&d=e:f@g%20h+i`               |
| `percentFormUrlencoded`   | `a%2Fb%3Fc%26d%3De%3Af%40g+h%2Bi`   |

`percentEncodedLength!set(data)` returns the exact output size for
pre-sizing a buffer.

## Decoding

```d
import sparkles.base.text : decodePercentComponent;

SmallBuffer!(ubyte, 64) bytes;
auto r = decodePercentComponent(bytes, "caf%C3%A9");
assert(r.value == 5 && bytes[] == cast(const(ubyte)[]) "café");
```

Decoding writes bytes to a `ubyte` output range and returns the count
(never more than `text.length`, so that is a safe buffer size). Hex digits
are accepted in either case (RFC 3986 §6.2.2.1).

Malformed escapes are rejected with the shared `ParseError` vocabulary:

| Condition                              | `ParseErrorCode`      | Offset         |
| -------------------------------------- | --------------------- | -------------- |
| `%` with fewer than two chars after it | `unexpectedEnd`       | the `%`        |
| non-hex character in either position   | `unexpectedCharacter` | that character |

**Literal characters are not validated against the set.** A byte that
_should_ have been escaped decodes as itself — what every interoperable
decoder does, and why decoding is far less context-sensitive than
encoding. The set therefore only affects `'+'`: under a `spaceAsPlus` set
it decodes to a space, otherwise it is literal.

```d
decodePercentComponent(buf, "a+b");  // → "a+b"
decodeFormUrlencoded(buf, "a+b");    // → "a b"
```

As with the RFC 4648 decoders, the payload is taken by value rather than as
an advancing cursor, and on failure the writer may already hold a partial
prefix.

## Adding a context

Define a `PercentSet`; everything derives from it:

```d
enum PercentSet percentFragment = PercentSet(extraUnreserved: "-._~!$&'()*+,;=:@/?");
alias encodePercentFragment = encodePercent!percentFragment;
alias decodePercentFragment = decodePercent!percentFragment;
```

## Performance

Throughput is dominated by escape density, so the benchmark matrix varies
the data profile as well as the set (64 KiB, LDC `-O3 -mcpu=native`, via
`dub test :base -b bench -- --bench --group-by=set,op,data`):

| Path                      | text (mostly safe) | binary (uniform bytes) |
| ------------------------- | ------------------ | ---------------------- |
| `percentComponent` encode | 1.19 GB/s          | 509 MB/s               |
| `percentComponent` decode | 1.37 GB/s          | 1.02 GB/s              |
