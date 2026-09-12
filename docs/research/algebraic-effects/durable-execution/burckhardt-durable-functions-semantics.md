# Durable Functions: Semantics for Stateful Serverless (OOPSLA 2021)

The only peer-reviewed formalization of replay-based durable execution: it defines an idealized fault-free semantics for orchestrations, activities and entities, then proves that a compute-storage-separated implementation simulates it, and that storing a history of events instead of the execution state is a bisimulation, provided the orchestration is deterministic.

| Field        | Value                                                                                                                                                                                                      |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Sebastian Burckhardt, Chris Gillum, David Justo, Konstantinos Kallas, Connor McMahon, Christopher S. Meiklejohn                                                                                            |
| Venue / year | Proc. ACM Program. Lang. 5, OOPSLA, Article 133 (October 2021)                                                                                                                                             |
| DOI or URL   | [10.1145/3485510][doi] · [author PDF][pdf] · [SPLASH 2021 talk page][splash]                                                                                                                               |
| Category     | theory                                                                                                                                                                                                     |
| Grounds      | 1 (step identity), 2 (journal versus world: by explicit exclusion), 3 (determinism), 4 (failure handling), 6 (concurrency under replay), 7 (replay or snapshot). Silent on 5 (versioning) and 8 (testing). |

**Last reviewed:** September 12, 2026.

