# Compensation calculi for long-running transactions

What the [saga][sagas] pattern looks like once it is given an algebra: a forward action paired with its compensation, composition operators that decide the order compensations run in, a transaction block that runs them on failure, and laws you can calculate with. Plus the systems-side corrective from Helland: a compensation is not an undo but an _apology_, because the world already saw the action.

| Field        | Value                                                                                                                                                                                                                                                                                  |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Michael Butler, Tony Hoare, Carla Ferreira · Roberto Bruni, Hernán Melgratti, Ugo Montanari · Pat Helland, David Campbell                                                                                                                                                              |
| Venue / year | "A trace semantics for long-running transactions", _Communicating Sequential Processes: The First 25 Years_, LNCS 3525, 2005, pages 133–150 · "Theoretical foundations for compensations in flow composition languages", POPL 2005, pages 209–220 · "Building on Quicksand", CIDR 2009 |
| DOI or URL   | [`10.1007/11423348_8`][ccsp-doi] (author copy read: [Southampton ePrints][ccsp-pdf]) · [`10.1145/1040305.1040323`][bruni-doi] (author copy read: [Melgratti's publication page][bruni-pdf]) · [arXiv `0909.1788`][helland-abs] ([PDF][helland-pdf])                                    |
| Category     | theory                                                                                                                                                                                                                                                                                 |
| Grounds      | 4 (compensation) and 2 (journal versus world) principally; also 1 (step identity, via Helland's uniquifier), 3 (determinism), 6 (concurrency); 7 and 8 are absent                                                                                                                      |

**Last reviewed:** September 12, 2026.

The sibling page [Sagas (SIGMOD 1987)][sagas] covers the database paper these calculi formalise. The umbrella is the [durable-execution catalog index][index].

---

## What it establishes

Sagas gave an informal guarantee ("either `T1..Tn` or `T1..Tj, Cj..C1`") and an implementation. The two 2005 papers turn that into a language with a compositional semantics, and prove that the semantics matches the informal requirement. Both are built on the same three ideas: a **compensation pair** binding a forward action to its compensation; a redefinition of **sequential composition** so that compensations accumulate in reverse; and a **transaction block** that discards accumulated compensations on success and runs them on failure. From the cCSP abstract ([`10.1007/11423348_8`][ccsp-doi]):

> _"It introduces a method for declaring that a process is a transaction, and for declaring a compensation for it in case it needs to be rolled back after it has committed. The familiar operator of sequential composition is redefined to ensure that all necessary compensations will be called in the right order if a later failure makes this necessary."_

Both papers are explicit that they are modelling _semantic_ undo, in the sense the Sagas paper defined. Bruni et al. (§2): _"We remind that, in this context, the term 'undo' does not mean to exactly reverse the effects by restoring the original state, but just to perform an ad hoc activity that moves the system to a sound state."_ Butler, Hoare and Ferreira (§2) give the reason no automatic technique will do: _"a long-running transaction may have interacted with the real world before failing, and the real world cannot be check-pointed."_

Helland and Campbell, four years later and from the other side of the industry, generalise the observation to every system that answers before it has durably agreed with anyone: since the action was taken on partial knowledge and has already been observed, what follows a mistake is not a rollback but an apology, and the system should be designed around that from the start.

---

## Compensating CSP (Butler, Hoare, Ferreira, 2005)

### Syntax

cCSP has two sorts of process. _Standard_ processes `P, Q` are ordinary CSP-like processes: an atomic action `A`, `P ; Q`, choice `P □ Q`, parallel `P ‖ Q`, `SKIP`, `THROW`, `YIELD`, the interrupt handler `P ▷ Q`, and the transaction block `[PP]`. _Compensable_ processes `PP, QQ` are built from the compensation pair `P ÷ Q` (a forward process and its compensation), `PP ; QQ`, `PP □ QQ`, `PP ‖ QQ`, and the compensable basics `SKIPP`, `THROWW`, `YIELDD` (Figure 1 of the paper). The two sorts meet only at `[PP]`, which converts a compensable process back into a standard one.

The order-processing example (Figure 2):

```text
OrderTransaction = [ ProcessOrder ]
ProcessOrder     = (AcceptOrder ÷ RestockOrder) ; FulfillOrder
FulfillOrder     = BookCourier ÷ CancelCourier
                 ‖ PackOrder
                 ‖ CreditCheck ; ( Ok ; SKIPP  □  NotOk ; THROWW )
PackOrder        = ‖ i ∈ Items • (PackItem(i) ÷ UnpackItem(i))
```

A failed credit check throws; whatever `BookCourier` and the `PackItem(i)` branches have committed by then is compensated, and nothing else is.

### Semantics: pairs of traces

A standard process is a set of completed traces `s⟨ω⟩` where the terminal symbol `ω` is one of `✓` (terminated), `!` (threw an interrupt) or `?` (yielded to one). A compensable process is a set of **pairs** `(p⟨ω⟩, p′⟨ω′⟩)`: a forward trace and the compensation trace that would undo it. The whole design is in three definitions (§4):

- **Compensation pair** (Definition 11). `p⟨✓⟩ ÷ q = (p⟨✓⟩, q)`; if the forward part throws or yields, the compensation is empty: `p⟨ω⟩ ÷ q = (p⟨ω⟩, ⟨✓⟩)` for `ω ≠ ✓`. The rationale: _"a compensation is intended to be used to compensate, at a later stage, for a successfully completed forward unit of work and not for an interrupted unit of work."_ Every pair also contains `(⟨?⟩, ⟨✓⟩)`, so it can yield before starting with nothing to undo.
- **Sequential composition** (Definition 10) is the LIFO law, stated on traces:

  ```text
  (p⟨✓⟩, p′) ; (q, q′) = (pq, q′ ; p′)
  (p⟨ω⟩, p′) ; (q, q′) = (p⟨ω⟩, p′)      where ω ≠ ✓
  ```

  _"We redefine the sequential composition operator so that the compensation behaviour of the first process is made to happen after that of the second process."_ The paper's worked example: `A ÷ A′ ; B ÷ B′` has exactly the behaviours `(⟨?⟩, ⟨✓⟩)`, `(⟨A, ?⟩, ⟨A′, ✓⟩)` and `(⟨A, B, ✓⟩, ⟨B′, A′, ✓⟩)`: yield at once with nothing to undo, yield after `A` with `A′` installed, or complete with `B′` then `A′`.

- **Parallel composition** (Definition 9) interleaves forward traces and interleaves compensation traces: `(p, p′) ‖ (q, q′) = { (r, r′) | r ∈ p ‖ q ∧ r′ ∈ p′ ‖ q′ }`. Compensations of parallel branches run in parallel, in _any_ interleaving; the order in which the forward actions happened to interleave is not recorded and not replayed.
- **Transaction block** (Definition 13):

  ```text
  [PP] = { p p′ | (p⟨!⟩, p′) ∈ PP }  ∪  { p⟨✓⟩ | (p⟨✓⟩, p′) ∈ PP }
  ```

  An interrupted forward trace is extended with its accumulated compensation; a successful forward trace drops its compensation; yielding traces are removed entirely. The block _"masks interrupts and yields in forward behaviour"_: `[THROWW] = SKIP`.

Interrupts are not prioritised. In a parallel block a `!` in one branch synchronises with `!`, `✓` or `?` in the others (Table 1), so a sibling is only interrupted at a point where it is willing to yield. The law `THROW ‖ (YIELD ; P) = THROW □ P ; THROW` (for non-yielding `P`) says the interrupt lands either before `P` or after it, never inside; the authors note this _"is what we would expect in a distributed setting where we cannot expect an entire distributed system to respond immediately to an attempt by one party to raise an exception."_

### Cancellation semantics

§5 adds a relation `cancel(A, A°)` and an `independent(A, B)` relation, and a cancellation function `C` that deletes an `A … A°` pair from a trace when everything in between is independent of `A°`. A compensable process is _self-cancelling_ when every behaviour's forward and compensation parts cancel to the empty trace and the compensation terminates. The two results:

```text
self_cancelling(PP)  ⟹  C[ PP ; THROWW ] = SKIP                   (1)
self_cancelling(PP)  ⟹  C[ PP ] ⊆ PP✓ □ SKIP                        (2)
```

Rule (2) is the point: _"it allows us to reason separately about the normal behaviour and the compensation behaviour of a closed transaction block"_. Self-cancellation is preserved by `;` and `□` unconditionally, and by `‖` _"provided the compensations from parallel processes are independent"_. The proof obligation the programmer inherits is exactly two-fold: _"an action A is directly paired with its compensation A° and every compensation is independent of compensations in parallel processes"_.

### Speculative choice

§6 defines `PP ⊠ QQ`: run both forward, and when one completes, compensate the other. It is the transactional form of racing alternatives. The paper shows `[A ÷ A′ ⊠ B ÷ B′] = A □ B □ ((A ‖ B) ; (A′ □ B′))`, proves that under self-cancellation and independence it is indistinguishable from plain choice, and notes it is _not associative_: with three alternatives the losers' compensations run in an order that depends on the bracketing.

### Position against StAC

The related-work section is candid about the authors' own earlier language: StAC _"has explicit primitives for running or discarding installed compensations (`reverse` and `accept` respectively)"_, and _"the separation of the `accept` and `reverse` operators from compensation scoping prevents the definition of a compositional semantics: the semantics of the `reverse` operator cannot be defined on its own as its behaviour depends on the context in which it is called."_ cCSP's answer is to make running the compensation part of the meaning of `[PP]`.

---

## The sagas calculi (Bruni, Melgratti, Montanari, POPL 2005)

### A hierarchy, each with an adequacy theorem

Bruni et al. build the same ideas as an operational big-step semantics and grow it in layers: sequential sagas, parallel sagas (a naive semantics and a revised one), nested sagas, then programmable compensations, exception handling, forward-recovery alternatives, choices, and link dependencies. The core grammar (Definition 1):

```text
(STEP)     X ::= 0 | A | A ÷ B
(PROCESS)  P ::= X | P ; P
(SAGA)     S ::= {[ P ]}
```

with structural axioms `A ÷ 0 = A`, `0 ; P = P ; 0 = P`, and associativity of `;`. Execution is judged against a context `Γ` that says, for each atomic activity, whether it commits or aborts; the calculus deliberately _"is intended to describe the behavior of top-level processes but not the low-level computations performed by atomic activities"_. A saga's result is one of commit `⊡`, compensated abort `⊠`, or abnormal termination `⊞` (a compensation itself failed). The key rule (`S-ACT`) installs the compensation at commit time and in front of what is already there: _"the compensation is updated by installing B in front of β. Note that A is the last executed activity, hence the first to be compensated for if the next activity in the saga fails."_

The adequacy theorem for sequential sagas (Theorem 1) recovers the Sagas guarantee exactly: completion is `A1 … An`; successful compensation is `A1 … A(k-1) ; B(k-1) … B1` for the failing `Ak`; and failed compensation is the same prefix with the compensation sequence cut short at the first `Bj` that aborts. The paper notes: _"It is clear from the above theorem that the last compensation Bn is never activated."_

### Parallel composition: two policies, one chosen

The parallel calculus is where the paper states a policy and names the alternatives it rejects. On order (§3):

> _"Composition languages usually express this requirement by stating that all compensation handlers for completed activities run in the reverse order of completion. In our approach the compensations of concurrent activities are concurrent, because we want a semantics where compensations do not depend on the particular interleaving of executed concurrent activities."_

That is a direct rejection of the BPEL reading, in which compensation order is a function of the observed forward interleaving. The **naive** semantics (§3.1) lets parallel branches run to completion independently even after a sibling has aborted; the paper shows on `{[ A1 ÷ B1 ; A2 ÷ B2 | C1 ÷ D1 ]}` with `C1` failing that this forces `A2` and then `B2` to run pointlessly, and calls it _"not entirely satisfactory when modelling real problems, because it does not allow to force the failure in one branch as soon as a failure is detected in the other branch."_ The **revised** semantics (§3.2) adds two results, "forced to compensate and compensated" and "forced to compensate and the compensation failed", plus a `FORCED-ABT` rule that lets a branch _"activate the compensation procedure before starting its execution"_. The ordering constraint is then stated as an order `<S` on activities (Definition 5): `A <S B` when `A ÷ B` occurs, when `A` is in the forward flow of `P` and `B` in that of `Q` for `P ; Q`, and reversed for compensations (`A <S B ⟹ B⁻¹ <S A⁻¹`). Theorems 2 through 4 characterise a valid execution as one whose observed flow respects `<S`, executes exactly the activities that precede the failure set, and compensates exactly the executed ones.

### Nesting, programmable compensations, exceptions, alternatives

- **Nesting** (§4): a nested saga `{[ P ]}` used as a step runs in its own thread with no initial compensation; on commit its accumulated compensation is installed as one unit in the parent (`SUB-CMT`); on a compensated abort the abort is _hidden_ from the parent (`SUB-ABT`), which is what lets a top-level transaction commit despite failed sub-transactions; abnormal termination propagates. Two further rules let a running sub-saga be interrupted and compensated when a sibling fails.
- **Programmable compensations** (§5.1): BPEL-style `S ÷ P` where the programmer overrides the default compensation of a nested block. The paper chooses rule `PGM-CMP`, which installs only the _forward flow_ of `P` (its own compensations stripped) so that _"the execution of a compensation never generates new compensations neither terminates abnormally"_. The alternative, StAC-style `REPEATED-COMP`, where compensations install compensations, is rejected: _"it would mean that a successful execution of A1 can be undone by running B1, which can be in turn compensated with C1 … it is difficult to figure out real cases in which repeated compensation is really necessary."_
- **Exception handling** (§5.2): `try S with P` catches abnormal termination, that is a _failed compensation_; the section closes with the division of labour: _"compensations undo partial executions of transactions, while exception handling deals with incomplete compensations."_
- **Alternatives** (§5.3): `try S or P` is forward recovery, activated only on abort during forward execution, never during a forced compensation: _"alternatives are intended to be used while executing towards a completion not during the compensation procedure."_
- **Links** (§5.5): a synchronisation `link(Ai, Aj)` between parallel branches must be honoured in reverse by the compensations (`Aj⁻¹ <S,L Ai⁻¹`). The paper criticises StAC, which _"ignores all synchronizations when computing backward"_.

The conclusion lists what the calculus abstracts away: _"we do not include usual imperative features, such as state (or variables), control structures like branching or iteration, neither data communication between activities (i.e. parameter passing). We abstract away from the fact that compensations usually require appropriate data when activated."_ The two groups compared their calculi directly in a joint CONCUR 2005 paper ([`10.1007/11539452_30`][compare-doi]), not read for this page.

---

## Building on Quicksand (Helland, Campbell, CIDR 2009)

Helland and Campbell are not writing about compensation calculi; they are writing about what happens to transactional guarantees when a system acknowledges work before its backup knows about it. Their vocabulary is nevertheless the one question 2 needs.

The paper's arc: fault tolerance has always been _"a set of idempotent sub-algorithms"_ between which state crosses a failure boundary (§2.2, the river-crossing image: _"stepping across a river from rock to rock, always keeping one foot on solid ground"_). Once checkpointing to the backup becomes asynchronous (log shipping, §4.1), two things follow (abstract): _"Everything promised by the primary is probabilistic … Hence, nothing is guaranteed!"_ and _"Applications must ensure eventual consistency."_ §5 draws the consequence for replay:

> _"The old model assumed the work would be processed in exactly one order of execution. … This single history allows for a low-level READ and WRITE semantic that depends on 'replaying history'. In this new world, history cannot be exactly replayed and we must count on the ability to reorder the work."_

And for truth (§5.1): _"Back when we had a centralized machine with synchronous checkpointing, we knew the one and only one answer at any given point in time. Allowing for work being locked up in an unavailable backup (née primary) means we don't know the truth."_

### Memories, guesses, and apologies

§5.4 and §5.7 define the triad:

> _"Memories: Your local replica has seen what it has seen and (hopefully) remembers it. … Guesses: Any time an application takes an action based upon local information, it may be wrong. … In any system which allows a degradation of the absolute truth, any action is, at best, a guess. It is simply a matter of business choice as to the quality of the guess. Apologies: When a mistake is made (either due to replication anomalies or because the FAA grounds your jets and you cannot honor your flight reservations), you apologize. Every business includes apologies."_

> _"Arguably, all computing really falls into three categories: memories, guesses, and apologies. The idea is that everything is done locally with a subset of the global knowledge. You know what you know when an action is performed. Since you have only a subset of the knowledge, your actions are really only guesses. When your knowledge as a replica increases, you may have an 'Oh, crap!' moment."_

The reason a compensation is an apology and not an undo is that the action was already observed outside the system's control; §7.2 makes the point with a case where the computers are flawless: the only book in inventory is promised to a customer, then _"it is run over by the forklift in the warehouse. So, over-provisioning notwithstanding, you need to apologize! Even if the computer systems are perfect, business includes apologizing because stuff will go wrong!"_ The policy the paper recommends for a violated business rule (§5.6) is the same one the Sagas paper landed on for a stuck compensation: _"1. Send the problem to a human (via email or something else), 2. If that's too expensive, write some business specific software to reduce the probability that a human needs to be involved."_

### Uniquifiers, idempotence and ACID 2.0

The mechanism that makes retry safe is the _uniquifier_ (§2.1, §5.4): _"each request is submitted with a 'uniquifier' that ensures the request is unique (and ensures retries will be associated with the original request), OR the service applies some trick to accomplish the same thing. An example trick is the creation of an MD5 hash of the entire incoming request."_ The identifier must be _"functionally dependent only on the request as seen by the server system"_, and it has two roles: it partitions the work, and _"it allows the system to recognize multiple executions of the same request. In this fashion, they can be collapsed and the work becomes idempotent."_ §8 names the target property set ACID 2.0, _"Associative, Commutative, Idempotent, and Distributed"_, whose goal is to succeed if the pieces of the work happen _"At least once, Anywhere in the system, In any order."_

Two smaller observations matter for a journal design. The bank-statement example (§6.2): _"Once it is issued, it is permanent and immutable. Errors in March's statement may be adjusted in April's statement but March's statement is never modified."_ And the operation-centric pattern (§6.5): record the operations the user asked for, not the resulting state, because _"operation-centric work can be made commutative (with the right operations and the right semantics) where a simple READ/WRITE semantic does not lend itself to commutativity."_

---

## Results

The laws that the analysis below relies on, as stated in the sources:

| Law                                                                  | Source             | Meaning                                                                                   |
| -------------------------------------------------------------------- | ------------------ | ----------------------------------------------------------------------------------------- |
| `(p⟨✓⟩, p′) ; (q, q′) = (pq, q′ ; p′)`                               | cCSP Definition 10 | Sequential composition installs compensations in reverse (LIFO)                           |
| `[P ÷ P′] = P`                                                       | cCSP §4            | Success discards the compensation                                                         |
| `[P ÷ P′ ; THROWW] = P ; P′`                                         | cCSP §4            | Failure after a committed step runs its compensation                                      |
| `[P ÷ P′ ; Q ÷ Q′ ; THROWW] = P ; Q ; Q′ ; P′`                       | cCSP §4            | Compensation of a sequence is the reverse sequence of compensations                       |
| `[(P ÷ P′ ‖ Q ÷ Q′) ; THROWW] = (P ‖ Q) ; (P′ ‖ Q′)`                 | cCSP §4            | Compensation of a parallel block is the parallel block of compensations, any interleaving |
| `[(P ÷ P′ ; Q ÷ Q′) ‖ THROWW] = SKIP □ (P ; P′) □ (P ; Q ; Q′ ; P′)` | cCSP §4            | An external interrupt lands only at yield points: before `P`, between, or after `Q`       |
| `THROW ‖ (YIELD ; P) = THROW □ P ; THROW`                            | cCSP §3.2          | Interrupts have no priority; an atomic step is never cut in half                          |
| `C[PP] ⊆ PP✓ □ SKIP` for self-cancelling `PP`                        | cCSP rule (2)      | A closed transaction either does its forward work or nothing observable                   |
| `A <S B ⟹ B⁻¹ <S A⁻¹`                                                | Bruni Definition 5 | The compensation order is the reverse of the saga order, and only that                    |
| Adequacy Theorem 1                                                   | Bruni §2.1         | Sequential sagas execute `A1..An` or `A1..A(k-1); B(k-1)..B1`, or stop at a failed `Bj`   |
| `PGM-CMP` installs `‖Q‖`, the forward flow of `Q`                    | Bruni §5.1         | A compensation never installs compensations and never terminates abnormally               |
| "At least once, anywhere, in any order"                              | Helland §8         | The retry contract a uniquifier buys: duplicates collapse, order is irrelevant            |

---

## Relevance to durable execution

### 1. Step identity and replay matching

Only Helland speaks to this, and he does so precisely: the identity of a unit of work is a _uniquifier_ that is _"functionally dependent only on the request as seen by the server system"_, carried by every retry, and used to collapse duplicates. Either the client supplies it or the server derives it deterministically from the request (his example is a hash of the whole request). The two calculi assume activity names are unique per instance (_"we consider any execution as a different instance of it and, hence distinguishable from all other instances"_, Bruni §2) and never say where the name comes from.

### 2. Journal versus world

This is where the three sources agree, and where they sharpen the journal-versus-world question. The calculi journal nothing about the world; the context `Γ` in Bruni's semantics, and the `cancel`/`independent` relations in cCSP, are _assumptions_ about what atomic activities do, supplied from outside. cCSP is blunt that the world cannot be captured: _"the real world cannot be check-pointed."_ Its cancellation semantics defines correctness _relative to a declared cancellation relation_, and the authors say so: _"The unrealism of this abstraction should be mitigated in engineering practice, by ensuring that failures with less desirable compensations are adequately rare."_ Helland then says what happens when the assumption fails: the journal is a _memory_, the action taken from it was a _guess_, and when the world is re-read and disagrees, the response is an _apology_, either code written for the anticipated cases or a human for the rest. On the concrete question of which wins, Helland is unambiguous: the world. A journal entry does not make the forklift un-run-over the book. What the journal is authoritative about is _what the program decided and did_; it is never authoritative about the world's current state, which must be re-observed.

### 3. Determinism enforcement

The calculi have no state, no variables, no data flow (Bruni's own list of omissions), so determinism is trivial in them and they enforce nothing. Helland argues the opposite of the durable-execution premise for _distributed_ replay: _"history cannot be exactly replayed"_ across replicas, so correctness has to come from commutative, idempotent operations rather than from replaying a single sequence. For a single-process journal replayed by the same process this is not a contradiction, but it is a warning about where replay stops being a strategy: as soon as two copies of the workflow can run.

### 4. Compensation and failure handling

The calculi settle the mechanics:

- **Registration** happens at the commit of the forward step, never before (cCSP Definition 11 gives an interrupted step an empty compensation; Bruni's `S-ACT` installs `B` only when `A` commits).
- **Order** is LIFO for sequence, by the law `(p✓, p′) ; (q, q′) = (pq, q′ ; p′)`; for parallel branches it is parallel, deliberately independent of the forward interleaving (Bruni: _"we want a semantics where compensations do not depend on the particular interleaving"_), and correctness under that policy needs the compensations to be independent (cCSP's side condition on `‖`).
- **Triggering** is by the transaction block, not by an explicit `reverse` call. Both papers reject StAC's explicit `accept`/`reverse` because it breaks compositionality.
- **A compensation must not install compensations** (Bruni's `PGM-CMP` over `REPEATED-COMP`) and **must not throw into further compensation**; a failed compensation is an abnormal termination handled by a separate exception mechanism (`try S with P`), which exists precisely because _"exception handling deals with incomplete compensations."_
- **Forward recovery is a different operator** (`try S or P`), used only during forward execution, never inside a compensation pass.
- **The last step's compensation is never run** (Bruni, after Theorem 1), as in the Sagas paper.
- **Interrupting siblings** is a policy choice with a cost: cCSP interrupts only at yield points; Bruni's revised semantics forces siblings to compensate as soon as one fails, but then needs the extra result states to track "forced" outcomes.

Helland supplies what the calculi leave out: what a compensation _is_ when the effect was external. It is a second forward action, addressed to whoever observed the first, and its success is probabilistic like everything else's.

### 6. Concurrency under replay

The parallel laws are the finding. cCSP: `[(P ÷ P′ ‖ Q ÷ Q′) ; THROWW] = (P ‖ Q) ; (P′ ‖ Q′)`, so the compensations of parallel branches are themselves a parallel block whose interleaving is unconstrained. Bruni's `<S` order says the same in relational form: nothing but the saga's own structure (sequence, nesting, and declared links) orders compensations. An engine that records the forward interleaving and replays compensations in exact reverse is implementing the BPEL policy that both papers argue against, and cCSP's independence side condition is the price of _not_ doing so. Helland's replicas-reordering-work is the extreme case, where even the forward order is not fixed.

### 8. Testing

Absent in all three. The calculi offer proofs of adequacy in place of tests; Helland offers business judgement (_"What's your stomach for risk?"_, §5.5). Neither says how to test that a specific compensation actually cancels a specific forward action; cCSP's `cancel(A, A°)` is an axiom the programmer asserts.

### 9. Journal integrity and the single writer

**The calculi are silent, and the silence is principled.** cCSP and the sagas calculi
are trace semantics over processes; they have no store, no log and therefore no
integrity question. What they do supply is the constraint that makes the question
matter: because _"the real world cannot be check-pointed"_, a compensation is
reasoning about a world that has already been observed, so the record of what was
done is the only thing the program has.

**Helland's half of the page does bear on it**, through the requirement that a
compensating message carry a uniquifier of its own. A compensation retried after a
crash is a duplicate message like any other, and must be recognised as one — which
means a library must give each compensation an identity, not only each forward step.

### 10. Operator recovery and intervention

**Abnormal termination is a distinct outcome, and that is the contribution.** In the
sagas calculi a compensation that itself fails does not produce ordinary failure; it
produces a separate abnormal result that the enclosing handler must deal with. A
library that folds "the step failed" and "the rollback failed" into one error has
lost the distinction an operator most needs.

**Compensations are flat.** The calculi forbid compensating a compensation:
rollback is retried forward, never itself rolled back. That is what keeps recovery
bounded, and it is a rule a library must enforce rather than document.

**Forward recovery is a separate operator.** cCSP's alternative construct resumes
rather than rolls back, and it is distinct from compensation both syntactically and
semantically — so "retry this step" and "undo everything before it" are different
choices, available at the same point.

**Helland's apology is the endpoint.** When neither forward nor backward recovery is
available, the remaining move is outside the system: notify someone, and record that
you did. That is the boundary of automated intervention, stated as a design
position rather than as a failure.

---

## Implications for a durable-execution library

- **Compensations of concurrent steps are themselves concurrent, and their order does
  not follow the observed interleaving.** The law is explicit, and it contradicts the
  intuitive reading that rollback reverses the sequence things actually happened in.
  A library that reverses an execution trace is implementing a different, stronger
  and unnecessary guarantee.
- **Register a compensation only when the forward action commits.** The pairing
  operator installs the compensation at completion, which is the same conclusion the
  Sagas paper reaches and the opposite of registering it optimistically before the
  action runs.
- **Sequential composition installs compensations in reverse, and that law is what
  LIFO means.** Stating it as an algebraic property rather than as an implementation
  detail is what makes it checkable.
- **Compensation must be flat.** No compensating a compensation: rollback is retried
  forward. A library that allows nesting here cannot bound its recovery.
- **"The rollback failed" is a different outcome from "the step failed."** Give it a
  distinct terminal state, because it is the case that requires a person.
- **Forward recovery needs its own operator**, distinct from compensation and
  available at the same point, so that retrying a step and undoing everything before
  it are separate decisions rather than one policy.
- **Correctness is relative to a declared cancellation relation.** The calculi make
  `cancel(A, A°)` an axiom the programmer asserts, which means a library cannot verify
  that a compensation actually compensates — it can only give the author a place to
  say so, and a test harness a place to check it.
- **The real world cannot be check-pointed**, so the record of what was done is the
  only ground a compensation stands on. That is the argument for journaling effects
  rather than state.

---

## Sources

- Butler, M., Hoare, T., Ferreira, C., "A trace semantics for long-running transactions", in _Communicating Sequential Processes: The First 25 Years_, LNCS 3525, Springer, 2005: [DOI `10.1007/11423348_8`][ccsp-doi]; the author copy read for this page is the [Southampton ePrints PDF][ccsp-pdf] (dated January 2005).
- Bruni, R., Melgratti, H., Montanari, U., "Theoretical foundations for compensations in flow composition languages", POPL 2005: [DOI `10.1145/1040305.1040323`][bruni-doi]; the author copy read for this page is linked from [Hernán Melgratti's publication page][bruni-pdf].
- Bruni, R., Butler, M., Ferreira, C., Hoare, T., Melgratti, H., Montanari, U., "Comparing Two Approaches to Compensable Flow Composition", CONCUR 2005: [DOI `10.1007/11539452_30`][compare-doi] (cited as the follow-up; not read for this page).
- Helland, P., Campbell, D., "Building on Quicksand", CIDR 2009: [arXiv `0909.1788`][helland-abs], [PDF][helland-pdf].
- Related pages in this catalog: [Sagas (SIGMOD 1987)][sagas], [catalog index][index], [`sparkles:event-horizon` spec][eh-spec].

<!-- References -->

[ccsp-doi]: https://doi.org/10.1007/11423348_8
[ccsp-pdf]: https://eprints.soton.ac.uk/260080/1/comptraces.pdf
[bruni-doi]: https://doi.org/10.1145/1040305.1040323
[bruni-pdf]: http://groups.di.unipi.it/~melgratt/
[compare-doi]: https://doi.org/10.1007/11539452_30
[helland-abs]: https://arxiv.org/abs/0909.1788
[helland-pdf]: https://arxiv.org/pdf/0909.1788
[sagas]: ./sagas.md
[index]: ./index.md
[eh-spec]: ../../../specs/event-horizon/SPEC.md
