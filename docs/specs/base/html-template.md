# `sparkles.base.html_template` — Design

_Audience: developers and coding agents building against `sparkles:base`. This
document is normative: it states what an interpolated HTML literal means, which
escape each interpolation receives, and which templates are rejected at compile
time. Status: **designed, not implemented** — the mechanism is proven by a
prototype (§9), the module is not written yet._

## 1. Overview

D's [Interpolated Expression Sequences][ies] hand a library the literal parts of
a string _and_ the source text of every interpolated expression, separately, at
compile time. `sparkles.base.styled_template` already uses that for terminal
styling. HTML wants the same treatment for a sharper reason: **the correct
escape for a value depends on where the value lands**, and only the library sees
both halves.

```d
writeHtml(w, i`<a class=$(cls) href="/users/$(id)/profile?q=$(term)">$(name)</a>`);
```

Four interpolations, four different escapes, none chosen by the caller:

| Value  | Lands in           | Treatment                                                         |
| ------ | ------------------ | ----------------------------------------------------------------- |
| `cls`  | unquoted attribute | quotes added, then five-entity escape                             |
| `id`   | URL path segment   | `percentPathSegment` (so `/` cannot escape), then entity-escape   |
| `term` | URL query          | `percentComponent` (so `&`/`=` cannot escape), then entity-escape |
| `name` | text content       | five-entity escape                                                |

The alternative in this repository today is hand-written: `w ~= "<a href=\"";
escapeInto(w, href); w ~= "\">";` — three statements per element, with the
escape call as an unchecked convention. `sparkles.docs.page_shell`,
`sparkles.docs.sidebar`, `sparkles.docs.breadcrumbs` and
`sparkles.docs.site_tree` are ~2,000 lines of it, and
`sparkles.syntax.md.render_html` more. Those are the first consumers.

| Identifier      | Value                                                                                                      |
| --------------- | ---------------------------------------------------------------------------------------------------------- |
| Dub sub-package | `sparkles:base`                                                                                            |
| Source root     | `libs/base/src/sparkles/base/`                                                                             |
| Module          | `sparkles.base.html_template`                                                                              |
| Depends on      | `sparkles.base.text.html` (`writeHtmlEscaped`), `sparkles.base.text.percent`, `sparkles.base.text.writers` |

Inspired by `07-html.d` in the upstream [interpolation examples][examples],
which parses the literal into an `arsd.dom` tree and validates it under CTFE.
This design keeps the compile-time validation and drops the DOM: no tree is
built, nothing is allocated, and the output is written straight to an output
range (§6).

## 2. Requirements

| ID    | Requirement                                                                                                                                                                                                                                                                                                                                                           |
| ----- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| HTL1  | **Context decides the escape.** Every interpolation is classified by scanning the literal skeleton, and escaped for that context alone (§3, §4). A caller never names an escape for a plain value.                                                                                                                                                                    |
| HTL2  | **Classification is compile-time.** The scan runs during CTFE over the `InterpolatedLiteral!lit` parts; the context of each interpolation is a template constant, so the runtime path is the escape loop and nothing else — no per-value branch on a stored state.                                                                                                    |
| HTL3  | **Unsound placements are compile errors**, naming the offending expression's own source text: tag-name and attribute-name positions (HTL7), raw-text elements (HTL8), comments (HTL9), and unterminated attribute quotes.                                                                                                                                             |
| HTL4  | **Auto-quoting.** An interpolation in an unquoted attribute value (`class=$(x)`) emits `"…"` around the escaped value. An unquoted value that contains a space would otherwise become two attributes; quoting is always correct, so it is not left to the caller.                                                                                                     |
| HTL5  | **URL attributes are percent-encoded per position**, not entity-escaped only: `percentPathSegment` before a `?`, `percentComponent` after it, `percentFragment` after a `#`, then the five-entity escape on top (an attribute is still an attribute). The URL attribute set is `href src action formaction cite poster data ping srcset manifest`.                    |
| HTL6  | **A whole-URL interpolation is checked, not encoded.** `href=$(url)` (the value _is_ the interpolation) cannot be percent-encoded — that would destroy `://`. It is scheme-checked instead: `javascript:`, `vbscript:` and `data:` (other than `data:image/*`) are rejected at **runtime** as `HtmlError.unsafeScheme`, since the value is not known at compile time. |
| HTL7  | **Structure is static.** `<$(tag)>` and `<div $(attr)="x">` do not compile: an attacker-chosen tag or attribute name is not an escaping problem but a structural one, and there is no escape that makes it safe.                                                                                                                                                      |
| HTL8  | **No interpolation into `<script>`/`<style>`.** Raw-text elements have no character references, so no escape exists; the value must arrive through `json(x)` or `cssValue(x)` (§5), which serialize into a form that cannot close the element.                                                                                                                        |
| HTL9  | **No interpolation into comments**, where `--` and `>` terminate unpredictably across parsers.                                                                                                                                                                                                                                                                        |
| HTL10 | **Skeleton validation.** The literal must be well-formed on its own: tags balanced (accounting for the void elements), attribute quotes closed, raw-text elements closed. Violations are compile errors, quoting the tag and the byte offset.                                                                                                                         |
| HTL11 | **Escape hatches are explicit and greppable**: `raw(x)` (pre-escaped markup, e.g. a fragment from another `html` call), `attrs(range)` (a spread of name/value pairs in a tag), `json(x)`, `cssValue(x)`. A `raw` is the only way unescaped bytes reach the output.                                                                                                   |
| HTL12 | **Composition without double-escaping.** `htmlText(...)` returns an `HtmlFragment` (a `string` newtype); interpolating one into another template writes it verbatim, exactly as `raw` does, because it is already escaped.                                                                                                                                            |
| HTL13 | **Writer-first, allocation-free.** The primitive is `writeHtml(ref Writer, …)` over any `char` output range; attributes are inferred, and the path is `@safe pure nothrow @nogc` for a `@nogc` writer and values with `@nogc` conversions (§6). `htmlText` and the lazy `html` wrapper are conveniences over it.                                                      |
| HTL14 | **Values render through `sparkles.base.text.writers.writeValue`** — the same vocabulary `styled_template` uses, so an `int`, a `Duration`, a `SmallBuffer` or a `toString`-bearing type all interpolate without a caller-side `.text`.                                                                                                                                |

