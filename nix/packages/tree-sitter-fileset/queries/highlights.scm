; The fileset query language. Each capture is one token kind of
; `sparkles.build_primitives.fileset.query.TokenKind` (FXL8).

(text) @string                     ; path: a path's literal text
(string) @string                   ; path: a quoted piece, quotes and all
(meta) @punctuation.special        ; globMeta: * ** ? […] { , }
(escape) @string.escape            ; escape: \ and the metacharacter
(function) @function.builtin       ; function_
(predicate) @property              ; predicate
(comment) @comment                 ; comment

[
  "|"
  "&"
  "-"
  "&&"
  "||"
  "!"
  "=="
  "!="
] @operator                        ; operator

[
  "("
  ")"
] @punctuation.bracket             ; punctuation

"," @punctuation.delimiter         ; punctuation
