/**
 * The fileset query language (docs/specs/fileset-explorer/SPEC.md §2), as
 * `sparkles.build_primitives.fileset.query` parses it. `FXL8` keeps the two
 * equal: over a shared corpus this grammar has an error exactly where the D
 * parser fails, and its highlight captures are the parser's token kinds.
 *
 * @file Fileset query grammar for tree-sitter
 * @license BSL-1.0
 */

/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// A brace group of a glob, where a comma belongs to the glob: two levels deep.
const BRACE_INNER = /\{[^\s()"{}]*\}/;
const BRACE = seq('{', repeat(choice(/[^\s()"{}\\]/, /\\./, BRACE_INNER)), '}');

export default grammar({
  name: 'fileset',

  extras: $ => [/\s/, $.comment],

  word: $ => $.glob,

  rules: {
    query: $ => optional($._expression),

    _expression: $ => choice($.union, $.difference, $.intersection, $._unary),

    union: $ =>
      prec.left(
        1,
        seq(field('left', $._expression), '|', field('right', $._expression)),
      ),
    difference: $ =>
      prec.left(
        1,
        seq(field('left', $._expression), '-', field('right', $._expression)),
      ),
    intersection: $ =>
      prec.left(
        2,
        seq(field('left', $._expression), '&', field('right', $._expression)),
      ),

    _unary: $ =>
      choice(
        $.parenthesized,
        $.call,
        $.file_filter,
        $.keyword,
        $.glob,
        $.string,
      ),

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
    has_ext: $ => seq(alias('hasExt', $.function), '(', $.string, ')'),
    name_is: $ => seq(alias('name', $.predicate), '==', $.string),
    type_is: $ => seq(alias('type', $.predicate), '==', $.string),

    keyword: _ => choice('all', 'none', 'exec', 'gitignored', 'gitTracked'),

    // A bare glob: no whitespace, `(`, `)`, `"`, and a comma only inside
    // braces; it does not begin with `#` (a comment) or `!` (negation).
    glob: _ =>
      token(
        seq(
          choice(/[^\s()",#!{\\]/, /\\./, BRACE),
          repeat(choice(/[^\s()",{\\]/, /\\./, BRACE)),
        ),
      ),

    string: _ => token(seq('"', repeat(choice(/[^"\\]/, /\\./)), '"')),

    comment: _ => token(seq('#', /[^\n]*/)),
  },
});