## 3. The context model

The scanner is a plain byte state machine over the literal parts, carried across
them (an interpolation can sit anywhere, including mid-attribute). Its state is
the tuple `(inTag, quote, afterEq, attrName, urlSection, rawTextElement)`.

| Context        | Reached at                                 | Example                        |
| -------------- | ------------------------------------------ | ------------------------------ |
| `text`         | outside any tag                            | `<p>$(x)</p>`                  |
| `attrQuoted`   | inside `"…"` or `'…'` after `=`            | `<p class="$(x)">`             |
| `attrUnquoted` | directly after `=`                         | `<p class=$(x)>`               |
| `urlWhole`     | a URL attribute whose value _is_ the value | `<a href=$(u)>`, `href="$(u)"` |
| `urlPath`      | inside a URL attribute, before `?`/`#`     | `<a href="/u/$(id)">`          |
| `urlQuery`     | inside a URL attribute, after `?`          | `<a href="/s?q=$(q)">`         |
| `urlFragment`  | inside a URL attribute, after `#`          | `<a href="/p#$(anchor)">`      |
| `tagName`      | inside `<…` before the first space         | `<$(t)>` — **error**           |
| `attrName`     | in a tag, not after `=`                    | `<p $(a)="1">` — **error**     |
| `rawText`      | inside `<script>`/`<style>`                | **error** unless §5            |
| `comment`      | inside `<!-- … -->`                        | **error**                      |

`urlWhole` is distinguished from `urlPath` by one bit: whether any literal byte
of the attribute value precedes the interpolation. `href="/u/$(id)"` has `/u/`;
`href="$(u)"` has nothing, so the value must carry its own scheme and authority
and is checked rather than encoded (HTL6).

## 4. The escape table

| Context                   | Applied, in order                                          |
| ------------------------- | ---------------------------------------------------------- |
| `text`                    | `writeHtmlEscaped`                                         |
| `attrQuoted`              | `writeHtmlEscaped` (five entities cover both quote styles) |
| `attrUnquoted`            | `'"'`, `writeHtmlEscaped`, `'"'`                           |
| `urlPath`                 | `encodePercent!percentPathSegment` → `writeHtmlEscaped`    |
| `urlQuery`                | `encodePercent!percentComponent` → `writeHtmlEscaped`      |
| `urlFragment`             | `encodePercent!percentFragment` → `writeHtmlEscaped`       |
| `urlWhole`                | scheme check (HTL6) → `writeHtmlEscaped`                   |
| `raw(x)` / `HtmlFragment` | verbatim                                                   |

`percentComponent` in a query — rather than `percentQuery` — is deliberate: the
interpolation is one parameter's name or value, so `&` and `=` must not survive
it. `percentQuery` describes a _whole_ query string and would let an
interpolated value append parameters.

Percent-encoding runs before entity-escaping because it is the URL layer;
`&` produced by neither stage is left ambiguous (`%26` from the first stage
survives the second unchanged, and a literal `&` in a path becomes `&amp;`).

## 5. API surface

