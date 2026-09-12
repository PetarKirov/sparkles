# Effect handlers and record/replay

Does the algebraic-effects literature contain a "durable" or "replaying" handler, one that records the answers to operations on a first run and answers from that record on a later run? The short answer: the _mechanism_ is well known and appears under several names (a trace handler paired with a replay handler in probabilistic programming, replay-based delimited control, log-and-replay of an operational-monad program), but no paper in the effect-handlers literature defines a durable, crash-resumable handler with a correctness theorem. The one formal result with the right shape, an idempotence monad that logs each effectful step under a unique identifier and proves failure-freedom, predates the handler vocabulary and is written in monads.

| Field             | Value                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Principal sources | Pyro's `poutine` (trace/replay handlers) · Nguyen, Perera, Wang, Wu, "Modular Probabilistic Models via Algebraic Effects" · Koppel, Scherer, Solar-Lezama, "Capturing the Future by Replaying the Past" · Ramalingam, Vaswani, "Fault Tolerance via Idempotence" · Apfelmus, `operational` web-session example · Ahman, Bauer, "Runners in action" · `ocaml-multicore/dscheck` · Unison's `Remote.pure.run` · Wu, Schrijvers, Hinze, "Effect Handlers in Scope" · the `yallop/effects-bibliography` index · Burckhardt et al.'s related-work section |
| Venue / year      | Pyro (Uber AI Labs, 2018; source read at `45341b1ba77d0f0d6de1999b8bd2d305ef4ec190`) · ICFP 2022 · ICFP 2018 · POPL 2013 · `operational` (Hackage; read at `597a561d07c77e32068eef2129982068ac8cceba`) · ESOP 2020 · dscheck read at `45406eca007f391dc9764b949f23b0cfed343a9b` · Unison blog March 7, 2023 · Haskell 2014 · bibliography read at `08d791bf9bcf20164aa5919e97272df147d9f1ed` · OOPSLA 2021                                                                                                                                           |
| DOI or URL        | [Pyro docs][pyro-docs] · [`10.1145/3547635`][nguyen-doi] · [`10.1145/3236771`][thermo-doi] · [`10.1145/2429069.2429100`][idem-doi] · [`WebSessionState.lhs`][operational-web] · [arXiv `1910.11629`][runners-arxiv] · [`dscheck`][dscheck] · [Visualizing remote computations][unison-blog] · [`10.1145/2633357.2633358`][scope-doi] · [effects-bibliography][effbib] · [`10.1145/3485510`][df-doi]                                                                                                                                                  |
| Category          | theory                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               |
| Grounds           | 1 (step identity: the addressing problem is the same one PPL traces solve), 3 (determinism: replay is only sound for a computation whose only effects go through the handler), 4 (compensation: the idempotence monad's compensation extension and scoped `catch`), 8 (testing: a scheduler handler that enumerates interleavings). Touches 6 and 7. Silent on 2 and 5.                                                                                                                                                                              |

**Last reviewed:** September 12, 2026.

No clone of Pyro, dscheck, `operational` or the effects bibliography exists under `$REPOS`; those citations are pinned GitHub blobs read through the GitHub API. The Unison checkout at `$REPOS/unison/unison` is at `0452fcab2635cdbf0d1f717812a1168d300ebbcb`. The sibling page [Burckhardt et al.][burckhardt] covers the only formal replay result in full; this page cites its lemmas but does not restate the model.

## What it establishes

Searching for "record and replay" against the effect-handlers literature turns up one exact match and several near misses. The exact match is not a paper but a library: Pyro's `poutine`, which its own documentation introduces as "a library of composable effect handlers for recording and modifying the behavior of Pyro programs" ([`docs/source/poutine.rst`][pyro-rst]), and which ships a `trace` handler that records every operation's inputs and outputs and a `replay` handler that answers a later run's operations from that record. The academic version of the same idea, in Haskell with algebraic effects, is Nguyen et al.'s `traceSamples` handler and the address-keyed `STrace` map it maintains. Both exist to make a stochastic program re-executable under a chosen set of answers, which is exactly what a durable workflow needs, but neither paper says anything about persistence, crashes or resumption.

The `yallop/effects-bibliography` index, the community's canonical list, has no entry mentioning replay, record, durable, checkpoint or journal; its only entries near the topic are the probabilistic-programming ones (Nguyen et al. 2022, Pyro 2018, Moore and Gorinova's Edward2 paper) ([README at `08d791bf`][effbib-readme]). Burckhardt et al.'s related-work section, written by people who built the record/replay runtime, cites no effect-handler or continuation work at all; its closest citations are a serverless runtime that instruments storage accesses "to enable record/replay" and Ramalingam and Vaswani's λFAIL, which "proposes a semantics for distributed services that execute on top of reliable storage, also providing a compilation procedure using monads that guarantees correct execution in the presence of faults" ([paper][df-pdf], §7). That last citation is the closest thing to the sparkles design with a proof attached, and it is a monad, not a handler.

