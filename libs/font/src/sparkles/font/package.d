/**
Font files parsed in D (`docs/specs/font`).

Milestone M1: faces and collections over borrowed bytes, the table
directory, typed views of the fixed tables, character maps, `name` records
and glyph names. Every operation reads only inside the caller's buffer,
reports malformed data as a `FontError` rather than asserting, and does not
allocate.

$(UL
    $(LI `sparkles.font.face` — `openFace`, `openCollection`, `Face`, table lookup and inspection.)
    $(LI `sparkles.font.tables` — `head`, `hhea`, `maxp`, `OS/2`, `post`, `hmtx`, `fvar`, `avar`, `STAT`, spacing.)
    $(LI `sparkles.font.cmap` — `charMap`, lookups, coverage ranges and variation sequences.)
    $(LI `sparkles.font.names` — `name` records and their text.)
    $(LI `sparkles.font.glyph_names` — glyph names from `post` and `CFF`.)
    $(LI `sparkles.font.errors` — `FontError`, `FontResult` and `Tag`.)
)
*/
module sparkles.font;

public import sparkles.font.cmap;
public import sparkles.font.errors;
public import sparkles.font.face;
public import sparkles.font.glyph_names;
public import sparkles.font.names;
public import sparkles.font.tables;