```d
// The primitive.
void writeHtml(Writer, Args...)(ref Writer w, InterpolationHeader, Args, InterpolationFooter);

// Conveniences.
HtmlFragment htmlText(Args...)(InterpolationHeader, Args, InterpolationFooter);   // allocates
auto         html    (Args...)(InterpolationHeader, Args, InterpolationFooter);   // lazy: toString + writer

// An already-escaped fragment. `HtmlFragment` is what `htmlText` returns, so
// templates compose (HTL12); `raw` is the assertion a caller makes about text
// from elsewhere, and the only unescaped path (HTL11).
struct HtmlFragment { string value; alias value this; }
HtmlFragment raw(scope const(char)[] markup);

// Contexts that no escape can make safe (HTL8).
struct JsonValue  { … }  JsonValue json(T)(auto ref T value);       // for <script>
struct CssValue   { … }  CssValue  cssValue(scope const(char)[] v); // for <style>

// A spread of attributes in tag position: `<div $(attrs(m))>`.
struct Attrs(R) { R pairs; }  Attrs!R attrs(R)(R nameValuePairs);

// Conditional/boolean attributes: `<input $(attr("disabled", isLocked))>`.
struct Attr { const(char)[] name; const(char)[] value; bool present = true; }
Attr attr(const(char)[] name, const(char)[] value);
Attr attr(const(char)[] name, bool present);
```

Runtime failures (HTL6 is the only one) follow the repository's
[`Expected`](../../guidelines/idioms/expected/index.md) convention on the
writer path: `writeHtmlChecked` returns `Expected!(void, HtmlError)`, while
`writeHtml` treats a rejected scheme as a hard error (`recycledErrorInstance`)
— a URL the policy refuses is never silently emitted, and never silently
dropped either.

## 6. Attributes and cost

The scan is CTFE-only, so nothing of it survives into the binary: each
interpolation compiles to one call to the escape its context selected. Both
escapes are `@safe pure nothrow @nogc` over an output range already
(`writeHtmlEscaped`, and the
[percent encoders](../../libs/base/reference/percent-encoding.md)), and values render through `writeValue`, so the whole path
inherits the attributes of the writer and the value's conversion — exactly the
`styled_template` contract.

The one allocation the naive implementation would make is a temporary for
"render the value, then escape the rendered text". It is avoided by giving the
escapers an output-range adaptor: `writeValue` writes _into_ an escaping
writer, so the bytes are escaped as they are produced. The `urlPath` and
`urlQuery` contexts stack two adaptors (percent, then entity) the same way.

## 7. Non-goals

- **No DOM.** Nothing is queried, mutated or re-serialized; if a caller needs a
  tree, that is a different library.
- **No template files.** This is a D-source construct; a runtime template
  language has different requirements (caching, sandboxing, hot reload).
- **No HTML parsing of untrusted input.** `raw` is a caller's assertion, not a
  sanitizer. Sanitizing hostile markup is out of scope.
- **No pretty-printing.** Whitespace is the caller's, byte for byte.

## 8. Milestones

| ID    | Milestone                                                                                                                                                                                        |
| ----- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| HTLM1 | Scanner + context classification + `text`/`attrQuoted`/`attrUnquoted` escapes; `writeHtml`/`htmlText`.                                                                                           |
| HTLM2 | URL contexts (HTL5/HTL6) and the escaping-writer adaptors that remove the temporary (§6).                                                                                                        |
| HTLM3 | Compile-time rejections and skeleton validation (HTL3, HTL7–HTL10) with the error-message corpus.                                                                                                |
| HTLM4 | `raw`/`HtmlFragment`/`attrs`/`attr` (HTL11–HTL12); `json`/`cssValue`.                                                                                                                            |
| HTLM5 | Adoption: `sparkles.docs.breadcrumbs` and `sparkles.docs.sidebar` first (smallest, most markup-dense), then `page_shell`. A/B the generated site — byte-identical output is the acceptance test. |

## 9. Prototype evidence

A ~200-line prototype (scanner + classification + the four escapes) compiles and
runs. Given

```d
const cls  = `a" onload="evil()`;
const name = "<script>alert('x')</script>";
const id   = 65;
const term = "rock & roll/jazz";

writeln(html(i`<p class="$(cls)">Hello, $(name)!</p>`));
writeln(html(i`<a href="/users/$(id)/profile?q=$(term)">link</a>`));
writeln(html(i`<div class=$(cls)>auto-quoted</div>`));
writeln(html(i`<a href="/files/$(term)">path segment</a>`));
```

it writes:

```html
<p class='a" onload="evil()'>
  Hello, &lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt;!
</p>
<a href="/users/65/profile?q=rock%20%26%20roll%2Fjazz">link</a>
<div class='a" onload="evil()'>auto-quoted</div>
<a href="/files/rock%20&amp;%20roll%2Fjazz">path segment</a>
```

— attribute-injection defeated, path traversal defeated (`/` → `%2F`), query
parameter injection defeated (`&` → `%26`), and the unquoted attribute quoted.
The two rejections report the expression's own source text:

```
Error: static assert:  "`cls` interpolates into a tag/attribute NAME position"
Error: static assert:  "`cls` interpolates into <script>/<style>: no escaping is safe there"
```

[ies]: ../../guidelines/interpolated-expression-sequences.md
[examples]: https://github.com/adamdruppe/interpolation-examples/blob/a8a5d4d4ee37ee9ae3942c4f4e8489011c3c4673/07-html.d
