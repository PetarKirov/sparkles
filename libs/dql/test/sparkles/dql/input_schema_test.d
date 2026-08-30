/**
Integration schemas: `sparkles.input.Event` through the reflection kernel.

The input vocabulary is plain data — no DQL knowledge, no resolver, no
policy. The schema is generated inside DQL from the types themselves; the
only input-side contributions are neutral metadata (`@Name`/`@Aliases` on
`Key`'s members and the variant types) and the language capability that makes
`KeyEvent.text` a `@property`.
*/
module sparkles.dql.input_schema_test;

version (unittest):

import std.sumtype : SumType;

import sparkles.dql.engine : DqlEngine;
import sparkles.dql.schema : DqlSchema, isDqlCategory, isDqlPath;
import sparkles.dql.testing : parseAndEvalDql;
import sparkles.input : Event, FocusEvent, Gesture, GestureEvent, Key, KeyAction,
    KeyEvent, Mods, NoEvent, Point, PointerAction, PointerButton, PointerEvent,
    ResizeEvent, WheelEvent;

alias InputSchema = DqlSchema!Event;
alias parseAndEval = parseAndEvalDql!InputSchema;

@("dql.input-schema: canonical paths mirror the event vocabulary")
@safe unittest
{
    foreach (path; [
        "key.key", "key.ch", "key.action", "key.unshifted", "key.text",
        "key.mods.ctrl", "key.mods.alt", "key.mods.shift", "key.mods.meta",
        "pointer.action", "pointer.button", "pointer.pos.x", "pointer.pos.y",
        "pointer.pointerId", "pointer.mods.meta",
        "wheel.dx", "wheel.dy", "wheel.precise", "wheel.pos.y",
        "focus.focused",
        "resize.size.width", "resize.size.height",
        "gesture.gesture", "gesture.pos.x", "gesture.scale",
    ])
        assert(isDqlPath!InputSchema(path), path);

    // Mechanical SumType transparency: no payload spelling.
    assert(!isDqlPath!InputSchema("payload.key.key"));
    // The synthetic categories are gone; field predicates replace them.
    assert(!isDqlPath!InputSchema("pointer.typo"));
}

@("dql.input-schema: categories come from the alternatives and their aliases")
@safe unittest
{
    foreach (name; ["key", "pointer", "ptr", "wheel", "scroll", "focus",
        "resize", "gesture", "none", "endOfInput"])
        assert(isDqlCategory!InputSchema(name), name);

    assert(!isDqlCategory!InputSchema("motion"));
    assert(!isDqlCategory!InputSchema("click"));
    assert(!isDqlCategory!InputSchema("text"));
}

@("dql.input-schema: enum values answer to wire names and aliases")
@safe unittest
{
    DqlEngine engine;
    Event event = KeyEvent(key: Key.pageUp, ch: 0, mods: Mods(ctrl: true),
        action: KeyAction.press);

    foreach (query; [
        "key.key == pageup",     // @Name spelling
        "key.key == pgup",       // @Aliases spelling
        "key.key == pageUp",     // declared identifier
        "key.action == press",
        "key.mods.ctrl == true",
        "key.mods.meta == false",
        "key.text == ``",        // no text paired
    ])
        assert(parseAndEval(engine, query, event), query);

    // Inactive variants are absent, not null and not matching.
    assert(!parseAndEval(engine, "pointer.button == left", event));
    assert(parseAndEval(engine, "pointer.button == null", event));
}

@("dql.input-schema: computed key text resolves from the event's own storage")
@safe unittest
{
    DqlEngine engine;
    KeyEvent stroke = KeyEvent(key: Key.char_, ch: 'a',
        mods: Mods(), action: KeyAction.press);
    stroke.text("hello");
    Event event = stroke;

    assert(parseAndEval(engine, "key.text == `hello`", event));
    assert(parseAndEval(engine, "key.text != `world`", event));
}

@("dql.input-schema: pointer coordinates and derived-value queries")
@safe unittest
{
    DqlEngine engine;
    Event pointer = PointerEvent(action: PointerAction.move,
        button: PointerButton.none, pos: Point(150, 200),
        mods: Mods(), pointerId: 3);

    foreach (query; [
        "pointer.pos.x == 150",
        "pointer.pos.y >= 200",
        "pointer.action == move",
        "pointer.pointerId == 3",
    ])
        assert(parseAndEval(engine, query, pointer), query);

    assert(!parseAndEval(engine, "pointer.pos.x > 160", pointer));

    // A present scalar is not null, whatever its value.
    assert(!parseAndEval(engine, "pointer.pos.x == null", pointer));

    // The value-dependent category spellings are expressed as field
    // predicates now.
    assert(parseAndEval(engine, "pointer.action == move", pointer));
}
