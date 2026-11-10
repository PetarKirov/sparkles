/**
 * The fileset query language (docs/specs/fileset-explorer/SPEC.md §2), as
 * `sparkles.build_primitives.fileset.query` parses it. `FXL8` keeps the two
 * equal: over a shared corpus this grammar has an error exactly where the D
 * parser fails, and its highlight captures are the parser's token kinds.
 *
 * A path is a run of pieces written together: literal text, glob
 * metacharacters, escapes, brace groups and quoted pieces. Its first piece is
 * an ordinary token and every later one an immediate token, so whitespace
 * ends a path.
 *
 * @file Fileset query grammar for tree-sitter
 * @license BSL-1.0
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// Literal text: none of whitespace, `(`, `)`, `"`, `,`, `\`, `*`, `?`, `[`,
// `{` or `}`. A path's first piece does not begin with `#` or `!`.
const TEXT_FIRST = /[^\s()",\\*?\[{}#!][^\s()",\\*?\[{}]*/;
const TEXT = /[^\s()",\\*?\[{}]+/;
const STAR = /\*\*?/;
const CLASS = /\[[!^]?([^\s()",\]\\]|\\[^\s])+\]/;
const ESCAPE = /\\[*?\[\]{},!\\]/;
const STRING = /"([^"\\]|\\.)*"/;

// The calls a bare word may also be the first piece of a path for.
const CALLS = [
  'all',
  'none',
  'exec',
  'gitignored',
  'gitTracked',
  'unions',
  'intersection',
  'difference',
  'fileFilter',
];

export default grammar({
  name: 'fileset',

  extras: $ => [/\s/, $.comment],

  rules: {
    query: $ => optional($._expression),

    _expression: $ => choice($.union, $.difference, $._term),

    // `|` and `-` each chain to the left, but one never takes the other as
    // an operand without parentheses (`FXL3`).
    union: $ =>
      seq(
        field('left', choice($.union, $._term)),
        '|',
        field('right', $._term),
      ),
    difference: $ =>
      seq(
        field('left', choice($.difference, $._term)),
        '-',
        field('right', $._term),
      ),

    _term: $ => choice($.intersection, $._unary),
    intersection: $ =>
      seq(field('left', $._term), '&', field('right', $._unary)),

    _unary: $ =>
      choice($.parenthesized, $.call, $.nullary, $.file_filter, $.path),

    parenthesized: $ => seq('(', $._expression, ')'),

    call: $ =>
      seq(
        field(
          'function',
          alias(choice('unions', 'intersection', 'difference'), $.function),
        ),
        '(',
        $._expression,
        repeat(seq(',', $._expression)),
        ')',
      ),

    nullary: $ =>
      seq(
        field(
          'function',
          alias(
            choice('all', 'none', 'exec', 'gitignored', 'gitTracked'),
            $.function,
          ),
        ),
        '(',
        ')',
      ),

    file_filter: $ =>
      seq(
        field('function', alias('fileFilter', $.function)),
        '(',
        $._predicate,
        ')',
      ),

    _predicate: $ =>
      choice(
        $.or,
        $.and,
        $.not,
        $.has_ext,
        $.name_is,
        $.type_is,
        $.predicate_group,
      ),

    or: $ => prec.left(1, seq($._predicate, '||', $._predicate)),
    and: $ => prec.left(2, seq($._predicate, '&&', $._predicate)),
    not: $ => prec(3, seq('!', $._predicate)),
    predicate_group: $ => seq('(', $._predicate, ')'),
    has_ext: $ => seq(alias('hasExt', $.function), '(', $.path, ')'),
    name_is: $ => seq(alias('name', $.predicate), choice('==', '!='), $.path),
    type_is: $ =>
      seq(
        alias('type', $.predicate),
        choice('==', '!='),
        choice(
          alias(choice('regular', 'symlink'), $.text),
          alias(choice('"regular"', '"symlink"'), $.string),
        ),
      ),

    // ---- paths ------------------------------------------------------------

    path: $ => seq($._first_piece, repeat($._next_piece)),

    _first_piece: $ =>
      choice(
        alias(token(TEXT_FIRST), $.text),
        alias(choice(...CALLS), $.text),
        alias(token(STAR), $.meta),
        alias(token('?'), $.meta),
        alias(token(CLASS), $.meta),
        alias(token(ESCAPE), $.escape),
        alias(token(STRING), $.string),
        $.brace,
      ),

    _next_piece: $ =>
      choice(
        alias(token.immediate(prec(1, TEXT)), $.text),
        alias(token.immediate(STAR), $.meta),
        alias(token.immediate('?'), $.meta),
        alias(token.immediate(CLASS), $.meta),
        alias(token.immediate(ESCAPE), $.escape),
        alias(token.immediate(STRING), $.string),
        alias($._brace_next, $.brace),
      ),

    // A brace group: `{`, alternatives split by `,`, `}`; no alternative is
    // empty, and none holds a quoted piece.
    brace: $ =>
      seq(
        alias('{', $.meta),
        $._alternative,
        repeat(seq(alias(token.immediate(','), $.meta), $._alternative)),
        alias(token.immediate('}'), $.meta),
      ),
    _brace_next: $ =>
      seq(
        alias(token.immediate('{'), $.meta),
        $._alternative,
        repeat(seq(alias(token.immediate(','), $.meta), $._alternative)),
        alias(token.immediate('}'), $.meta),
      ),
    _alternative: $ =>
      repeat1(
        choice(
          alias(token.immediate(prec(1, TEXT)), $.text),
          alias(token.immediate(STAR), $.meta),
          alias(token.immediate('?'), $.meta),
          alias(token.immediate(CLASS), $.meta),
          alias(token.immediate(ESCAPE), $.escape),
          alias($._brace_next, $.brace),
        ),
      ),

    comment: _ => token(seq('#', /[^\n]*/)),
  },
});
