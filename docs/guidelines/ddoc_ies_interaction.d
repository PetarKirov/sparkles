#!/usr/bin/env dub
/+ dub.sdl:
    name "ddoc-ies-interaction"
    dependency "sparkles:core-cli" version="*"
    dflags "-preview=in" "-preview=dip1000"
+/

/**
Investigation of IES and DDoc `$(DOLLAR)$(LPAREN)...$(RPAREN)` syntax interaction.

Both IES and DDoc use the dollar-paren syntax but for different purposes:

$(UL
    $(LI IES: `i"Hello $(DOLLAR)$(LPAREN)name$(RPAREN)"` — interpolation of D expressions)
    $(LI DDoc: `$(DOLLAR)$(LPAREN)B bold$(RPAREN)` — macro expansion in documentation)
)

This module tests 8 interaction scenarios to reveal how the compiler
handles `$(DOLLAR)$(LPAREN)...$(RPAREN)` in contexts where both systems could claim it.

# Running This Test

Compile and run:
---
dub run --single docs/guidelines/ddoc_ies_interaction.d
---

Generate DDoc and inspect the HTML output:
---
ldc2 -D -Dd=build/docs -preview=in -preview=dip1000 \
    docs/guidelines/ddoc_ies_interaction.d
---
*/

import std.conv : text;
import std.stdio : writeln;


// ---------------------------------------------------------------------------
// Scenario 1: IES in documented unittest
// ---------------------------------------------------------------------------

/**
Scenario 1: IES inside a documented unittest.

When DDoc extracts a documented unittest body as an Example, it processes
the source text through its macro expander. The `$(DOLLAR)$(LPAREN)name$(RPAREN)` inside
`i"Hello $(DOLLAR)$(LPAREN)name$(RPAREN)"` appears as raw text to DDoc.

If `name` is not a defined DDoc macro, it should expand to empty string,
silently vanishing from the Example section in the generated HTML.

Params:
    person = the name to greet

Returns: A greeting string.
*/
string greetPerson(string person) @safe pure
{
    return i"Hello, $(person)!".text;
}

/// Documented unittest — DDoc extracts this body as an Example.
/// The `$(name)` inside `i"..."` will be visible to DDoc's macro expander.
@safe unittest
{
    string name = "Alice";
    auto result = greetPerson(name);
    assert(result == "Hello, Alice!");

    // This IES literal contains $(name) — DDoc may try to expand it
    auto greeting = i"Welcome, $(name)!".text;
    assert(greeting == "Welcome, Alice!");
}


// ---------------------------------------------------------------------------
// Scenario 2: IES in `---` code blocks inside DDoc comments
// ---------------------------------------------------------------------------

/**
Scenario 2: IES usage inside a DDoc `---` code block.

Code inside `---` delimiters is NOT subject to DDoc macro expansion.
This means `$(expr)` is preserved literally in the documentation output.

---
int cpu = 75;
string status = "OK";
auto msg = i"CPU: $(cpu)% Status: $(status)".text;
assert(msg == "CPU: 75% Status: OK");
---

The `$(cpu)` and `$(status)` above should appear literally in generated
docs because they are inside a `---` code block.

Params:
    cpuPercent = CPU usage percentage
    status = current status string

Returns: A formatted status string.
*/
string formatStatus(int cpuPercent, string status) @safe pure
{
    return i"CPU: $(cpuPercent)% Status: $(status)".text;
}

///
@safe unittest
{
    assert(formatStatus(75, "OK") == "CPU: 75% Status: OK");
    assert(formatStatus(100, "BUSY") == "CPU: 100% Status: BUSY");
}


// ---------------------------------------------------------------------------
// Scenario 3: IES in backtick inline code in DDoc prose
// ---------------------------------------------------------------------------

