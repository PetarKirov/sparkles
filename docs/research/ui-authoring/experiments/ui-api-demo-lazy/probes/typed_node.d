// Probe: can a typed `Node!M` (M = the message type a subtree sends) make the
// missing-`mapMsg` check compile-time under lazy variadic children?
@safe pure nothrow @nogc:
struct Ui { int n; }
struct Node(M) { uint index; }
struct NoMsg {}
struct A {} struct B { A a; }

// (1) IFTI through a lazy variadic: is M inferred from the child expressions?
Node!M column1(M)(ref Ui ui, scope Node!M delegate() @safe pure nothrow @nogc[] children...) => Node!M(1);
Node!A sendsA(ref Ui ui) => Node!A(2);
Node!NoMsg label(ref Ui ui) => Node!NoMsg(3);
enum ifti = __traits(compiles, (ref Ui ui) => column1(ui, sendsA(ui)));
// (2) explicit M: the label (NoMsg) must convert to Node!A, but `alias this`
// cannot convert to *every* Node!M.
enum explicitMixed = __traits(compiles, (ref Ui ui) => column1!A(ui, sendsA(ui), label(ui)));
// (3) the lift: mapMsg!fn takes Node!From, returns Node!To.
Node!B mapMsg(alias fn)(ref Ui ui, scope Node!A delegate() @safe pure nothrow @nogc[] c...) => Node!B(4);
enum liftOk = __traits(compiles, (ref Ui ui) => column1!B(ui, mapMsg!((A a) => B(a))(ui, sendsA(ui))));
enum missingRejected = !__traits(compiles, (ref Ui ui) => column1!B(ui, sendsA(ui)));
pragma(msg, "IFTI infers M through a lazy variadic: ", ifti);
pragma(msg, "explicit M accepts a NoMsg label next to an A sender: ", explicitMixed);
pragma(msg, "explicit M, lifted pane accepted: ", liftOk, ", unlifted pane rejected: ", missingRejected);
