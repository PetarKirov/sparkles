#!/usr/bin/env dub
/+ dub.sdl:
    name "prettyprint"
    dependency "sparkles:core-cli" version="*"
+/

import std.stdio : writeln;
import std.typecons : Tuple, tuple;

import sparkles.core_cli.prettyprint : prettyPrint, PrettyPrintOptions;

// Custom enum
enum Status { pending, running, completed, failed }

// Simple struct
struct Point { int x; int y; }

// Nested struct
struct Person {
    string name;
    int age;
    Point location;
}

// Recursive struct (linked list)
struct Node {
    int value;
    Node* next;
}

// Complex struct with many field types
struct ComplexData {
    // Primitives
    bool active;
    byte b;
    int count;
    long bigNum;
    float ratio;
    double precise;

    // Characters and strings
    char initial;
    string name;
    wstring wideName;

    // Enum
    Status status;

    // Arrays
    int[] numbers;
    int[3] fixedNumbers;

    // Associative array
    string[int] lookup;

    // Nested struct
    Person owner;

    // Pointer
    int* refCount;

    // Tuple
    Tuple!(int, string, bool) metadata;
}

// Simple class
class Animal {
    string species;
    int legs;
}

void main() {
    writeln("═══════════════════════════════════════════════════════════════════");
    writeln("                    prettyPrint Demo - All Types                    ");
    writeln("═══════════════════════════════════════════════════════════════════\n");

    // 1. Null
    writeln("── null ──");
    writeln(prettyPrint(null));
    writeln();

    // 2. Booleans
    writeln("── bool ──");
    writeln(prettyPrint(true));
    writeln(prettyPrint(false));
    writeln();

    // 3. Integers
    writeln("── integers ──");
    writeln(prettyPrint(42));
    writeln(prettyPrint(-123L));
    writeln(prettyPrint(cast(ubyte)255));
    writeln();

    // 4. Floating point
    writeln("── floats ──");
    writeln(prettyPrint(3.14159));
    writeln(prettyPrint(double.nan));
    writeln(prettyPrint(double.infinity));
    writeln(prettyPrint(-double.infinity));
    writeln();

    // 5. Characters
    writeln("── chars ──");
    writeln(prettyPrint('A'));
    writeln(prettyPrint('\n'));
    writeln(prettyPrint('\t'));
    writeln(prettyPrint('\''));
    writeln();

    // 6. Strings
    writeln("── strings ──");
    writeln(prettyPrint("Hello, World!"));
    writeln(prettyPrint("Line1\nLine2\tTabbed"));
    writeln(prettyPrint("Quote: \"test\""));
    writeln();

    // 7. Enums
    writeln("── enum ──");
    writeln(prettyPrint(Status.running));
    writeln(prettyPrint(Status.failed));
    writeln();

    // 8. Arrays
    writeln("── arrays ──");
    int[] arr = [1, 2, 3, 4, 5];
    writeln(prettyPrint(arr));
    writeln();

    int[] empty;
    writeln(prettyPrint(empty));
    writeln();

    // 9. Static arrays
    writeln("── static array ──");
    int[4] staticArr = [10, 20, 30, 40];
    writeln(prettyPrint(staticArr));
    writeln();

    // 10. Associative arrays
    writeln("── associative array ──");
    string[int] aa = [1: "one", 2: "two", 3: "three"];
    writeln(prettyPrint(aa));
    writeln();

    // 11. Simple struct
    writeln("── struct ──");
    auto point = Point(10, 20);
    writeln(prettyPrint(point));
    writeln();

    // 12. Nested struct
    writeln("── nested struct ──");
    auto person = Person("Alice", 30, Point(100, 200));
    writeln(prettyPrint(person));
    writeln();

    // 13. Tuples
    writeln("── tuple (unnamed) ──");
    auto t1 = tuple(42, "hello", 3.14, true);
    writeln(prettyPrint(t1));
    writeln();

    writeln("── tuple (named) ──");
    auto t2 = Tuple!(int, "id", string, "name", bool, "active")(1, "test", true);
    writeln(prettyPrint(t2));
    writeln();

    // 14. Pointers
    writeln("── pointers ──");
    int* nullPtr = null;
    writeln(prettyPrint(nullPtr));

    int val = 42;
    int* ptr = &val;
    writeln(prettyPrint(ptr));
    writeln();

    // 15. Recursive struct (linked list)
    writeln("── recursive struct (linked list) ──");
    Node n3 = Node(3, null);
    Node n2 = Node(2, &n3);
    Node n1 = Node(1, &n2);
    writeln(prettyPrint(n1));
    writeln();

    // 16. Class
    writeln("── class ──");
    Animal nullAnimal = null;
    writeln(prettyPrint(nullAnimal));

    auto dog = new Animal();
    dog.species = "Canis familiaris";
    dog.legs = 4;
    writeln(prettyPrint(dog));
    writeln();

    // 17. Complex nested structure
    writeln("── complex nested structure ──");
    int refVal = 99;
    auto complex = ComplexData(
        active: true,
        b: -5,
        count: 42,
        bigNum: 9_876_543_210,
        ratio: 0.75f,
        precise: 3.141592653589793,
        initial: 'X',
        name: "Complex\nData",
        wideName: "Wide"w,
        status: Status.running,
        numbers: [1, 2, 3],
        fixedNumbers: [10, 20, 30],
        lookup: [1: "one", 2: "two"],
        owner: Person("Bob", 25, Point(50, 60)),
        refCount: &refVal,
        metadata: tuple(123, "meta", false)
    );
    writeln(prettyPrint(complex));
    writeln();

    // 18. maxItems demonstration
    writeln("── maxItems (limit: 3) ──");
    int[] bigArray = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
    writeln(prettyPrint(bigArray, PrettyPrintOptions(maxItems: 3)));
    writeln();

    // 19. maxDepth demonstration
    writeln("── maxDepth (limit: 2) ──");
    writeln(prettyPrint(complex, PrettyPrintOptions(maxDepth: 2)));
    writeln();

    // 20. Without colors
    writeln("── without colors ──");
    writeln(prettyPrint(person, PrettyPrintOptions(useColors: false)));
    writeln();

    // ─────────────────────────────────────────────────────────────────────────
    // softMaxWidth demonstrations
    // ─────────────────────────────────────────────────────────────────────────

    writeln("═══════════════════════════════════════════════════════════════════");
    writeln("                   softMaxWidth Demonstrations                      ");
    writeln("═══════════════════════════════════════════════════════════════════\n");

    // 21. softMaxWidth comparison - same struct, different widths
    writeln("── softMaxWidth: default (80) - fits on one line ──");
    writeln(prettyPrint(point));
    writeln();

    writeln("── softMaxWidth: 15 - too narrow, uses multi-line ──");
    writeln(prettyPrint(point, PrettyPrintOptions(softMaxWidth: 15)));
    writeln();

    writeln("── softMaxWidth: 0 - always multi-line ──");
    writeln(prettyPrint(point, PrettyPrintOptions(softMaxWidth: 0)));
    writeln();

    // 22. Array width comparison
    writeln("── array with softMaxWidth: default (80) ──");
    int[] mediumArr = [100, 200, 300, 400, 500];
    writeln(prettyPrint(mediumArr));
    writeln();

    writeln("── array with softMaxWidth: 20 ──");
    writeln(prettyPrint(mediumArr, PrettyPrintOptions(softMaxWidth: 20)));
    writeln();

    // 23. Nested struct width comparison
    writeln("── nested struct with softMaxWidth: default (80) ──");
    writeln(prettyPrint(person));
    writeln();

    writeln("── nested struct with softMaxWidth: 40 ──");
    writeln(prettyPrint(person, PrettyPrintOptions(softMaxWidth: 40)));
    writeln();

    writeln("── nested struct with softMaxWidth: 0 ──");
    writeln(prettyPrint(person, PrettyPrintOptions(softMaxWidth: 0)));
    writeln();

    // 24. Associative array width comparison
    writeln("── AA with softMaxWidth: default (80) ──");
    writeln(prettyPrint(aa));
    writeln();

    writeln("── AA with softMaxWidth: 25 ──");
    writeln(prettyPrint(aa, PrettyPrintOptions(softMaxWidth: 25)));
    writeln();

    // 25. Complex struct - shows how nested values can be inline even when parent is multi-line
    writeln("── complex struct (default) - parent multi-line, nested values inline ──");
    writeln(prettyPrint(complex));
    writeln();

    writeln("── complex struct with softMaxWidth: 0 - everything multi-line ──");
    writeln(prettyPrint(complex, PrettyPrintOptions(softMaxWidth: 0)));
    writeln();

    // 26. Linked list width comparison
    writeln("── linked list with softMaxWidth: default (80) ──");
    writeln(prettyPrint(n1));
    writeln();

    writeln("── linked list with softMaxWidth: 30 ──");
    writeln(prettyPrint(n1, PrettyPrintOptions(softMaxWidth: 30)));
    writeln();

    writeln("═══════════════════════════════════════════════════════════════════");
    writeln("                           Demo Complete                            ");
    writeln("═══════════════════════════════════════════════════════════════════");
}
