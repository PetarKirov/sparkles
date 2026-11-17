// The package against its own module, under node --test: each operation in
// each format, errors as values, faults and size limits as exceptions.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { load } from '../index.js';

const wired = await load();

test('SDL: a document tree with kinds and canonical spellings', () => {
  const { tree } = wired.parse('sdl', 'a 1 k="v" {\n  b\n}\n');
  assert.deepEqual(tree, [
    {
      name: 'a',
      line: 1,
      values: [{ kind: 'integer', text: '1' }],
      attributes: [{ name: 'k', value: { kind: 'string', text: '"v"' } }],
      children: [
        { name: 'b', line: 2, values: [], attributes: [], children: [] },
      ],
    },
  ]);
  assert.equal(wired.format('sdl', 'a   1\n').text, 'a 1\n');
});

test('JSON: the value, and the value indented', () => {
  assert.deepEqual(wired.parse('json', '{"b": [1, 2.5], "a": null}').tree, {
    b: [1, 2.5],
    a: null,
  });
  assert.equal(
    wired.format('json', '{"a":[1,{}]}').text,
    '{\n  "a": [\n    1,\n    {}\n  ]\n}\n',
  );
});

test('recipes: SDL, JSON and embedded, as the Nix module answers', () => {
  assert.deepEqual(
    wired.recipe('name "x"\ndependency "sparkles:base" path="../.."\n').recipe,
    {
      dependencies: [{ name: 'sparkles:base', path: '../..' }],
      name: 'x',
    },
  );
  assert.deepEqual(wired.recipe('{"name": "j"}', 'dub.json').recipe, {
    name: 'j',
  });
  assert.deepEqual(
    wired.recipe('/+ dub.sdl:\n    name "e"\n+/\n', 'e.d').recipe,
    { name: 'e' },
  );
});

test('errors are values', () => {
  const { error } = wired.recipe('name "x"\ntargetTyp "library"\n');
  assert.equal(error.code, 'unknownMember');
  assert.equal(error.line, 2);
  assert.equal(error.column, 1);
  assert.match(error.message, /unknown directive `targetTyp`/);
  assert.equal(wired.parse('json', '{\n  "a": ]').error.line, 2);
});

test('a malformed request and an oversized one throw', () => {
  assert.throws(() => wired.parse('yaml', ''), TypeError);
  assert.throws(
    () => wired.parse('sdl', 'x'.repeat(wired.capacity + 1)),
    RangeError,
  );
});

test('load accepts the module as bytes', async () => {
  const bytes = await readFile(new URL('../spk-wired.wasm', import.meta.url));
  const again = await load(bytes);
  assert.equal(again.recipe('name "y"\n').recipe.name, 'y');
});
