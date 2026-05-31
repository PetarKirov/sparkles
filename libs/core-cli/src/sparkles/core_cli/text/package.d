/**
Low-level text I/O primitives for CLI tooling.

This package groups the building blocks that read, write, and report
errors on text without committing to any higher-level format:

$(UL
    $(LI `sparkles.core_cli.text.writers` — integer / float / escaped
        output-range writers.)
)

Importing `sparkles.core_cli.text` pulls in the whole package.
*/
module sparkles.core_cli.text;

public import sparkles.core_cli.text.writers;
