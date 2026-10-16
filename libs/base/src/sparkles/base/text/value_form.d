/++
Value forms of writers. A writer `writeX(ref W w, args)` writes into an output
range; its value form `x(args)` is that output as a value (`formatted!writeX(args)`
from $(MREF sparkles,base,text,writers)), rendered when something consumes it.

This module depends on nothing in `sparkles`, so mixing a value form into a
module adds no imports to it: the generated function names the writers module
only in its body, which is compiled when a value form is used.
+/
module sparkles.base.text.value_form;

/**
The declaration of `name`, the $(I value form) of the writer `writer`: called
without a writer, `name(args)` is `formatted!writer(args)`, the writer's
output as a value. Mix it in at module scope, beside the writer:

---
mixin(valueForm!("writeDuration", "duration")); // writeln(duration(d))
mixin(valueForm!"drawTable");                  // the writer's own name
---

With the writer's own name, the value form overloads the writer: it applies
unless the first argument is an output range of `char` other than text (a
mutable `char[]` is one, but as a first argument it is content), so
`drawTable(w, cells)` still writes and `drawTable(cells)` is the value. The
constraint reaches only Phobos, so a module that mixes this in does not
import the writers module until a value form is used.
*/
enum string valueForm(string writer, string name = writer) =
    "auto " ~ name ~ "(Args...)(Args args)\n"
    ~ "if (!(Args.length && imported!\"std.range.primitives\".isOutputRange!(Args[0], char)\n"
    ~ "    && !is(Args[0] : const(char)[])))\n"
    ~ "    => imported!\"sparkles.base.text.writers\".formatted!(" ~ writer ~ ")(args);\n";

/**
Whether `T` writes itself: it has a `toString(Writer)` taking a sink, as every
value form does (and `prettyPrint(x)`). A component that takes text can take
such a value too, rendering it where it would read the text.
*/
enum bool isWritableValue(T) = is(T == struct) && __traits(compiles, (const T t) {
    scope void delegate(const(char)[]) @safe sink;
    t.toString(sink);
});

///
@("valueForm.isWritableValue")
@safe pure nothrow @nogc
unittest
{
    static struct Text
    {
        void toString(W)(ref W w) const { w("x"); }
    }
    static assert(isWritableValue!Text);
    static assert(!isWritableValue!string && !isWritableValue!int);
}