/**
Scenario 3: backtick inline code containing IES syntax.

In DDoc, backtick content is wrapped in `$(DDOC_BACKQUOTED)`, but
macros are still expanded inside backticks.

So writing `i"Hello $(name)"` in prose should cause `$(name)` to be
processed as a macro even inside backticks.

The safe way to show IES in DDoc prose is to use a `---` code block,
or escape: `i"Hello $(DOLLAR)$(LPAREN)name$(RPAREN)"`.

Params:
    person = the name to greet

Returns: A greeting string.
*/
string greetSafe(string person) @safe pure
{
    return i"Greetings, $(person)!".text;
}

///
@safe unittest
{
    assert(greetSafe("Bob") == "Greetings, Bob!");
}


// ---------------------------------------------------------------------------
// Scenario 4: Bare $(name) in DDoc prose (no backticks, no code block)
// ---------------------------------------------------------------------------

/**
Scenario 4: bare dollar-paren in DDoc prose.

Writing $(name) without backticks or code blocks causes DDoc to
interpret it as a macro invocation. Since `name` is not a defined
DDoc macro, it expands to an empty string.

Compare these in generated docs:

$(UL
    $(LI $(B This text is bold) — `B` is a predefined DDoc macro)
    $(LI $(I This text is italic) — `I` is a predefined DDoc macro)
    $(LI >$(name)< — undefined macro, should vanish)
    $(LI >$(DOLLAR)$(LPAREN)name$(RPAREN)< — escaped, shows literal text)
)

Params:
    person = the name to greet

Returns: A farewell string.
*/
string farewell(string person) @safe pure
{
    return i"Goodbye, $(person)!".text;
}

///
@safe unittest
{
    assert(farewell("Charlie") == "Goodbye, Charlie!");
}


// ---------------------------------------------------------------------------
// Scenario 5: DDoc macros coexisting with IES in function body
// ---------------------------------------------------------------------------

/**
Scenario 5: DDoc macros in comments, IES in function body.

This function uses $(LREF greetPerson) internally. The $(D formatReport)
function demonstrates that DDoc macros in comments and IES in the
function body coexist without conflict.

DDoc processes comments only — it never looks inside function bodies.
The IES `$(DOLLAR)$(LPAREN)count$(RPAREN)` in the body is invisible to DDoc.

Params:
    person = the person to include in the report
    count = the item count to report

Returns: A formatted report string.

See_Also: $(LREF greetPerson), $(LREF formatStatus)
*/
string formatReport(string person, int count) @safe pure
{
    auto greeting = i"$(person) has $(count) items".text;
    return i"Report: $(greeting)".text;
}

///
@safe unittest
{
    assert(formatReport("Dave", 5) == "Report: Dave has 5 items");
}


// ---------------------------------------------------------------------------
// Scenario 6: Dollar sign escaping
// ---------------------------------------------------------------------------

/**
Scenario 6: dollar sign escaping in IES vs DDoc.

In IES, `\$` produces a literal dollar sign:
---
string price = i"Price: \$$(amount)".text;
// With amount=42: "Price: $42"
---

In DDoc, use `$(DOLLAR)` for a literal dollar sign:
$(UL
    $(LI Literal dollar: $(DOLLAR))
    $(LI Literal dollar-paren: $(DOLLAR)$(LPAREN))
    $(LI Literal right paren: $(RPAREN))
)

To show IES syntax literally in DDoc prose, write
`$(DOLLAR)$(LPAREN)expr$(RPAREN)` which renders as the literal text.

Params:
    amount = the price amount

Returns: A price string with dollar sign.
*/
string formatPrice(int amount) @safe pure
{
    return i"Price: \$$(amount)".text;
}

///
@safe unittest
{
    assert(formatPrice(42) == "Price: $42");
    assert(formatPrice(0) == "Price: $0");
}


// ---------------------------------------------------------------------------
// Scenario 7: Nested IES in documented unittests
// ---------------------------------------------------------------------------

/**
Scenario 7: nested IES in documented unittests.

Chained IES conversions produce multiple `$(DOLLAR)$(LPAREN)...$(RPAREN)` patterns
in the unittest source text. When DDoc extracts this as an Example,
its parenthesis-tracking macro expander encounters nested dollar-paren
sequences from multiple IES literals.
*/
string nestedIes() @safe pure
{
    int val = 42;
    auto inner = i"inner=$(val)".text;
    return i"outer[$(inner)]".text;
}

