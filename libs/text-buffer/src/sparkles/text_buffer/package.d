/**
Persistent editable text: a summary tree of UTF-8 chunks (`Text`), edits as
values (`ChangeSet`), and a branching undo history (`History`).

Specification: `docs/specs/text-buffer/SPEC.md`.
*/
module sparkles.text_buffer;

public import sparkles.text_buffer.summary;
public import sparkles.text_buffer.text;