## Pyro `poutine`: the `trace` / `replay` pair

Pyro's inference layer is a stack of `Messenger` objects that intercept `pyro.sample` and `pyro.param` calls; the documentation points readers at Pretnar's handlers tutorial to explain the design ([`poutine.rst`][pyro-rst]). Two handlers matter here. `TraceMessenger` is documented as "Return a handler that records the inputs and outputs of primitive calls and their dependencies" ([`trace_messenger.py`][pyro-trace]). `ReplayMessenger` is the other half ([`replay_messenger.py`][pyro-replay]):

> "Given a callable that contains Pyro primitive calls, return a callable that runs the original, reusing the values at sites in trace at those sites in the new trace … `replay` makes `sample` statements behave as if they had sampled the values at the corresponding sites in the trace"

The mechanics are small enough to quote in full. A sample site is matched by its name; a site not in the trace falls through to the live behaviour; a site whose recorded kind does not match is an error:

```python
def _pyro_sample(self, msg: "Message") -> None:
    assert msg["name"] is not None
    name = msg["name"]
    if self.trace is not None and name in self.trace:
        guide_msg = self.trace.nodes[name]
        if msg["is_observed"]:
            return None
        if guide_msg["type"] != "sample" or guide_msg["is_observed"]:
            raise RuntimeError("site {} must be sampled in trace".format(name))
        msg["done"] = True
        msg["value"] = guide_msg["value"]
```