The companion implementation is the Durable Task Framework ([`Azure/durabletask`][durabletask], local clone at `$REPOS/durabletask` at `b385165ac10ecebbf183fdfdb07db33307756792`), and the backend the authors were designing while writing the paper is [Netherite][netherite] ([`microsoft/durabletask-netherite`][netherite-repo]). The paper models neither directly; it says so (see [Results](#results)).

## What it establishes

The paper answers one question in three layers: how can a workflow written in an ordinary language, with no runtime support for checkpointing, make reliable progress on volatile workers that may die mid-execution or execute the same work twice? Its answer is a stack of three operational models, each refining the previous, with a proof at each seam. The high-level model (§4) is the specification: the untyped lambda calculus plus `await`, futures, and the DF primitives, executed with no faults and exactly once. The compute-storage model (§5) replaces that with a durable key-value store that offers atomic commit and an elastic pool of stateless workers that fetch work-items, execute them, and try to commit; Theorem 5.3 says the specification weakly simulates it. The replay-based model (§6) replaces the stored execution state with a history of events that the worker replays to rehydrate the state before recording new events; Theorem 6.4 says this is bisimilar to the compute-storage model, and the proof leans on one lemma, deterministic replay, that the calculus satisfies trivially and a real language satisfies only by discipline.

The definitions that matter:

- **Three function types** (Fig. 3, page 133:7): an activity is a plain FaaS function whose unit of progress is its completion and which need not be deterministic; an orchestration is async/await task-parallel code whose unit of progress is a completed task and which must be deterministic; an entity is a virtual actor whose unit of progress is one operation and which need not be deterministic.
- **Work-item** (§5): the unit of billing and of atomic progress. For an activity, one complete execution; for an entity, a batch of queued operations run to completion; for an orchestration, "a work-item starts a new execution, or processes responses to a waiting execution. It continues execution until the code completes or gets stuck waiting on a response" (page 133:18).
- **History** (§6.1): "a history is simply a sequence of incoming messages `in(g)` and outgoing messages `out(g)`" (page 133:21). Nothing else is persisted for an orchestration.
- **Replay** (§6.2): "The point of this 'replay execution' is to 'rehydrate' the execution state. Any other effects are suppressed: for example, messages that were already sent by the original execution are not sent again during replay. When replay is complete, 'recording execution' starts. Effects are normally applied, and also recorded into the history to enable future replay" (page 133:22).
- **The programmer's obligation** (§3.5): "the orchestration code must be deterministically replayable. Any code that reads non-deterministic data sources or calls I/O should not be done directly in the orchestration, but must be wrapped in an activity, to ensure it is properly recorded and replayed" (page 133:11).

## The model

### The calculus

Code inside every function type is an untyped call-by-value lambda term. Fig. 9 (page 133:12) adds the DF operations and, crucially, a column of context restrictions: which of activity, orchestration, entity, or critical section may use each form.

| Form                | Meaning                | Activity | Orchestration | Entity | Critical section |
| ------------------- | ---------------------- | -------- | ------------- | ------ | ---------------- |
| `await e`           | basic evaluation       | yes      | yes           | yes    | yes              |
| `call nA(e)`        | call activity          | no       | yes           | no     | no               |
| `call nE.o(e, e)`   | call entity            | no       | yes           | no     | only if locked   |
| `call nX(e)`        | call external service  | yes      | no            | yes    | no               |
| `continue nO(e)`    | continue as new        | no       | yes           | no     | no               |
| `signal nE.o(e, e)` | signal entity          | no       | yes           | yes    | only if unlocked |
| `get` / `set e`     | read / write own state | no       | no            | yes    | no               |
| `lock<e> e`         | critical section       | no       | yes           | no     | no               |

The restriction table is the whole determinism story in one place: an orchestration cannot call an external service at all. The only way for the world to enter an orchestration is as the result of an activity or entity call, and those results arrive as messages that the runtime records.

Asynchrony is futures. A call evaluates to a placeholder `P_i` with a globally fresh identifier `i`; when the callee finishes, every occurrence of `P_i` in the caller's term is substituted by `done ρ`, where `ρ` is a constant or `error` (rule Act-Done, §4.3.5). Two calls overlap by binding both placeholders before awaiting either. Errors do not have handlers in the calculus: "errors always propagate to the top level. Adding exception handling should pose no major difficulties, however" (§4.1.3). Activity timeouts are a nondeterministic rule that replaces a busy activity's term with `error` (Act-Timeout, §4.3.4).

### System states and observability

A system state is an unordered bag of components: activities `A_i(x)`, orchestrations `O_d(x)` keyed by a client-chosen instance id `d`, and entities `E_k(q, x)` keyed by a (name, key) pair with a FIFO request queue `q`. Transitions carry labels; the only externally observable ones are `in(m)` and `out(m)`, messages exchanged with the environment. In the high-level model those messages are exactly: `startnew(d, nO, c)` with replies `ok` or `alreadyexists`, and external-service calls `nX(c)` with their replies (§4.2). Two executions are equivalent when their observable label sequences are. That is the correctness currency for both theorems.

Entities are virtual actors: they are never created or destroyed, only nondeterministically materialized from and collected to a default state (AutoStart / Collect, §4.4.1). Their queues are "FIFO-per-origin: only the right-most (oldest) request from a particular origin can be dequeued" (§4.4.5), which is the formal content of the informal guarantee that all messages from one orchestration to one entity arrive in order. Entities cannot call other entities, only signal them, because a call cycle between two busy entities "would be (durably and reliably) deadlocked forever" (§3.3.3). Critical sections lock a declared set of entities for one orchestration; while inside, it may call only locked entities, signal only unlocked ones, and neither call sub-orchestrations nor nest (§3.4.1).

### The compute-storage model

The store is a key-value map with a queue attached to each entry: `κ<g, x>`, where `κ` is an activity id, an instance id, or an entity key, `g` is a queue of task messages (start orchestration, start activity, entity request, response for orchestration) and `x` is the execution state. A worker picks an entry with a non-empty queue, runs it to a stable point, and sends one commit message:

```text
S-Commit
  S κ<g_new g_in, x_pre> + commit(κ, g_in, x_pre, x_post, g_out)
    ⇒ enq(g_out, S κ<g_new, x_post>) + ok
```

The paper's own gloss (§5.1.3): "The commit happens only if the original `g_in` and `x_pre` match. This ensures that even if multiple workers attempt to execute the same work item, only one worker can commit it. This mechanism is conceptually similar to compare-and-swap in shared-memory multiprocessors." Messages that arrived while the worker was busy (`g_new`) survive the commit; the produced messages are fanned out to every destination queue in the same atomic step. A worker's run is a big-step relation that ends only in `completed ρ`, a term stuck on a placeholder, or an idle entity (Definition 5.1); commits are sent only at those points (Definition 5.2).

### The replay-based model

The store is unchanged except that `x` becomes a history `h` of `in(g)` / `out(g)` entries, and one new task message `k.σ` records the initialization of entity `k`'s state to `σ`. A worker's obligation becomes (Definition 6.3): replay `h_in` to some `x_pre`, then run a recording execution from `x_pre` consuming `g_in` and appending to the history, then commit `(κ, g_in, h_in, h_out, g_out)`.

Recording (Fig. 12) appends `in(g)` whenever a message is consumed and `out(g)` whenever one is produced. Two recording rules are the interesting ones: when an entity operation finishes, the worker appends `in(k.σ)`, the entity's whole state, to the history; and `continue nO(c)` does not append, it replaces the history with the single entry `in(d.nO(c))`. Replay (Fig. 13) walks the history from the left: an `in(g)` entry is applied to the state exactly as a live message would be, and an `out(g)` entry is consumed by re-running the step that produces `g` without actually sending it. The `g` in the history entry and the `g` the re-executed step produces are the same metavariable in rule YOut, so a re-execution that would emit a different message has no applicable rule: replay is stuck, not silently divergent.

The Durable Task Framework's real history is the same shape with named event types. From [`src/DurableTask.Core/History/EventType.cs`][event-type]: `ExecutionStarted`, `TaskScheduled` / `TaskCompleted` / `TaskFailed`, `SubOrchestrationInstanceCreated` / `...Completed` / `...Failed`, `TimerCreated` / `TimerFired`, `OrchestratorStarted` / `OrchestratorCompleted`, `EventSent` / `EventRaised`, `ContinueAsNew`, and later additions (`ExecutionSuspended`, `ExecutionResumed`, `ExecutionRewound`). The `Scheduled` / `Created` / `Sent` events are the paper's `out(g)`; the `Completed` / `Failed` / `Fired` / `Raised` events are its `in(g)`.

## Results

- **Theorem 5.3.** The simulation relation between compute-storage states and high-level states is a weak simulation when commit messages are hidden. Consequence stated by the authors: "the internal state of a DF application, i.e., the state of all actors, queues, and the progress of all orchestrations, is not visibly affected by any transient faults or recoveries of the underlying infrastructure" (page 133:4). The relation is defined per key (Fig. 11), so it is compositional over components: an entity matches when queue and state match; an activity or orchestration matches the high-level state obtained after applying every queued message.
- **Theorem 6.4.** The relation "history replays to state" lifted to whole stores is a bisimulation. The proof is boilerplate except at S-Commit, where it needs three lemmas: 6.5 (Deterministic Replay: a history replays to at most one state), 6.6 (Record/Replay: recording from a state that `h_in` replays to yields an `h_out` that replays to the resulting state), and 6.7 (Transparency of Recording: a recording execution is a regular execution with a log attached, and every regular execution has a recording counterpart). Because it is a bisimulation and not just a simulation, the paper claims both directions: "persisting histories is equivalent to persisting intermediate states" (§6.3).
- **The determinism caveat, in the authors' words.** "Lemma 6.5 relies on the determinism of the execution, which in this model, is easy to prove for our simple lambda calculus. In a mainstream programming language, nondeterminism is not implicitly guaranteed, and requires programmers to be careful when writing orchestrations (§3.5)" (page 133:23).
- **Exactly-once is internal only.** Activities "are automatically retried under partial execution. However, if an activity exceeds the FaaS time limit, or if the application code in the activity throws an unhandled exception, it is not automatically retried. Rather, the activity is considered to have completed with an exception result, and the exception is re-thrown in the parent orchestration" (§3.1). Workers may run the same work-item concurrently since failure is undetectable, and the store lets only one commit. But external calls are excluded from the compute-storage model precisely because "duplication of external calls (unlike internal calls) is observable, and can happen when workers make repeated attempts at processing a work item" (§5, Future Extensions). The high-level model includes them (§4.5) only so that the weaker guarantee of the lower models can be stated.
- **What is not modelled.** Critical sections are absent from the compute-storage model (they need the distributed locking protocol). Timers, external events, and sub-orchestrations appear in the informal §3 and in the implementation's event types but have no transition rules; the only environment inputs in the calculus are `startnew` and external-call replies. Error handling is absent. Netherite's sharded commit-log design is named as the subject of a future proof: "to formalize and prove the CCC guarantee of the sharded Netherite implementation" (§8).
- **Relationship to real backends.** "Our compute storage model (§5) and the SqlServer backend are actually very similar, as they both achieve reliable execution using an atomic commit primitive" (§7). Netherite instead "uses static partitions that can atomically commit work items using a per-partition commit log, and communicate via ordered persistent queues" (§7), citing the [Netherite paper][netherite-vldb]; see [Netherite][netherite] for that design.

## Relevance to durable execution

### 1. Step identity and replay matching

In the calculus a step is identified by a globally fresh identifier `i` minted at the call (label `i` on the transition; Definition 4.1 requires all such identifiers in an execution to be distinct) and carried by the placeholder `P_i`, the activity component `A_i`, and the response message `d.(ρ/i)`. Replay matching is structural: the history is consumed left to right, and an `out(g)` entry matches only if re-execution produces the identical message `g`, which contains the callee name, the argument, and the identifier. There is no lookup by name; position in the history is the key, and identity is a consequence of determinism.

The implementation makes the position explicit. [`TaskOrchestrationContext.cs`][orch-ctx] assigns `int id = this.idCounter++` to each scheduled activity, timer, or sub-orchestration in program order, and on replay `HandleTaskScheduledEvent` looks the history event's `EventId` up in the actions the current execution has produced so far. A miss throws `NonDeterministicOrchestrationException` with the message "A previous execution of this orchestration scheduled an activity task with sequence ID ... but the current replay execution hasn't (yet?) scheduled this task. Was a change made to the orchestrator code after this instance had already started running?"; a hit with a different name or version throws the same exception. Identity is therefore (sequence number, name, version), with no hash of the arguments.

### 2. Journal versus world

The paper's world is the store, and the store is owned by the runtime; there is no second source of truth for the journal to disagree with. Disagreement in the model is only ever between two workers racing on one work-item, and S-Commit resolves it by compare-and-swap on `(g_in, x_pre)`: the loser's execution is discarded wholesale, including any external calls it made, which is exactly why external calls are pushed out of the model. The paper's honest position is that effects on the outside world are at-least-once and unmodelled, and that the exactly-once theorem covers only what the store holds. Nothing in the paper re-observes the world on resume; an activity result, once in the history, is the truth forever.

### 3. Determinism enforcement

By discipline, backed by structure. The calculus makes non-determinism unexpressible in an orchestration (no `call nX`, no clock, no random) and then proves Lemma 6.5 trivially. Real languages get: the §3.5 guideline to wrap I/O in activities; built-in deterministic substitutes for common cases ("read the current time, create a random new GUID"), which in the implementation are `CurrentUtcDateTime` and `IsReplaying` on [`OrchestrationContext.cs`][ctx]; a C# static analyzer that "can warn users about suspected error" (footnote 7); and, at run time, the sequence-id check above, which catches a divergence only when it changes the order or kind of scheduled tasks. A non-deterministic branch that schedules the same tasks in the same order is invisible to every layer.

### 4. Compensation and failure handling

Absent as a first-class notion. The calculus has no handlers; the informal model has ordinary `try` / `except` in the orchestration (Fig. 4), and the only failure vocabulary is: an activity's timeout or exception becomes an `error` result awaited by the parent; a worker crash is invisible because the uncommitted work-item is retried by another worker. Compensation, if wanted, is an activity the orchestration chooses to call in its `except` clause, ordered by the program, not by the runtime. Critical sections are the paper's answer to the atomicity question that sagas usually answer: "Unlike transactions, they do not require the programmer to handle failures or issue retries, and operate reliably even in the presence of contention" (§3.4.2), but they cover only entities inside the system, never external effects.

### 5. Versioning against old histories

Not addressed. The application `A` is a fixed map from names to lambda terms for the whole execution. The only mention of evolution is the implementation's exception text quoted under question 1, which treats changed code as a determinism violation. `continue nO(c)` is the closest tool: it truncates the history to a single start entry, so an orchestration that restarts itself at a version boundary carries no old events forward.

### 6. Concurrency under replay

Task parallelism is futures over an unordered bag of components, so the interleaving of activity completions is arbitrary in the high-level model. Replay does not need to reproduce it: the history records the order in which the orchestration's work-item consumed responses (`in(d.(ρ/i))`), and replay applies them in that recorded order (rule YIn), so the placeholder substitutions happen in the same sequence they did originally. The fan-out / fan-in of Fig. 5 therefore replays deterministically even though its activities ran in any order. Entity concurrency is serialized per entity by construction (one operation at a time, FIFO-per-origin), and cross-entity atomicity is a critical section, which the models do not include.

### 7. Replay or snapshot

This is the paper's central result and it is subtler than "replay". Orchestrations are replayed because "the state of the orchestration can be dispersed, including variables and the execution location, as well as arbitrary non-serializable objects on the heap" (§6). Entities are effectively snapshotted: the recording rule for a finished entity operation appends the entity's entire post-state `in(k.σ)` to the history, so replaying an entity is reading its last snapshot entry. The two coexist in one history format because a snapshot is just an `in` entry the runtime chose to synthesize. Cost and mitigation are stated plainly: "history size can become an issue if it grows too large to be replayed quickly", so structure work as sub-orchestrations "so that only small portions of the overall history have to be replayed at any given time", or use `continue_as_new` (§3.5). The claimed benefit beyond language independence is observability: "users can later inspect not only the final execution state of the application, but also all of its intermediate steps" (§6).

### 8. Testing

Not addressed; the paper's validation is proof, not test. What it leaves behind is nonetheless a test oracle: Lemma 6.7 says recording is transparent (run the workflow with and without the journal, compare observable output) and Lemma 6.6 says any prefix of a recording replays to the state the recording had at that point (cut the history anywhere, replay, continue, compare). Those two lemmas are exactly the properties an empirical harness can check.

## Relevance to sparkles

- **Confirms the layering and names the theorem to aim at.** The decided design, one pure workflow function over the capability row with journaling as the single pure-cast, is the paper's three models with the runtime removed: the function under live capabilities is the high-level model, the journaling combinator is the recording execution, and the resume path is replay. The `release` spec can cite Theorems 5.3 and 6.4 for the shape of the correctness claim, and Lemma 6.7 (Transparency of Recording) as the property the journaling combinator must preserve: adding the journal must not change what the workflow does.
- **Confirms "decisions replay verbatim, effects are suppressed".** Rule YOut is precisely "re-run the step, do not emit the effect, check the emitted message equals the recorded one". The args-hash in the sparkles step key is stronger than the implementation (sequence id plus name plus version, no argument check) and matches the calculus, where the whole message is compared.
- **Cannot be cited for journal-versus-world reconciliation.** The paper's runtime owns the only state; git tags and HEAD are external, mutable by other actors, and the paper explicitly excludes external calls from its proved models because their duplication is observable. The "re-observe and reconcile by rule table" decision has no support here and no refutation either; it is outside the paper's universe. The one usable idea is the entity trick from question 7: an observation of the world can be recorded as a synthesized `in` entry, so the journal carries a snapshot of what was seen without pretending it caused it.
- **Argues that `git push` and `gh release create` are at-least-once and must be made safe by the tool, not the journal.** The paper's exactly-once is internal-state-only; every external effect between a `started` entry and its `completed` entry may have happened zero or one times when the process died. The spec should say that explicitly and cite §5's exclusion as the reason a journal alone cannot promise more. Whether the design's "re-observe the world" answers this for tags (a tag either exists or not) is the question the rule table has to settle per effect.
- **No work-item boundary exists in a CLI.** The paper's atomic unit is the work-item commit: state plus all outgoing messages land together or not at all. A single-process release tool has no such unit; it crashes between any two lines. Journaling `started` before and `completed` after each op is the right substitute, but the spec should not call it exactly-once, and the crash-at-every-event-index test is what stands in for S-Commit's atomicity.
- **Compensation and versioning get nothing from this paper.** Both are absent. The LIFO explicit compensation scope and the versioning rules must be justified from the subject pages (Temporal, Restate, DBOS), not from here. `continue_as_new` is the one relevant pattern: `--split` mode's chain of releases maps naturally onto one orchestration per release with a truncated history at each boundary, which also bounds replay cost per §3.5.
- **Determinism stays a discipline, and the paper says so.** With no continuation capture and every capability op tail-resumptive, sparkles' `Ctx` row already gives the structural half of the calculus's answer: the workflow cannot reach the world except through a handler that journals. The spec can cite Fig. 9's context-restriction table as the precedent for "an orchestration has no `call nX`", and the paper's own caveat on Lemma 6.5 as the reason a runtime divergence check (the sparkles args hash) is still required.
- **The testing strategy is the paper's two lemmas turned into a harness.** "Run with and without the journal, compare" is Lemma 6.7; "cut the journal at every index and resume" is Lemma 6.6. The spec can cite them as the properties the tests check, even though the paper never tests anything.

## Sources

- Burckhardt, Gillum, Justo, Kallas, McMahon, Meiklejohn. "Durable Functions: Semantics for Stateful Serverless". Proc. ACM Program. Lang. 5, OOPSLA, Article 133, October 2021. [DOI][doi]; [author PDF][pdf] (read in full for this page); [SPLASH 2021 talk page][splash].
- Burckhardt, Chandramouli, Gillum, Justo, Kallas, McMahon, Meiklejohn, Zhu. "Netherite: Efficient Execution of Serverless Workflows". PVLDB 15(8), 2022. [PDF][netherite-vldb]; earlier version [arXiv:2103.00033][netherite-arxiv]. The paper's §7 and §8 cite this work for the backend design.
- [`Azure/durabletask`][durabletask] at `b385165ac10ecebbf183fdfdb07db33307756792`: [`EventType.cs`][event-type] (the history event vocabulary), [`TaskOrchestrationContext.cs`][orch-ctx] (sequence-id replay matching and `NonDeterministicOrchestrationException`), [`OrchestrationContext.cs`][ctx] (`CurrentUtcDateTime`, `IsReplaying`).
- [`microsoft/durabletask-netherite`][netherite-repo]: the sharded commit-log backend; see the sibling [Netherite][netherite] page.
- Catalog context: [durable-execution index][index]; `sparkles:event-horizon` [spec][eh-spec]; `release` [spec][release-spec].

<!-- References -->

[doi]: https://doi.org/10.1145/3485510
[pdf]: https://www.microsoft.com/en-us/research/wp-content/uploads/2021/10/DF-Semantics-Final.pdf
[splash]: https://2021.splashcon.org/details/splash-2021-oopsla/37/Durable-Functions-Semantics-for-Stateful-Serverless
[netherite-vldb]: https://www.vldb.org/pvldb/vol15/p1591-burckhardt.pdf
[netherite-arxiv]: https://arxiv.org/abs/2103.00033
[durabletask]: https://github.com/Azure/durabletask
[event-type]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/History/EventType.cs
[orch-ctx]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/TaskOrchestrationContext.cs
[ctx]: https://github.com/Azure/durabletask/blob/b385165ac10ecebbf183fdfdb07db33307756792/src/DurableTask.Core/OrchestrationContext.cs
[netherite-repo]: https://github.com/microsoft/durabletask-netherite
[netherite]: ./netherite.md
[index]: ./index.md
[eh-spec]: ../../../specs/event-horizon/SPEC.md
[release-spec]: ../../../specs/release/SPEC.md
