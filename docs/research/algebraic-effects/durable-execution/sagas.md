# Sagas (SIGMOD 1987)

The paper that named the pattern every durable-execution engine's "compensation" feature descends from: a long-lived transaction becomes a sequence of ordinary transactions plus a compensating transaction for each, and the system promises that either the whole sequence commits or the compensations run backwards over whatever did.

| Field        | Value                                                                                                                                                |
| ------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Hector Garcia-Molina, Kenneth Salem (Princeton University)                                                                                           |
| Venue / year | ACM SIGMOD International Conference on Management of Data, 1987, pages 249–259                                                                       |
| DOI or URL   | [`10.1145/38713.38742`][doi] · scanned copy read for this page: [Cornell CS711 mirror][pdf]                                                          |
| Category     | theory                                                                                                                                               |
| Grounds      | 1 (step identity), 2 (journal versus world), 3 (determinism), 4 (compensation), 5 (versioning), 6 (concurrency), 7 (replay or snapshot); 8 is absent |

**Last reviewed:** September 12, 2026.

The sibling page [Compensation calculi for long-running transactions][calculi] follows the idea forward into the process-algebra treatments (cCSP, Bruni et al.'s sagas calculus) and Helland's "memories, guesses, and apologies". The umbrella for both is the [durable-execution catalog index][index].

---

## What it establishes

The paper starts from a database-systems problem: a _long lived transaction_ (LLT) that runs for hours or days holds locks on everything it touches until it commits, blocking short transactions and raising the deadlock and abort rate. The proposal is to give up atomicity at the outer level in exchange for a weaker but still useful guarantee. From the abstract ([`10.1145/38713.38742`][doi]):

> _"Long lived transactions (LLTs) hold on to database resources for relatively long periods of time, significantly delaying the termination of shorter and more common transactions. To alleviate these problems we propose the notion of a saga. A LLT is a saga if it can be written as a sequence of transactions that can be interleaved with other transactions. The database management system guarantees that either all the transactions in a saga are successfully completed or compensating transactions are run to amend a partial execution."_

Three definitions carry the rest of the paper (all from §1):

- **Saga.** _"Let us use the term saga to refer to a LLT that can be broken up into a collection of sub-transactions that can be interleaved in any way with other transactions. Each sub-transaction in this case is a real transaction in the sense that it preserves database consistency. However, unlike other transactions, the transactions in a saga are related to each other and should be executed as a (non-atomic) unit: any partial executions of the saga are undesirable, and if they occur, must be compensated for."_
- **Compensating transaction.** Each `Ti` is paired with a `Ci`. _"The compensating transaction undoes, from a semantic point of view, any of the actions performed by `Ti`, but does not necessarily return the database to the state that existed when the execution of `Ti` began."_
- **The guarantee.** _"Once compensating transactions `C1`, `C2`, ..., `Cn-1` are defined for saga `T1`, `T2`, ..., `Tn`, then the system can make the following guarantee: Either the sequence `T1`, `T2`, ..., `Tn` (which is the preferable one) or the sequence `T1`, `T2`, ..., `Tj`, `Cj`, ..., `C2`, `C1`"_ for some `j` below `n` will be executed.

Note the index bound: the last sub-transaction needs no compensation. §3 makes it explicit: _"if an end-saga command ends both the last transaction and the saga, there is no need to have a compensating transaction for the last transaction."_ Once `Tn` commits there is nothing left that could fail and trigger backward recovery.

The paper is careful about what the guarantee does **not** say. The parenthetical right after it (§1): _"Note that other transactions might see the effects of a partial saga execution. When a compensating transaction `Cj` is run, no effort is made to notify or abort transactions that might have seen the results of `Tj` before they were compensated for by `Cj`."_ Isolation at the saga level is gone by design, and that is the price of releasing locks early.

### Semantic, not physical, undo

The airline example in §1 is the canonical statement of why compensation is not rollback:

> _"In our airline example, if `Ti` reserves a seat on a flight, then `Ci` can cancel the reservation (say by subtracting one from the number of reservations and performing some other checks). But `Ci` cannot simply store in the database the number of seats that existed when `Ti` ran because other transactions could have run between the time `Ti` reserved the seat and `Ci` canceled the reservation, and could have changed the number of reservations for this flight."_

A compensation is a new forward action that cancels the _meaning_ of the original, computed against the current state of the world, not a restore of a before-image. §9 pushes the point to its limit: _"Designing compensating transactions for LLTs is a difficult problem in general. (For instance, if a transaction fires a missile, it may not be possible to undo this action.)"_ And the same section shows how far "semantic undo" stretches when physical undo is impossible: _"to compensate for the letter, send a second letter explaining the problem. To compensate for the check, send a stop-payment message to the bank."_ The compensation for an observed effect is a second observed effect, which is exactly Helland's "apology" two decades later (see the [sibling page][calculi]).

### Relation to nested transactions

The paper positions sagas against Moss/Lynch nested transactions (§1): _"a saga is like a nested transaction [...], except that (a) A saga only permits two levels of nesting: the top level saga and simple transactions, and (b) At the outer level full atomicity is not provided. That is, sagas may view the partial results of other sagas."_ There is no general recursive "saga of sagas" in this paper; the hierarchy is exactly two deep, and it is the later process-calculus work that generalises transaction blocks to arbitrary nesting.

---

## The model

### User-facing commands

§2 defines the application's interface as a small command vocabulary layered on a conventional transaction monitor: `begin-saga` (returns a saga identifier), `begin-transaction` / `end-transaction`, `abort-transaction` (aborts the current sub-transaction, not the saga), `abort-saga`, `end-saga`, and an optional `save-point`. The important detail is _when_ and _how_ the compensation is registered:

> _"Each `end-transaction` call includes the identification of the compensating transaction that must be executed in case the currently ending transaction must be rolled back. The identification includes the name and entry point of the compensating program, plus any parameters that the compensating transaction may need."_

So compensation is registered at the moment the forward step commits, by name plus entry point plus captured arguments, and it is recorded in the log, not held in process memory. The alternative the paper allows (§3) is that _"each transaction store in the database the parameters that its compensating transaction may need in the future"_. Two further rules bound what a compensation may do: _"Abort-transaction and abort-saga commands are not allowed within a compensating transaction"_ (§2), so compensations cannot themselves trigger compensation, and _"We assume that each compensating program includes its own `begin-transaction` and `end-transaction` calls"_, so a compensation is itself atomic.

### The saga execution component and its log

§4 introduces the runtime: _"Within the DBMS, a saga execution component (SEC) manages sagas. This component calls on the conventional transaction execution component (TEC), which manages the execution of the individual transactions."_ The SEC is a layer above atomic transactions, and it is journal-driven:

> _"All saga commands and database actions are channeled through the SEC. Each saga command (e.g., begin-saga) is recorded in the log before any action is taken. Any parameters contained in the commands (e.g., the compensating transaction identification in an end-transaction command) are also recorded in the log."_

The log is write-ahead for saga commands (recorded _before_ the action) and shared with the transaction log. The SEC needs no concurrency control of its own _"because the transactions it controls can be interleaved with other transactions"_.

### Backward recovery

On `abort-saga`, or after a crash with a saga that has a `begin-saga` but no `end-saga` entry, the SEC compensates in reverse. The crash path (§4):

> _"After a crash, the TEC is first invoked to clean up pending transactions. Once all transactions are either aborted or committed, the SEC evaluates the status of each saga. If a saga has corresponding begin-saga and end-saga entries in the log, then the saga completed and no further action is necessary. If there is a missing end-saga entry, then the saga is aborted. By scanning the log the SEC discovers the identity of the last successfully executed and uncompensated transaction. Compensating transactions are run for this transaction and all preceding ones."_

Two layers of undo appear here. The in-flight sub-transaction is rolled back _physically_ by the TEC (before-images from the log), because it never committed. Everything that did commit is undone _semantically_ by running its `Ci`. The SEC records its abort decision in the log before starting _"to protect against a crash during roll back"_, and the compensations' own begin/commit records let a second crash resume the backward pass where it stopped.

### Forward recovery and save-points

§5 gives the alternative: _"When a failure interrupts a saga, there are two choices: compensate for the executed transactions, backward recovery, or execute the missing transactions, forward recovery. (Of course, forward recovery may not be an option in all situations.) For backward recovery the system needs compensating transactions; for forward recovery it needs save-points."_

A save-point _"forces the system to save the state of the running application program and returns a save-point identifier for future reference"_ (§2). Recovery then becomes a hybrid the paper calls _backward/forward recovery_: compensate back to the latest save-point, restore the program state, re-run from there. §2 spells out the consequence for what counts as a valid execution, using a saga with a save-point after `T1` that crashes after `T2`, restarts, and crashes again after `T5`: the observed sequence is `T1, T2, C2, T2, T3, T4, T5, C5, C4, T4, T5, T6`, and _"our definition of valid execution sequences given above must be modified to include such sequences. If these partial recovery sequences are not valid, then the system should either not take save-points, or it should take them automatically at the beginning (or end) of every transaction."_

Pure forward recovery is the degenerate case where every step is retried until it succeeds:

> _"In this case the SEC becomes a simple 'persistent' transaction executor, similar to persistent message transmission mechanisms. After every crash, for every active saga, the SEC instructs the TEC to abort the last executing transaction, and then restarts the saga at the point where this transaction had started."_

The footnote attached to this mode is the paper's retry assumption in full: _"In this case we must also assume that every sub-transaction in the saga will eventually succeed if it is retried enough times."_ Retriability is a precondition of forward recovery, not a property the paper proves.

### The restricted model: a saga as a script

§5 also proposes the model that a durable-execution engine will recognise as its own:

> _"We can simplify this further if we simply view a saga as a file containing a sequence of calls to individual transaction programs. Here there is no need for explicit begin or end saga nor begin or end transaction commands. The saga begins with the first call in the file and ends with the last one. Furthermore, each call is a transaction. The state of a running saga is simply the number of the transaction that is executing. This means that the system can take save-points after each transaction with very little cost."_

With static control flow, the whole "program state" that a save-point has to capture collapses to a step index. The paper then names its own ancestry: _"the transaction file model described above could be called an EXEC (or a SCRIPT or a BATCH). However, all EXEC facilities we know of are not persistent in our sense (e.g., a failed EXEC may simply be restarted at the beginning, without compensation)."_

### When compensation itself fails

§6 drops the assumption that compensations are bug-free:

> _"But what happens if a compensating transaction cannot be successfully completed due to errors (e.g., it tries to read a file that does not exist, or there is a bug in the code)? The transaction could be aborted, but if it were run again it would probably encounter the same error. In this case, the system is stuck: it cannot abort the transaction nor can it complete it."_

The answers offered are recovery blocks (an alternate implementation of the same step or compensation: _"compensating transactions can be given alternates as well to make aborting sagas more reliable"_) and manual repair, about which the paper is candid: _"Relying on manual intervention is definitely not an elegant solution, but it is a practical one."_ While a step is being repaired the saga holds no locks, so a stuck saga costs nothing but its own latency.

### Saving code reliably

§3 raises an issue that most later systems rediscover as "versioning": _"To complete a running saga after a crash it is necessary to either complete the missing transactions or to run compensating transactions to abort the saga. In either case it is essential to have the required application code."_ A conventional DBMS can recover from its own log without application code; a saga system cannot, because the compensations _are_ application code. The proposals are to manage saga programs like system code (versioned, backed up, outside the DBMS) or to store the code as database objects, in which case _"the first transaction of the saga, `T1`, enters into the database all further transactions (compensating or not) that may be needed in the future"_.

### Parallel sagas

§8 extends the sequence to a fork/join tree of processes and gives the compensation-order rule:

> _"Within each process of the parallel saga, transactions are compensated for (or undone) in reverse order just as with sequential sagas. In addition, all compensations in a child process must occur before any compensations for transactions in the parent that were executed before the child was created (forked). (Note that only transaction execution order within a process and fork and join information constrain the order of compensation. If `T1` and `T2` have executed in parallel processes and `T2` has read data written by `T1`, compensating for `T1` does not force us to compensate for `T2` first.)"_

Data dependencies between branches do not order compensations; only the fork/join structure does. Save-points in parallel sagas can be inconsistent (a child's save-point taken after a parent transaction that is later compensated), which the paper identifies as _"cascading roll backs"_ and resolves by choosing _"the latest save-point within each process of the saga such that no earlier transaction has been compensated for"_.

---

## Results

The paper is a systems-design paper, not a theorem paper; its results are the guarantee and a set of implementation claims.

- **The saga guarantee** (above): every execution is either `T1..Tn` or `T1..Tj, Cj..C1`, extended to the backward/forward sequences when save-points are used.
- **No new concurrency control.** The SEC is purely a logging and recovery layer over an existing transaction manager.
- **Implementable without DBMS changes** (§7): the saga commands become subroutines that write saga status to ordinary tables, plus a _saga daemon_ that _"would always be active. It would be restarted after a crash by the operating system. After a crash it would scan the saga tables to discover the status of pending sagas."_ The constraint is that status writes _"must always be performed within a transaction, else the information may be lost in a crash."_
- **A design rule for splitting LLTs** (§9): _"The database and the LLTs should be designed so that data passed from one sub-transaction to the next via local storage is minimized."_ Intermediate state that lives only in the program's memory is precisely what a save-point has to capture; state that lives in the database is already durable.

---

## Relevance to durable execution

### 1. Step identity and replay matching

A step is a sub-transaction bracketed by `begin-transaction` / `end-transaction` records in the SEC log, and the log is the only thing consulted on recovery: the SEC _"discovers the identity of the last successfully executed and uncompensated transaction"_ by scanning it. In the restricted script model the identity is positional: _"The state of a running saga is simply the number of the transaction that is executing."_ There is no notion of matching a step's _content_ against the log; the log is the sequence, and position is identity. That is the weakest form of step identity in this catalog, and it is only sound because the script's control flow is static.

### 2. Journal versus world

The log is authoritative about _which_ steps ran and committed; the TEC's atomicity guarantees that a `begin`/`end` pair in the log corresponds to a committed effect. But the paper is explicit that the world keeps moving between a step and its compensation, and that the compensation must read the current state rather than trust what the step saw: _"other transactions could have run between the time `Ti` reserved the seat and `Ci` canceled the reservation"_. Disagreement is not detected; it is assumed, and compensation is defined so as to be correct despite it. The paper therefore never faces a "journal says X, world says Y" reconciliation, because it journals only step boundaries, never observations.

### 3. Determinism enforcement

Nothing in the language enforces determinism. The general model permits arbitrary computation between sub-transactions (_"the application can perform operations that do not involve access to the database, such as manipulation of local variables"_) and pays for it with save-points that snapshot program state. The restricted model achieves deterministic resumption by construction: a static list of transaction calls has no control flow to replay. Determinism is thus enforced by the shape of the program (discipline), and the runtime's save-point mechanism is what covers the non-deterministic remainder.

### 4. Compensation and failure handling

This is the paper's subject. Compensations are: registered explicitly, per step, at step commit (`end-transaction` carries the compensation's name, entry point and arguments); persisted in the log; triggered by `abort-saga` or by a crash that leaves a saga without `end-saga`; run strictly in reverse order within a sequential saga (reverse order per process, children before the parent's pre-fork steps, in parallel sagas); themselves atomic transactions; forbidden from aborting; and permitted to fail, in which case the system is _"stuck"_ and the paper reaches for alternates or a human. The last step of a saga is exempt from needing one. The semantics is semantic undo against current state, never physical restore.

### 5. Versioning against old histories

§3 ("Saving code reliably") is the versioning question in 1987 dress: the code that a compensation names in the log must still exist and still be runnable when the log is replayed, possibly long after the saga started. The paper's mitigations are procedural (treat saga code like system code, or store the code in the database at `T1` time so it is versioned with the saga instance). It does not consider a saga whose forward code has changed since it began.

### 6. Concurrency under replay

Parallel sagas (§8) give the ordering rule: compensation is reverse-per-process plus fork/join constraints, and nothing else. Recovery of a parallel saga requires the SEC to have logged every fork and join, and forward recovery needs a consistent cut of save-points across processes, which is the classic cascading-rollback problem. There is no notion of replaying interleavings; each process's log is independent except at fork/join points.

### 7. Replay or snapshot

Both, and the paper is the earliest clear statement of the trade. Save-points are snapshots of application state and cost _"large unstructured objects"_ in the DBMS. The restricted model removes them by making the step counter the entire state. Pure forward recovery is replay-free resumption: re-run the interrupted step from its beginning, never anything earlier. The paper does not consider re-executing _completed_ steps deterministically, which is the replay strategy most modern engines use; every completed step here is committed and skipped by construction.

### 8. Testing

Absent. The paper contains no testing methodology, no fault-injection discussion and no experiments. Absence is the finding: the saga guarantee is stated as a property of the SEC's log protocol and assumed to hold.

---

## Relevance to sparkles

- **Confirms the journal-as-authority design.** The SEC log is exactly a `started` + `completed` journal with write-ahead command records; the release rewrite's `journal.jsonl` is the saga daemon's tables under another name. Its "scan the tables after a crash" recovery is the resume path the design already specifies.
- **Confirms explicit, LIFO compensation, and sharpens _when_ to register.** The paper registers a compensation at `end-transaction`, with its arguments captured and logged at that moment. The sparkles design says compensations are registered on a scope, LIFO, explicit-only; the saga rule adds that registration should happen at step _completion_ with a stable name plus serialised arguments in the journal, not as a closure held in memory, so that a resumed process can run a compensation it never saw registered.
- **Argues against compensating on every failure.** The paper's pure-forward mode (retry until success, no compensation) is a first-class recovery policy, and §9 recommends designing away user-initiated aborts so compensation is never needed. For `release`, most steps (tag, push, publish) are retriable-forward; the design should classify steps as forward-recoverable versus compensable rather than defaulting to backward recovery.
- **Semantic undo means compensations must re-observe the world.** `Ci` reads current state, never the before-image. A compensation that deletes a tag must check the tag still points where the step left it; the design's "observations are re-observed and reconciled" rule must apply inside compensations too, not only on the forward path.
- **The world-mutation test the design plans is the paper's own model.** "Other transactions might see the effects of a partial saga execution" is the assumption that makes crash-then-mutate-then-resume a necessary test, and the paper offers no test of its own. That gap is what the design's crash-at-every-event-index plus mutate-the-world tests fill.
- **What the design lacks: a rule for a stuck compensation.** §6's "the system is stuck" case (a compensation that fails deterministically) has no answer in the current design. The paper's options are an alternate compensation or handing the saga to a human with a description of the error; the journal's UI projection should have a state for "compensation failed, needs operator", and `release` already has the confirmation-gate machinery to surface it.
- **What the design lacks: the last step is exempt.** The final effect of a workflow needs no compensation because nothing after it can fail. Registering one anyway is dead code that can never be exercised by a test.
- **Save-point cost supports "no continuation capture".** The paper's snapshots are expensive precisely because they capture arbitrary program state. The restricted model, where state is a step index, is what a tail-resumptive effect row with journaled ops amounts to. The `event-horizon` decision not to capture continuations is the 1987 restricted model, and this paper is the earliest argument for it.

---

## Sources

- Garcia-Molina, H. and Salem, K., "Sagas", SIGMOD 1987: [DOI `10.1145/38713.38742`][doi]; the scanned PDF read for this page is the [Cornell CS 711 course mirror][pdf].
- Related pages in this catalog: [Compensation calculi for long-running transactions][calculi], [catalog index][index], [`sparkles:event-horizon` spec][eh-spec], [`release` spec][release-spec].

<!-- References -->

[doi]: https://doi.org/10.1145/38713.38742
[pdf]: https://www.cs.cornell.edu/andru/cs711/2002fa/reading/sagas.pdf
[calculi]: ./compensation-calculi.md
[index]: ./index.md
[eh-spec]: ../../../specs/event-horizon/SPEC.md
[release-spec]: ../../../specs/release/SPEC.md