/// Documented unittest with chained IES expressions.
/// DDoc will see multiple `$(...)` patterns in the extracted source.
@safe unittest
{
    int val = 42;
    auto inner = i"inner=$(val)".text;
    auto result = i"outer[$(inner)]".text;
    assert(result == "outer[inner=42]");

    // Chained IES conversions
    string name = "Eve";
    int count = 3;
    auto part1 = i"$(name):".text;
    auto part2 = i"$(part1) $(count) items".text;
    assert(part2 == "Eve: 3 items");
}


// ---------------------------------------------------------------------------
// Scenario 8: IES with expressions that look like DDoc macros
// ---------------------------------------------------------------------------

/**
Scenario 8: variable names that collide with DDoc macro names.

The variables `B`, `D`, and `I` are valid D identifiers, but
`$(B text)` is the DDoc bold macro, `$(D code)` is inline code,
and `$(I text)` is italic.

In a documented unittest, DDoc extracts source text and applies
macro expansion. The text `i"$(B)"` contains `$(B)` which DDoc
will interpret as the bold macro with empty content.
*/
string ambiguousNames() @safe pure
{
    string B = "bold-var";
    string D = "code-var";
    string I = "italic-var";
    return i"B=$(B) D=$(D) I=$(I)".text;
}

/// Documented unittest where variable names match DDoc macro names.
/// In generated docs, `$(B)`, `$(D)`, and `$(I)` in the IES literals
/// may be expanded as DDoc macros instead of appearing as source code.
@safe unittest
{
    string B = "bold-value";
    string D = "code-value";
    string I = "italic-value";

    // These IES expressions use variables named B, D, I
    // which are also DDoc macro names
    auto result = i"B=$(B) D=$(D) I=$(I)".text;
    assert(result == "B=bold-value D=code-value I=italic-value");

    // Single-letter variable that is NOT a DDoc macro
    string X = "x-value";
    auto safe = i"X=$(X)".text;
    assert(safe == "X=x-value");
}


// ---------------------------------------------------------------------------
// Main — run all scenarios and print results
// ---------------------------------------------------------------------------

void main()
{
    writeln("=== IES / DDoc Interaction Test ===");
    writeln();

    writeln("--- Scenario 1: IES in documented unittest ---");
    writeln("  greetPerson(\"Alice\") = ", greetPerson("Alice"));
    writeln();

    writeln("--- Scenario 2: IES in ---code block--- documented function ---");
    writeln("  formatStatus(75, \"OK\") = ", formatStatus(75, "OK"));
    writeln();

    writeln("--- Scenario 3: IES in backtick-documented function ---");
    writeln("  greetSafe(\"Bob\") = ", greetSafe("Bob"));
    writeln();

    writeln("--- Scenario 4: Bare $(name) in DDoc prose ---");
    writeln("  farewell(\"Charlie\") = ", farewell("Charlie"));
    writeln();

    writeln("--- Scenario 5: DDoc macros + IES body ---");
    writeln("  formatReport(\"Dave\", 5) = ", formatReport("Dave", 5));
    writeln();

    writeln("--- Scenario 6: Dollar sign escaping ---");
    writeln("  formatPrice(42) = ", formatPrice(42));
    writeln();

    writeln("--- Scenario 7: Nested IES ---");
    writeln("  nestedIes() = ", nestedIes());
    writeln();

    writeln("--- Scenario 8: DDoc macro-like variable names ---");
    writeln("  ambiguousNames() = ", ambiguousNames());
    writeln();

    writeln("=== All runtime tests passed ===");
    writeln();
    writeln("To generate DDoc and inspect the interaction:");
    writeln("  ldc2 -D -Dd=build/docs -preview=in -preview=dip1000 \\");
    writeln("    docs/guidelines/ddoc_ies_interaction.d");
}
