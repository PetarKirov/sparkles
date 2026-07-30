module sample;
// ---cut---
/++
Escapes `<html>` markup: the literal \$(NOT_A_MACRO) stays as text, and
snake_case_name keeps every underscore it was written with.

Params:
    snake_case_name = the text to escape, underscores and all
    count = how many replacements to allow; the _count spelling in this
            sentence suppresses the usual identifier emphasis
Returns: The escaped text, with `<` and `&` replaced.
+/
string escapeHtml(string snake_case_name, int count) => snake_case_name;
//     ^?