What this establishes: a record/replay pair is expressible as two ordinary handlers over one effect, with the recorded trace as the state of the first and the input of the second; step identity is a user-supplied site name; a replayed site is marked `done` so inner handlers do not re-run it (the "suppress the effect" half of Burckhardt's rule YOut); and mismatch detection is limited to kind, not arguments. Nothing is persisted; a `Trace` is an in-memory graph, and the point of replaying it is to compute a density, not to survive a crash.

## Nguyen, Perera, Wang, Wu (ICFP 2022) and the programmable-inference sequel

The Haskell treatment makes the handler structure explicit. Every runtime `Sample` occurrence gets "a unique dynamic address α", the trace is "a map from addresses α to values", and tracing is "a handler that installs a runtime `State STrace` effect after each `Sample` operation" ([paper][nguyen-pdf], §6.1):

```haskell
type STrace = Map Addr PrimVal

traceSamples :: (Member Sample es, Member (State STrace) es) => Prog es a -> Prog es a
traceSamples (Op op k) = case prj op of
    Just (Sample d α) -> Op op (λx -> do call (Modify (Map.insert α x))
                                       traceSamples (k x))
    Nothing           -> Op op (traceSamples . k)
```

The replay half is stated for Metropolis–Hastings: a proposal address "denotes the address from which a new sample is to be drawn, where all other addresses are to instead reuse old samples from previous iterations" (§6.2.2). The 2024 sequel makes the determinism claim explicit: "The `Sample` handler `reuseTrace τ` is used for executing a model under a trace τ: it generates the draw using the stored random value for α if there is one", and "Since `draw` is pure, executing a model under a fixed (and sufficiently large) trace is deterministic, allowing the generative behaviour of the model to be controlled by providing it a specific trace" ([Effect Handlers for Programmable Inference][nguyen-inference]).

That is the record/replay handler named precisely: a state effect over a log, keyed by address, with a reuse handler that answers from the log and falls back to the live operation on a miss. The paper attributes the addressing scheme to the PPL literature (Wingate et al. 2011 via Tolpin et al. 2016), not to effects research; the effect-handlers contribution is that tracing and reuse become composable program transformations. There is no correctness theorem about replay; the property is stated informally and depends on `draw` being pure.

## Koppel, Scherer, Solar-Lezama: replay-based delimited control (ICFP 2018)

The one paper whose _whole subject_ is replaying an effectful computation from a recording. Thermometer continuations implement `shift`/`reset` without runtime support by re-running the computation from the start under a record ([paper][thermo-pdf], §1):

> "Thermometer continuations hence record the result of all effectful function calls so that they may be replayed in the next execution: the past of one invocation becomes the future of the next."

and, immediately after, the constraint every replay scheme lives under:

> "This approach poses an obvious limitation: the replayed computation can't have any side effects, except for thermometer continuations."

The paper proves correctness for the nondeterminism special case (Appendix A) and shows via Filinski's construction that the technique generalises "to any monadic effect" (§3). What it establishes for this catalog: replay of a recorded prefix is a legitimate implementation of continuation capture, so a runtime with no continuation capture at all, which is what `sparkles:event-horizon` deliberately is, loses nothing in expressive power if it can replay. It also states the cost honestly: "replays are inefficient", mitigated by memoisation.

## Ramalingam and Vaswani: the idempotence monad (POPL 2013)

The closest formal result to a journaling combinator, and the one Burckhardt et al. cite. The setting is λFAIL, a lambda calculus with process failure, duplicate requests, a `RETRY` rule and single-store atomic transactions. Correctness is _failfree idempotence_: a program is correct iff its behaviour under the standard semantics (with failures and duplicates) is weakly bisimilar to its behaviour under an ideal semantics with neither (Definition 2.3). The authors' gloss: "if the system can produce a response r under the ideal semantics, then the system should be capable of producing the same response r under the standard semantics also … this progress guarantee holds provided requests are retried" ([paper][idem-pdf], §2.2).

The construction is a monad that does what the sparkles design does ([paper][idem-pdf], §1):

> "Given a unique identifier associated with a computation, the monad essentially adds logging and checking to each effectful step in the workflow to ensure idempotance. … it does not assume the presence of dedicated storage for logs that can be accessed atomically with each transaction. The monad reuses the underlying store (in this case a key-value table) to simulate a distinct address space for logging."

Step identity is a pair: a per-computation `guid` plus a step counter `tc` threaded through the monad and incremented at every atomic step (§3.1). The whole of `imatomic` is a memo lookup keyed by that pair:

```ocaml
let imatomic T f =
  fun (guid, tc) ->
    atomic T {
      let key = (0, (guid, tc)) in
      match lookup key with
      | Some(v) -> (v, tc+1)
      | None    -> let v = f () in (update key v); (v, tc+1)
    }
```

The results: Theorem 3.4, every well-typed program in the monad is observationally idempotent; Theorem 3.7, such a program is failfree; Theorem 3.9, the monadic translation of any λFAIL program is a failfree realisation of it. Section 4.1 extends the calculus (λIDWF) with `atomic t ea ec`, where `ec` is the compensation for `ea`, and an `abort` that runs accumulated compensations in reverse; the compensation monad is "a combination" of the idempotence monad and continuation-passing style, with `compensateWith` binding a transaction to its compensation (§4.1). The implementation is F# and C# on Windows Azure.

What it establishes: a log keyed by (computation id, step counter), checked before every effectful step, is _sufficient_ for exactly-once-modulo-retries, with the proof in hand. What it lacks: the log lives inside the same atomic store as the effects (the trick that makes the proof work), so it says nothing about effects on a world outside that store, which is every effect `release` performs; and the step counter is positional, so a code change that inserts a step silently re-keys everything after it.

## Apfelmus's `operational`: replaying a logged session

The oldest free-monad instance of the pattern, written as a worked example rather than a paper. A web session monad with one instruction, `Ask :: String -> WebI String`, is run as a CGI script that has no state between requests ([`WebSessionState.lhs`][operational-web]):

> "How does this work? The trick is that all previous answers are logged in a hidden field of the input form. The CGI script will simply replays this log when called. In other words, the user state is stored in the input form."

```haskell
eval :: ProgramView WebI H.Html -> [String] -> [String] -> CGI H.Html
eval (Return html)         log _      = return html
eval (Ask question :>>= k) log (l:ls) = replay (k l) log ls   -- answer from log
eval (Ask question :>>= k) log []     = return $ htmlQuestion log question
```

This is a durable workflow in miniature: the program is re-run from the start on every request, positional matching against a log of answers, and the live operation fires exactly at the log's end. It also exhibits the two weaknesses the sparkles design must not repeat: identity is position only, and the log is the sole source of truth, with no notion of the world disagreeing with it.

## Ahman and Bauer: runners (ESOP 2020)

Not a replay result but the theory that names the sparkles capability row. A runner supplies, for each operation, a co-operation over a runtime state; it is "a restricted form of handlers, which apply the continuation at most once in a tail call position" ([paper][runners-pdf], §1), which is precisely the "every capability op is tail-resumptive, no continuation capture" discipline of `sparkles:event-horizon`. Runners "may use further external resources" and come with a finalisation construct: `using V @ W run M finally F`, with Theorem 7 (Finalisation) proving that a well-typed run factors through its finalisation clause, and "a strong guarantee that in the absence of external kill signals the finalisation code is executed exactly once" (§1). The paper proves nothing about logging, but it gives the design its correct name (a runner over a journal state) and its correct compensation vocabulary (finalisation that runs exactly once absent a kill).

## dscheck: a scheduler handler that enumerates interleavings

`ocaml-multicore/dscheck` is "an experimental model checker for testing concurrent programs" that "explores interleavings of a user-provided program and helps ensure that its invariants are maintained regardless of scheduling decisions" ([README][dscheck-readme]). The mechanism is OCaml 5 effects: every atomic operation is an effect, and a shallow handler owns the schedule ([`src/tracedAtomic.ml`][dscheck-src]):

```ocaml
open Effect
open Effect.Shallow

type _ Effect.t +=
  | Make : 'a -> 'a t Effect.t
  | Get : 'a t -> 'a Effect.t
  | Set : ('a t * 'a) -> unit Effect.t
  | Exchange : ('a t * 'a) -> 'a Effect.t
  | CompareAndSwap : ('a t * 'a * 'a) -> bool Effect.t
  | FetchAndAdd : (int t * int) -> int Effect.t
```

with `let get r = if !tracing then perform (Get r) else …`, so the same program runs natively when not under test. The search uses dynamic partial-order reduction ([Tarides, April 10, 2024][tarides-dscheck]). What it establishes: when the only nondeterminism is which effect the handler resumes next, the handler can enumerate or replay a chosen interleaving deterministically. This is the effect-handler form of deterministic simulation testing; see the sibling page [deterministic simulation testing][dst].

## Unison: `Remote.pure.run` and the `Durable` design

Unison Cloud's `Remote` ability is "the I/O of the Cloud … it's an ability which describes the runtime for a distributed system" ([Unison Cloud core concepts][unison-core]); durability is a separate `Storage` ability, "the general ability for interacting with durable storage". The local test handler is a serialising interpreter: "It works by serializing the events that occur during the computation and storing their order relative to one another in a local task queue", and the visualiser adds a second effect from inside the handler, "We decided to use the `Stream` ability to emit events as they occur, in effect, creating a log of the distributed computation" ([Rebecca Mark, March 7, 2023][unison-blog]). The older design RFC in the repository has a `Durable a` type with `Durable.store : ∀ a . a -> Remote (Durable a)` and an explicit note that "Unison can make any value durable. `Durable` values are immutable" ([`docs/distributed-programming-rfc.markdown`][unison-rfc]).

What this establishes: Unison's answer to durability is _serialisable continuations_, not replay. A computation is made durable by storing its captured state as a value, which its runtime can do because every value including a continuation is serialisable (see the parent-topic page [Unison][unison-page]). That is the snapshot branch of question 7, and it is unavailable to a D program with no continuation capture.

## Wu, Schrijvers, Hinze: scoped effects (Haskell 2014)

Relevant to compensation only. The paper's problem statement: algebraic handlers "do not support syntax for scoping constructs", and using a handler as the scope "constrains the possible interactions of effects and rules out some desired semantics" ([paper][scope-pdf], abstract). Its worked examples are exactly the scope-like operations a durable workflow needs: `catch` for exceptions, pruning nondeterministic choices, and multi-threading. The fix is to make the scope part of the syntax (a scoped operation carrying a sub-program) so handlers can be reordered without moving the scope boundary. What it establishes: a compensation scope (`withCompensation body`) is a scoped operation in this sense, not an algebraic one, and a journal that records it must record the scope boundary as data, not rely on handler nesting.

## Fecher: "Replayability" in the Ante design notes

An explicit, informal statement of the durable handler as a design idea, from a language designer's blog (May 21, 2025) ([Why Algebraic Effects?][ante]):

> "To implement this you would need two handlers: `record` and `replay` which handle the top-level effect emitted by `main`. In most languages this is named `IO`. `record` would record that the effect occurred, re-raise it to be handled by the built-in `IO` handler, and record its result. Then, on another run `replay` would handle `IO` and use the results from the effect log instead of actually performing them."

No implementation and no result; cited because it is the one place the idea is written down in effect-handler vocabulary with the word "replay".

## What the literature does not have

- **No paper defines a durable handler.** Nothing in the effects literature specifies a handler whose log survives the process, is resumed by a fresh process, and is proven to make the resumed run equivalent to an uninterrupted one. The bibliography index confirms the gap.
- **The only correctness results are outside the handler vocabulary.** Burckhardt et al.'s Lemmas 6.5–6.7 (deterministic replay, record/replay, transparency of recording) are stated for a workflow calculus with futures, not handlers ([sibling page][burckhardt]). Ramalingam and Vaswani's Theorems 3.4–3.9 are stated for a monad over an atomic store. Both proofs depend on the same assumption: the computation between logged steps is deterministic and the log is the only channel to the world.
- **No treatment of journal-versus-world disagreement.** Every replay scheme surveyed treats the record as truth; none re-observes the world on resume. Question 2 is unanswered by this body of work.
- **No treatment of versioning.** Positional identity (Apfelmus's log index, the idempotence monad's `tc`) is the norm; Pyro's named sites are the only content-addressed scheme, and nobody discusses running new code against an old record. Question 5 is unanswered.
- **The closest complete pattern is Pyro's `trace` + `replay`,** which has named step identity, effect suppression on replay, live fall-through on a miss, and kind-mismatch detection, but no persistence and no proof.

## Relevance to durable execution

### 1. Step identity and replay matching

Three schemes appear: position in the log (`operational`, thermometer continuations), a per-computation id plus a step counter (the idempotence monad), and a caller-supplied site name (Pyro, Nguyen et al.'s `Addr`). Only the third survives a code change that inserts or reorders a step, and only Pyro checks anything about the matched site (its kind). The PPL literature's "address" is the same object as a durable engine's step key, and the same problem (loops produce the same address twice unless a counter is folded in) is solved the same way.

### 3. Determinism enforcement

Uniformly by discipline, stated as a precondition. Thermometer continuations: the replayed computation "can't have any side effects, except for thermometer continuations". Nguyen et al.: replay is deterministic "since `draw` is pure". Ramalingam and Vaswani: every effect must go through `imatomic`. No surveyed system checks the precondition at runtime beyond Pyro's site-kind test; none uses a type or effect system to enforce it, though an effect row that excludes raw I/O would do so structurally.

### 4. Compensation and failure handling

The idempotence monad's λIDWF is the only surveyed formalism that combines a step log with compensations: `atomic t ea ec` registers `ec` as the compensation when `ea` commits, and `abort` runs the accumulated compensations in reverse (§4.1). Runners contribute finalisation with an exactly-once theorem. Scoped effects show that the compensation scope must be syntax the journal can see, not a handler boundary. See the sibling page [compensation calculi][compensation] for the algebraic treatment.

### 6. Concurrency under replay

dscheck is the demonstration that a handler owning every scheduling decision can enumerate and replay interleavings of effects deterministically. Unison's `Remote.pure.run` does the same in a simpler form: it serialises forks into a local task queue and runs them one at a time, so the local run has no real concurrency. Neither persists the schedule.

### 7. Replay or snapshot

The effects literature has both and prefers snapshot where it can: Unison serialises continuations; Koppel et al. replay precisely because they cannot capture. A runtime with tail-resumptive handlers and no continuation capture is on the replay side by construction, and thermometer continuations are the proof that this costs no expressiveness, only time.

### 8. Testing

Two patterns. A scheduler handler under model-checking search (dscheck) tests every interleaving. A replay handler tests reproducibility by construction: run under `trace`, run again under `replay`, compare (Pyro's own doctest does exactly this: `replayed_model(0.0) == old_trace.nodes["_RETURN"]["value"]`). The second is Burckhardt's Lemma 6.7 as an executable check.

## Relevance to sparkles

- **The journaling combinator has a name in the literature: it is Pyro's `trace` and `replay` fused into one handler, or in Nguyen et al.'s terms a `State STrace` handler installed after each capability operation.** The `release` spec can describe it that way and cite both, rather than presenting it as novel. The fused form (one handler that replays while the log has entries and records once it runs out) is exactly Apfelmus's `eval` and Burckhardt's replay-then-record worker.
- **The correctness statement to borrow is Ramalingam and Vaswani's, not only Burckhardt's.** Their Theorem 3.9 (the monadic translation is a failfree realisation of the original program) is the same shape as "the journaled workflow is observably the un-journaled workflow modulo retries", and it comes with the compensation extension the design also wants. The caveat to state alongside it: their proof puts the log in the same atomic store as the effects; `release`'s effects are `git` and GitHub, so the theorem covers the journal's own consistency and not the world's.
- **Confirms named step keys with an args hash.** Every positional scheme surveyed breaks on code change; Pyro's named sites are the one scheme that does not, and its `RuntimeError` on a kind mismatch is the weakest useful divergence check. The design's stable name plus attempt counter plus args hash is strictly stronger than anything in the literature.
- **Confirms "no continuation capture" costs nothing.** Thermometer continuations show replay _is_ a continuation implementation. The `Ctx` row with tail-resumptive capabilities is a runner in Ahman and Bauer's sense, and their finalisation theorem is the right precedent for LIFO compensations on a scope.
- **Argues for making the compensation scope a journal entry.** Wu, Schrijvers and Hinze's point that scopes must be syntax, not handler nesting, translates directly: a `scope-opened` / `scope-closed` pair belongs in `journal.jsonl`, so a resume can rebuild the LIFO stack without re-running the scope's body.
- **The design's "journal versus world" rule table and versioning story have no literature support and none against them.** Nothing surveyed re-observes the world or runs new code against old logs. Those two decisions are the design's own and should be tested as such.
- **The test plan is already the literature's test plan.** "Run under trace, run under replay, compare" is Pyro's doctest and Burckhardt's Lemma 6.7; "own the scheduler and enumerate" is dscheck. Crash-at-every-index is Lemma 6.6 and has no effects-literature precedent, which is fine.

## Sources

- Pyro `poutine`: [`docs/source/poutine.rst`][pyro-rst], [`pyro/poutine/trace_messenger.py`][pyro-trace], [`pyro/poutine/replay_messenger.py`][pyro-replay], [`pyro/poutine/handlers.py`][pyro-handlers], all at `45341b1ba77d0f0d6de1999b8bd2d305ef4ec190`; [documentation][pyro-docs]; Bingham et al., "Pyro: Deep Universal Probabilistic Programming", [arXiv 1810.09538][pyro-paper].
- Minh Nguyen, Roly Perera, Meng Wang, Nicolas Wu, "Modular Probabilistic Models via Algebraic Effects", ICFP 2022, [`10.1145/3547635`][nguyen-doi] ([arXiv PDF read][nguyen-pdf]); Nguyen, Perera, Wang, Ramsay, "Effect Handlers for Programmable Inference", [arXiv 2303.01328][nguyen-inference].
- Dave Moore, Maria I. Gorinova, "Effect Handling for Composable Program Transformations in Edward2", PROBPROG 2018, [arXiv 1811.06150][edward2] (abstract: Pyro's Poutines library named as the prior effect-handler PPL).
- James Koppel, Gabriel Scherer, Armando Solar-Lezama, "Capturing the Future by Replaying the Past", ICFP 2018, [`10.1145/3236771`][thermo-doi] ([arXiv PDF read][thermo-pdf]).
- G. Ramalingam, Kapil Vaswani, "Fault Tolerance via Idempotence", POPL 2013, [`10.1145/2429069.2429100`][idem-doi] ([author PDF read][idem-pdf]).
- Heinrich Apfelmus, `operational`, [`doc/examples/WebSessionState.lhs`][operational-web] at `597a561d07c77e32068eef2129982068ac8cceba`.
- Danel Ahman, Andrej Bauer, "Runners in action", ESOP 2020, [arXiv 1910.11629][runners-arxiv] ([PDF read][runners-pdf]).
- `ocaml-multicore/dscheck`: [README][dscheck-readme], [`src/tracedAtomic.ml`][dscheck-src] at `45406eca007f391dc9764b949f23b0cfed343a9b`; Carine Morel, Isabella Leandersson, [Multicore Testing Tools: DSCheck Pt 2][tarides-dscheck], Tarides, April 10, 2024.
- Unison: [Cloud core concepts][unison-core]; Rebecca Mark, [Visualizing remote computations in Unison][unison-blog], March 7, 2023; [`docs/distributed-programming-rfc.markdown`][unison-rfc] at `0452fcab2635cdbf0d1f717812a1168d300ebbcb`.
- Nicolas Wu, Tom Schrijvers, Ralf Hinze, "Effect Handlers in Scope", Haskell 2014, [`10.1145/2633357.2633358`][scope-doi] ([author PDF read][scope-pdf]).
- Jake Fecher, [Why Algebraic Effects?][ante], Ante blog, May 21, 2025, section "Replayability".
- Jeremy Yallop et al., [effects-bibliography][effbib], [README at `08d791bf`][effbib-readme].
- Burckhardt et al., "Durable Functions: Semantics for Stateful Serverless", OOPSLA 2021, [`10.1145/3485510`][df-doi] ([author PDF][df-pdf]), §6.3 and §7.
- Sibling and parent pages: [Burckhardt et al.][burckhardt], [compensation calculi][compensation], [deterministic simulation testing][dst], [Unison][unison-page], [Koka][koka-page], [OCaml effects][ocaml-page], [papers][papers-page], [theory and compilation][theory-page], [catalog index][index].

<!-- References -->

[pyro-docs]: https://docs.pyro.ai/en/stable/poutine.html
[pyro-rst]: https://github.com/pyro-ppl/pyro/blob/45341b1ba77d0f0d6de1999b8bd2d305ef4ec190/docs/source/poutine.rst
[pyro-trace]: https://github.com/pyro-ppl/pyro/blob/45341b1ba77d0f0d6de1999b8bd2d305ef4ec190/pyro/poutine/trace_messenger.py
[pyro-replay]: https://github.com/pyro-ppl/pyro/blob/45341b1ba77d0f0d6de1999b8bd2d305ef4ec190/pyro/poutine/replay_messenger.py
[pyro-handlers]: https://github.com/pyro-ppl/pyro/blob/45341b1ba77d0f0d6de1999b8bd2d305ef4ec190/pyro/poutine/handlers.py
[pyro-paper]: https://arxiv.org/abs/1810.09538
[nguyen-doi]: https://doi.org/10.1145/3547635
[nguyen-pdf]: https://arxiv.org/pdf/2203.04608
[nguyen-inference]: https://arxiv.org/abs/2303.01328
[edward2]: https://arxiv.org/abs/1811.06150
[thermo-doi]: https://doi.org/10.1145/3236771
[thermo-pdf]: https://arxiv.org/pdf/1710.10385
[idem-doi]: https://doi.org/10.1145/2429069.2429100
[idem-pdf]: https://www.microsoft.com/en-us/research/wp-content/uploads/2016/02/popl38-ramalingam.pdf
[operational-web]: https://github.com/HeinrichApfelmus/operational/blob/597a561d07c77e32068eef2129982068ac8cceba/doc/examples/WebSessionState.lhs
[runners-arxiv]: https://arxiv.org/abs/1910.11629
[runners-pdf]: https://arxiv.org/pdf/1910.11629
[dscheck]: https://github.com/ocaml-multicore/dscheck
[dscheck-readme]: https://github.com/ocaml-multicore/dscheck/blob/45406eca007f391dc9764b949f23b0cfed343a9b/README.md
[dscheck-src]: https://github.com/ocaml-multicore/dscheck/blob/45406eca007f391dc9764b949f23b0cfed343a9b/src/tracedAtomic.ml
[tarides-dscheck]: https://tarides.com/blog/2024-04-10-multicore-testing-tools-dscheck-pt-2/
[unison-core]: https://www.unison.cloud/docs/core-concepts/
[unison-blog]: https://www.unison-lang.org/blog/visualizing-remote/
[unison-rfc]: https://github.com/unisonweb/unison/blob/0452fcab2635cdbf0d1f717812a1168d300ebbcb/docs/distributed-programming-rfc.markdown
[scope-doi]: https://doi.org/10.1145/2633357.2633358
[scope-pdf]: https://www.cs.ox.ac.uk/people/nicolas.wu/papers/Scope.pdf
[ante]: https://antelang.org/blog/why_effects/
[effbib]: https://github.com/yallop/effects-bibliography
[effbib-readme]: https://github.com/yallop/effects-bibliography/blob/08d791bf9bcf20164aa5919e97272df147d9f1ed/README.md
[df-doi]: https://doi.org/10.1145/3485510
[df-pdf]: https://www.microsoft.com/en-us/research/wp-content/uploads/2021/10/DF-Semantics-Final.pdf
[burckhardt]: ./burckhardt-durable-functions-semantics.md
[compensation]: ./compensation-calculi.md
[dst]: ./deterministic-simulation-testing.md
[index]: ./index.md
[unison-page]: ../unison.md
[koka-page]: ../koka.md
[ocaml-page]: ../ocaml-effects.md
[papers-page]: ../papers.md
[theory-page]: ../theory-compilation.md
