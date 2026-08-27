# Links

Inline: a [plain link](https://example.com) and one carrying a
[title](https://example.com/titled "The example site").

Autolink: <https://example.com/autolink>.

Reference forms: a [full reference][ref-link], a [collapsed][], and a bare
[shortcut].

Formatting inside a reference label: [**an important** `code` *note*][ref-link]
keeps its bold, its code pill and its italics.

An undefined label stays literal text: [not defined][missing-ref].

A reference image renders its alt text: ![diagram][img-ref].

Links in a table:

| Form      | Example                       |
| --------- | ----------------------------- |
| inline    | [inline](https://example.com) |
| reference | [**bold** ref][ref-link]      |
| shortcut  | [shortcut]                    |

A callout marker is a shortcut link with no definition, so it stays a marker:

> [!NOTE]
> Reference definitions render nothing at all.

[ref-link]: https://example.com/reference "Reference destination"
[collapsed]: https://example.com/collapsed
[shortcut]: https://example.com/shortcut
[img-ref]: diagram.png "A diagram"
