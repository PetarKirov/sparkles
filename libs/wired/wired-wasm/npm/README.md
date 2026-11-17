# @sparkles-pkgs/wired

JSON, SDL and dub recipes, parsed, written and decoded in Node.js and in
browsers by `sparkles:wired` (in the PetarKirov/sparkles repository)
compiled to WebAssembly: the same readers, writers and dub recipe schema the
D library ships, not a port.

```js
import { load } from '@sparkles-pkgs/wired';

const wired = await load();

wired.parse('sdl', 'server "web" port=8080\n').tree;
// [{ name: 'server', line: 1, values: [{ kind: 'string', text: '"web"' }],
//    attributes: [{ name: 'port', value: { kind: 'integer', text: '8080' } }], children: [] }]

wired.format('json', '{"a":[1,{}]}').text; // two-space indented, members in source order

wired.recipe('name "app"\ndependency "sparkles:base" path="../.."\n').recipe;
// { dependencies: [{ name: 'sparkles:base', path: '../..' }], name: 'app' }

wired.recipe('targetTyp "library"\n').error;
// { name: 'dub.sdl', line: 1, column: 1, code: 'unknownMember',
//   message: 'Cannot decode a DUB recipe: unknown directive `targetTyp`' }
```

Text that does not parse or decode is an `error` value with its line and
column. A malformed call (an unknown format) throws a `TypeError`, and a
request larger than the module's buffer (`wired.capacity` bytes, 128 KiB)
throws a `RangeError`.

`load()` instantiates the `spk-wired.wasm` this package ships; pass the
module's bytes, a `Response` or a URL to load another copy (a bundler's
asset URL, for example). Each `load()` is a separate instance.

The module's interface is specified in the repository's
`docs/specs/wired/wasm/SPEC.md` (WW12, WW13).
