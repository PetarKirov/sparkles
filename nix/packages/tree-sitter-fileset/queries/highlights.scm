; The fileset query language. Each capture is one token kind of
; `sparkles.build_primitives.fileset.query.TokenKind` (FXL8).

(glob) @string.special.path        ; glob
(string) @string                   ; string_
(keyword) @constant.builtin        ; keyword
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
] @operator                        ; operator

[
  "("
  ")"
] @punctuation.bracket             ; punctuation

"," @punctuation.delimiter         ; punctuation
