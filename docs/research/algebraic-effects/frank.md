# Frank

A strict functional programming language with a bidirectional effect type system, multihandlers, and ambient abilities, designed from the ground up around algebraic effect handlers.

| Field         | Value                                                                                                                                                                                                            |
| ------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Language      | Frank                                                                                                                                                                                                            |
| License       | GPL-3.0                                                                                                                                                                                                          |
| Repository    | [github.com/frank-lang/frank](https://github.com/frank-lang/frank)                                                                                                                                               |
| Documentation | [arXiv paper](https://arxiv.org/abs/1611.09259) / [JFP extended version](https://www.cambridge.org/core/journals/journal-of-functional-programming/article/doo-bee-doo-bee-doo/DEC5F8FDABF7DE3088270E07392320DD) |
| Key Authors   | Conor McBride, Sam Lindley, Craig McLaughlin                                                                                                                                                                     |
| Encoding      | Multihandlers with ambient ability propagation over a call-by-push-value foundation                                                                                                                              |

---

## Overview

### What It Solves

Traditional effect handler systems treat handlers as a separate construct from functions, and effect types accumulate outward from sub-expressions. This creates syntactic overhead (explicit handler wrapping, monadic do-notation) and conceptual friction between pure functions and effectful computations. Frank eliminates this gap by generalizing function abstraction itself: a function is simply a handler that interprets no commands. There is no separate handler construct, no monadic notation, and no explicit effect variables in source code.

### Design Philosophy

Frank follows a "do be do be do" philosophy -- computations alternate between _doing_ (performing effects) and _being_ (returning values). This is formalized through a call-by-push-value (CBPV) foundation where values _are_ and computations _do_. The language is strict (call-by-value for arguments), but suspended computations are explicit and distinct from values, enabling controlled laziness.

Effect polymorphism is handled through _ambient ability_ propagation: rather than each sub-expression declaring its own effect set that must be unified outward, the environment declares what effects are available, and this ambient ability propagates inward. Effect variables never appear in Frank source code -- polymorphism is entirely implicit.

The paper describing Frank is titled "Do Be Do Be Do" (Lindley, McBride, McLaughlin, POPL 2017), with an extended version "Doo Bee Doo Bee Doo" published in the Journal of Functional Programming (2020, with Lukas Convent as additional author).

---

## Core Abstractions and Types

### Value Types vs Computation Types

Frank distinguishes values from computations following Levy's call-by-push-value:

```frank
-- Value types: data that "is"
data Bool = tt | ff
data List X = nil | X :: (List X)
data Pair X Y = pair X Y

-- Computation types: processes that "do"
-- {[E1, E2, ...] T} is a suspended computation
-- that may perform effects E1, E2, ... and returns T
```

A value of type `{[E] T}` is not a `T` -- it is the _ability to compute_ a `T` while potentially performing effects in `E`. The `!` operator forces a suspended computation:

```frank
-- f! forces the thunk f
-- f x is sugar for f! x when f is a suspended function
```

### Interfaces (Effect Signatures)

Interfaces declare the commands an effect provides:

```frank
interface Send X = send : X -> Unit
interface Receive X = receive : X
interface Abort = aborting : Zero
interface State S = get : S
                  | put : S -> Unit
interface Console = inch : Char
                  | ouch : Char -> Unit
```

Each command signature specifies argument types and a return type. The return type is what the handler must supply to the continuation when it intercepts the command.

### Operators and Handlers

In Frank, every function is an _operator_. An operator that handles no effects is an ordinary function. An operator that handles effects from one or more computation arguments is a _handler_ (or _multihandler_):

```frank
-- An ordinary function (no effects handled)
not : Bool -> Bool
not tt = ff
not ff = tt

-- A unary handler: handles State commands
state : S -> <State S>X -> X
state _ x             = x
state s <get -> k>    = state s (k s)
state s <put s' -> k> = state s' (k unit)
```

---

## How Effects Are Declared

### Interface Declarations

Effects are declared as interfaces at the top level. An interface specifies a collection of _commands_ with their signatures:

```frank
interface Send X = send : X -> Unit
interface Receive X = receive : X
```

Here `Send X` provides a single command `send` that takes a value of type `X` and returns `Unit`. `Receive X` provides `receive` which takes no arguments and returns an `X`.

### Ambient Ability

The key innovation is that effects are tracked via the _ambient ability_ -- the set of effects currently available in the typing context. When a computation type is written as `[E1, E2]T`, the effects `E1` and `E2` are what the computation is _allowed_ to perform. The ambient ability propagates inward through the typing rules:

```frank
-- [Console]Unit means: may use Console commands, returns Unit
-- [0]T means: may use the ambient ability (implicit polymorphism)
-- []T means: pure, no effects allowed

map : {X -> [0]Y} -> List X -> [0]List Y
map f nil        = nil
map f (x :: xs)  = f x :: map f xs
```

The `[0]` annotation means "whatever the ambient ability is." This is Frank's effect polymorphism -- `map` works with any effects because it inherits the ambient ability implicitly. There are no named effect variables.

### Computation Types in Signatures

Function arguments that are computations (thunks) carry their own ability annotations:

```frank
-- A function taking a computation that may use Console
withConsole : {[Console]Unit} -> [IO]Unit
```

---

## How Handlers/Interpreters Work

### Unary Handlers

A handler interprets commands from a computation argument by pattern matching on command requests and their continuations:

```frank
state : S -> <State S>X -> X
state _ x             = x           -- pure return: just give back x
state s <get -> k>    = state s (k s)     -- resume with current state
state s <put s' -> k> = state s' (k unit) -- update state, resume
```

The pattern `<get -> k>` matches a `get` command, binding the continuation to `k`. Calling `k s` resumes the computation with value `s` as the result of `get`.

### Multihandlers

Multihandlers are Frank's distinctive feature. They take multiple computation arguments and can simultaneously interpret commands from several sources:

```frank
pipe : <Send X>Unit -> <Receive X>Y -> [Abort]Y
pipe <send x -> s> <receive -> r> = pipe (s unit) (r x)
pipe <send _ -> _> y              = y
pipe unit          y              = y
pipe _             <receive -> _> = aborting!
```

This `pipe` operator connects a producer (performing `Send X`) with a consumer (performing `Receive X`). When the producer sends a value and the consumer requests one, the handler feeds the sent value to the consumer's continuation and resumes both. This is the canonical example showing how multihandlers enable concurrent-style composition without threads or channels.

### Using Handlers

```frank
-- Define a producer and consumer
sends : List X -> [Send X]Unit
sends nil        = unit
sends (x :: xs)  = send x; sends xs

catter : [Receive (List Char)]List (List Char)
catter = case receive! of
           nil -> nil
           xs  -> xs :: catter!

-- Compose with pipe
main : [Abort]List (List Char)
main = pipe (sends ["do", "be", "do"]!) catter!
```

---

## Performance Approach

Frank is primarily a research language, and its implementation prioritizes clarity of semantics over raw performance. The compiler (written in Haskell) compiles Frank to an intermediate language called Shonky, which is then interpreted.

Key characteristics of the current implementation:

- **Interpreted execution**: Frank programs compile to Shonky code and are interpreted, not compiled to native code
- **Continuation-based handlers**: Effect handling uses first-class continuations, which incur allocation overhead per command invocation
- **No optimization passes**: The compiler performs type checking and desugaring but does not apply significant optimizations
- **Research focus**: Performance work has not been a priority; the implementation serves as a proof of concept for the type system and semantics described in the paper

The formal semantics (Core Frank) uses a small-step operational semantics with evaluation contexts, providing a clear theoretical foundation even if runtime performance is modest.

---

## Composability Model

### Effect Composition via Ambient Ability

Multiple effects compose naturally through the ambient ability. A computation that needs both `State` and `Console` simply lists both in its type:

```frank
interactive : [State Int, Console]Unit
interactive = ouch (intToChar (get!)); put (get! + 1)
```

### Multihandler Composition

Multihandlers enable composition patterns that are difficult or impossible with unary handlers. The `pipe` example composes a producer and consumer, but the pattern extends to any number of interacting computations:

```frank
-- A spacer that intercepts strings and adds spaces
spacer : <Receive (List Char)>(List Char) ->
         [Send (List Char)]Unit
spacer <receive -> r> = send " "; send (r!)
spacer x              = send x

-- Compose three stages
main : [Abort]List (List Char)
main = pipe (sends ["do","be","do"]!)
            (pipe spacer! catter!)
```

### Adaptors and Effect Encapsulation

Frank introduces _adaptors_ (also called _adjustments_) to manage effect routing. An adaptor remaps the ambient ability for a sub-computation, enabling:

- **Effect masking**: hiding an effect from a sub-computation
- **Effect reordering**: changing which handler catches which command
- **Effect encapsulation**: preventing internal effects from polluting external interfaces

Adaptors are essential for building reusable components. Without them, composing handlers from smaller pieces can cause "effect pollution" where internal implementation effects leak into the public type signature.

---

## Strengths

- **Multihandlers** are a unique and powerful abstraction that enables simultaneous interpretation of commands from multiple sources, supporting patterns like pipes, concurrent interleavings, and actor-style communication
- **Invisible effect polymorphism** eliminates effect variable clutter from source code; the ambient ability propagation is elegant and reduces annotation burden
- **No separate handler syntax** -- functions and handlers share the same mechanism, reducing conceptual overhead
- **No monadic notation needed** -- effects are implicit in the type, so programs read as direct-style code
- **Formal foundations** are thoroughly developed with a sound small-step operational semantics for Core Frank
- **Influenced Unison** -- Frank's ambient ability system directly inspired Unison's abilities, demonstrating practical impact

## Weaknesses

- **Research prototype** -- the implementation is not production-ready; it compiles to an interpreted intermediate language
- **Small ecosystem** -- limited libraries, tooling, and community compared to established languages
- **Limited documentation** -- beyond the academic papers and example files, learning resources are sparse
- **No coverage checking** -- pattern match coverage is not verified by the compiler
- **Performance** is not competitive with production effect systems; no native code generation
- **Adaptor system complexity** -- while powerful, adaptors add conceptual overhead to an already novel type system

## Key Design Decisions and Trade-offs

| Decision                               | Rationale                                                                                        | Trade-off                                                                                           |
| -------------------------------------- | ------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------- |
| Multihandlers over unary handlers      | Enable simultaneous interpretation of multiple effect sources; subsume functions as special case | More complex typing rules; harder to implement efficiently                                          |
| Ambient ability (inward propagation)   | Eliminates effect variables from source; cleaner user-facing types                               | Less explicit than outward accumulation; harder to reason about which handler catches which command |
| Call-by-push-value foundation          | Clean separation of values and computations; principled treatment of laziness                    | Unfamiliar to most programmers; adds conceptual overhead                                            |
| No monadic notation                    | Direct-style programming; lower syntactic barrier                                                | Cannot express monadic patterns from Haskell ecosystem directly                                     |
| Adaptors for effect encapsulation      | Prevents effect pollution; enables modular composition                                           | Additional mechanism to learn; partial operation (can fail at type level)                           |
| Strict evaluation with explicit thunks | Predictable performance; explicit suspension                                                     | Requires `!` for forcing; more verbose than lazy languages for some patterns                        |

---

## Sources

- [Do Be Do Be Do (POPL 2017)](https://dl.acm.org/doi/10.1145/3009837.3009897)
- [Do Be Do Be Do -- arXiv preprint](https://arxiv.org/abs/1611.09259)
- [Doo Bee Doo Bee Doo (JFP 2020, extended version)](https://www.cambridge.org/core/journals/journal-of-functional-programming/article/doo-bee-doo-bee-doo/DEC5F8FDABF7DE3088270E07392320DD)
- [Frank compiler on GitHub](https://github.com/frank-lang/frank)
- [The Frank Manual (McBride, 2012)](https://personal.cis.strath.ac.uk/conor.mcbride/pub/Frank/TFM.pdf)
- [Encapsulating Effects in Frank (draft, 2018)](https://homepages.inf.ed.ac.uk/slindley/papers/leak-draft-november2018.pdf)
- [Sam Lindley's publications](https://homepages.inf.ed.ac.uk/slindley/)
- [Lambda the Ultimate discussion](http://lambda-the-ultimate.org/node/5401)
