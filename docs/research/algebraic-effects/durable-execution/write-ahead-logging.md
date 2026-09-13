# Write-ahead logging (ARIES)

The 1992 ARIES paper is the canonical statement of the discipline every durable-execution journal quietly reuses: write the intent to stable storage before the effect, tag the world with the identity of the last logged change so redo can be repeated safely, and log the undo too, so that a crash during recovery is just another crash.

| Field        | Value                                                                                                                                                                                                                                                  |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Authors      | C. Mohan, Don Haderle, Bruce Lindsay, Hamid Pirahesh, Peter Schwarz (IBM Almaden)                                                                                                                                                                      |
| Venue / year | _ACM Transactions on Database Systems_ 17(1), pp. 94–162, March 1992                                                                                                                                                                                   |
| DOI or URL   | [`10.1145/128765.128770`][aries-doi]; text read from the Stanford CS345 course mirror of the TODS PDF ([`aries.pdf`][aries-pdf])                                                                                                                       |
| Secondary    | PostgreSQL 18 documentation, [§28.3 Write-Ahead Logging (WAL)][pg-wal-intro] and [§28.6 WAL Internals][pg-wal-internals], as the living example                                                                                                        |
| Category     | theory                                                                                                                                                                                                                                                 |
| Grounds      | 1 (step identity: LSN and `page_LSN`), 2 (journal versus world: conditional redo), 3 (determinism: physical redo needs none), 4 (compensation: CLRs and `UndoNxtLSN`), 6 (concurrency: per-page order only), 7 (checkpoints), 8 (crash during restart) |

**Last reviewed:** September 12, 2026.

---

## What it establishes

ARIES ("Algorithm for Recovery and Isolation Exploiting Semantics") is a recovery method for a database that updates pages in place and keeps one append-only log. Its contribution is not the log itself, which predates it, but a set of rules that make recovery correct under fine-granularity locking, partial rollbacks and repeated crashes, and provably bounded in the amount of logging recovery itself generates. The abstract states the two ideas the rest of the paper defends ([`aries.pdf`][aries-pdf], p. 94):

> _"We introduce the paradigm of repeating history to redo all missing updates before performing the rollbacks of the loser transactions during restart after a system failure. ARIES uses a log sequence number in each page to correlate the state of a page with respect to logged updates of that page. All updates of a transaction are logged, including those performed during rollbacks. By appropriate chaining of the log records written during rollbacks to those written during forward progress, a bounded amount of logging is ensured during rollbacks even in the face of repeated failures during restart or of nested rollbacks."_

Four definitions carry the paper.

**The WAL protocol.** Section 1.1 gives the rule in the form every later system quotes ([`aries.pdf`][aries-pdf], p. 97):

> _"The WAL protocol asserts that the log records representing changes to some data must already be on stable storage before the changed data is allowed to replace the previous version of that data on nonvolatile storage. That is, the system is not allowed to write an updated page to the nonvolatile storage version of the database until at least the undo portions of the log records which describe the updates to the page have been written to stable storage."_

The rule has a second half that is easy to forget: commit is also gated on the log. _"Transaction status is also stored in the log and no transaction can be considered complete until its committed status and all its log data are safely recorded on stable storage by forcing the log up to the transaction's commit log record's LSN."_ (§1.1). So the undo portion must be stable before the effect, and the redo portion must be stable before the effect is promised.

**LSN.** _"Address of the first byte of the log record in the ever-growing log address space. This is a monotonically increasing value."_ (§4.1). A log record's identity is its position; nothing else names it.

**`page_LSN`.** _"One of the fields in every page of the database is the page_LSN field. It contains the LSN of the log record that describes the latest update to the page. This record may be a regular update record or a CLR. ARIES expects the buffer manager to enforce the WAL protocol."_ (§4.2). The world, that is, the data page, carries the identity of the last logged change applied to it.

**CLR.** A compensation log record: _"In many WAL-based systems, the updates performed during a rollback are logged using what are called compensation log records (CLRs). Whether a CLR's update is undone, should that CLR be encountered during a rollback, depends on the particular system. As we will see later, in ARIES, a CLR's update is never undone and hence CLRs are viewed as redo-only log records."_ (§1.1).

PostgreSQL states the same protocol in one sentence, which is worth having next to the original ([PostgreSQL §28.3][pg-wal-intro]):

> _"WAL's central concept is that changes to data files (where tables and indexes reside) must be written only after those changes have been logged, that is, after WAL records describing the changes have been flushed to permanent storage."_

---

## The model

### Log records

Section 4.1 lists the fields of a log record. The ones that matter for the recovery argument:

| Field        | Meaning (§4.1)                                                                                                                                                                                                                         |
| ------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `LSN`        | Position in the log; monotonically increasing. Not stored in the record itself.                                                                                                                                                        |
| `Type`       | `update`, `compensation`, a commit-protocol record such as `prepare`, or a non-transaction record.                                                                                                                                     |
| `TransID`    | The transaction that wrote the record.                                                                                                                                                                                                 |
| `PrevLSN`    | LSN of the previous record written by the same transaction; zero for the first, so no explicit begin record is needed.                                                                                                                 |
| `PageID`     | The page the update touched (update and compensation records only).                                                                                                                                                                    |
| `UndoNxtLSN` | _"Present only in CLRs. It is the LSN of the next log record of this transaction that is to be processed during rollback. That is, UndoNxtLSN is the value of PrevLSN of the log record that the current log record is compensating."_ |
| `Data`       | Redo and/or undo data. _"CLRs contain only redo information since they are never undone."_                                                                                                                                             |

Every record of a transaction is chained backwards through `PrevLSN`. A CLR additionally skips: its `UndoNxtLSN` points past the record it compensated to that record's predecessor. Figure 5 of the paper draws the chain: after actions 1, 2, 3 and a rollback of 3 and 2, the log reads `1 2 3 3' 2'`, where `3'` points at 2 and `2'` points at 1.

### Two tables rebuilt at restart

The **transaction table** (§4.3) holds, per active transaction, `TransID`, `State` (prepared or unprepared), `LastLSN`, and `UndoNxtLSN`, the next record to process during rollback. The **dirty pages table** (§4.4) holds, per page that may be newer in the buffer pool than on disk, `PageID` and `RecLSN`, _"the current end-of-log LSN"_ at the moment the page was first dirtied. `RecLSN` is a lower bound: no update to that page logged before it can be missing from disk. Both tables are written into every checkpoint record, and ARIES checkpoints are _fuzzy_: they record the tables, not the pages, so taking one does not quiesce the system.

### Physical redo, logical undo

The paper distinguishes page-oriented from logical recovery (§1.1):

> _"Page-oriented redo is said to occur if the log record whose update is being redone describes which page of the database was originally modified during normal processing and if the same page is modified during the redo processing. No internal descriptors of tables or indexes need to be accessed to redo the update. That is, no other page of the database needs to be examined."_

and chooses one of each: _"In the interest of efficiency, ARIES supports page-oriented redo and it supports, in the interest of high concurrency, logical undos."_ A logical undo may touch a different page than the forward action did (the paper's example is a key moved by a B-tree split performed by another transaction). Since a logical undo is real work with its own effects, it must be logged as a CLR, and that CLR is page-oriented and redo-only. This mix is what Gray and Reuter later named _physiological_ logging; Helland uses that name for it when he borrows the idea in the [idempotence page][idempotence].

### The three restart passes

Section 3 describes restart recovery as three sequential scans of the log:

1. **Analysis.** _"ARIES first scans the log, starting from the first record of the last checkpoint, up to the end of the log. During this analysis pass, information about dirty pages and transactions that were in progress at the time of the checkpoint is brought up to date as of the end of the log. The analysis pass uses the dirty pages information to determine the starting point (RedoLSN) for the log scan of the immediately following redo pass. The analysis pass also determines the list of transactions that are to be rolled back in the undo pass."_ Nothing is applied to the world during analysis; it only rebuilds the two tables.

2. **Redo, which repeats history.** The principle, verbatim (§3):

   > _"Then, during the redo pass, ARIES repeats history, with respect to those updates logged on stable storage, but whose effects on the database pages did not get reflected on nonvolatile storage before the failure of the system. This is done for the updates of all transactions, including the updates of those transactions that had neither committed nor reached the in-doubt state of two-phase commit by the time of the system failure (i.e., even the missing updates of the so-called loser transactions are redone). This essentially reestablishes the state of the database as of the time of the system failure. A log record's update is redone if the affected page's page_LSN is less than the log record's LSN. No logging is performed when updates are redone."_

   Redo is conditional on `page_LSN`, and it writes nothing to the log.

3. **Undo.** Loser transactions are rolled back _"in reverse chronological order, in a single sweep of the log"_ by repeatedly taking the maximum `UndoNxtLSN` across the transaction table. Undo is unconditional: _"Unlike during the redo pass, performing undos is not a conditional operation during the undo pass (and during normal undo). That is, ARIES does not compare the page_LSN of the affected page to the LSN of the log record to decide whether or not to undo the update."_ It does not need to, because history was repeated first. Each undone record produces a CLR, and _"when a CLR is encountered during undo, it is used just to determine the next log record to process by looking at the UndoNxtLSN field of the CLR."_

PostgreSQL's recovery is the redo pass of this scheme with the undo pass made unnecessary by its multi-version storage ([PostgreSQL §28.6][pg-wal-internals]): _"at the start of recovery, the server first reads pg_control and then the checkpoint record; then it performs the REDO operation by scanning forward from the WAL location indicated in the checkpoint record."_ Its LSN is the same object: _"a byte offset into the WAL, increasing monotonically with each new record."_

---

## Results

The paper's claims are engineering guarantees rather than theorems, but they are precise and the counter-examples are worked out.

**Repeating history is necessary, not an optimization.** Section 10.1 shows that _selective redo_ (redoing only committed transactions' updates, as System R and DB2 did) breaks under record-level locking: a loser's update at LSN 20 and a committed update at LSN 30 on the same page leave `page_LSN` at 30 whether or not update 20 is present, so the undo pass can no longer tell. _"By not repeating history, the page_LSN is no longer a true indicator of the current state of the page."_ The general principle is stated in §2: _"An undo or a redo of an update should not be performed without being sure that the original update is present or is not present, respectively."_

**Redo is idempotent because the world carries the LSN.** _"The LSN concept lets us avoid attempting to redo an operation when the operation's effect is already present in the page. It also lets us avoid attempting to undo an operation when the operation's effect is not present in the page."_ (§2). A crash after a redone page is written and before the next one simply makes the next restart skip it.

**Undo is idempotent because it is logged.** The CLR chain gives restart a resume point inside a rollback (§3):

> _"Thus, during rollback, the UndoNxtLSN field of the most recently written CLR keeps track of the progress of rollback. It tells the system from where to continue the rollback of the transaction, if a system failure were to interrupt the completion of the rollback or if a nested rollback were to be performed. It lets the system bypass those log records that had already been undone."_

Section 10.1 adds the case that motivates writing a CLR even when the page did not need the undo: _"Writing the CLR when an undo is not actually performed on the page turns out to be necessary also when handling a failure of the system during restart recovery."_ Without it, a second restart would see the page's advanced `page_LSN` and attempt the undo again.

**Logging during recovery is bounded.** Feature (15) in the §12 summary: _"Bounded logging during restart in spite of repeated failures or of nested rollbacks. Even if repeated failures occur during restart, the number of CLRs written is unaffected. This is also true if partial rollbacks are nested. The number of log records written will be the same as that written at the time of transaction rollback during normal processing. The latter again is a fixed number and is, usually, equal to the number of undoable records written during the forward processing of the transaction. No log records are written during the redo pass of restart."_ The paper contrasts systems that compensate compensations, where _"in the worst case, the number of log records written during repeated restart failures grows exponentially"_ (§11).

**Redo parallelizes per page.** Section 6.2: _"Updates to different pages may get applied in different orders from the order represented in the log. This does not violate any correctness properties since for a given page all its missing updates are reapplied in the same order as before."_

**The cost.** Every page needs an LSN field; every rollback writes as many CLRs as it undoes records; redo may dirty pages of losers only to undo them again (the paper acknowledges this and points to later work on restricting it). PostgreSQL's numbers put the trade in perspective ([§28.3][pg-wal-intro]): _"Using WAL results in a significantly reduced number of disk writes, because only the WAL file needs to be flushed to disk to guarantee that a transaction is committed, rather than every data file changed by the transaction."_

---

## Relevance to durable execution

A durable-execution journal is a WAL whose "pages" are the outside world and whose "transactions" are workflow scopes. Read that way, the paper answers six of the eight survey questions directly.

### 1. Step identity and replay matching

ARIES identifies a logged change by log position, and nothing else. There is no name, no argument hash: the LSN is the identity, and the `PrevLSN` chain turns a flat log into per-transaction histories. Matching on replay is then a comparison of two LSNs, one in the log and one stamped on the world. A durable journal that keys steps by name plus attempt plus argument hash is doing with content what ARIES does with position; the content key is needed only because the world it acts on carries no `page_LSN`.

### 2. Journal versus world

The paper's answer is unambiguous: the journal wins about _what was attempted_, the world wins about _what happened_, and the tie-break is the `page_LSN`. Redo is conditional on the world (`page_LSN < LSN` means apply, else skip); undo is unconditional only because redo has just made the world agree with the log. Disagreement is not detected by inspecting the page's content but by comparing one number. The lesson for a journal over a world with no such number: either stamp the world with the step id where the world allows it, or accept that reconciliation is a content comparison with a rule table, which is weaker.

### 3. Determinism enforcement

Page-oriented redo needs no determinism from the transaction's code: the log record carries the after-image (or a self-contained operation on a named page), and redo re-applies it without re-running anything. Logical undo does need to run code, which is precisely why its effects are logged as page-oriented CLRs. The general form: a journal that stores _results_ makes replay a lookup and confines the determinism requirement to the code between steps; a journal that stores _intents_ and re-executes them requires the executor to be deterministic.

### 4. Compensation and failure handling

CLRs are the model. Three properties matter:

- A compensation is logged as a redo-only record. It is never itself compensated.
- A CLR carries `UndoNxtLSN`, the resume point for the rollback, so a crash inside a rollback resumes exactly where it stopped.
- A CLR is written even when the undo turned out to be unnecessary (§10.1), so the log is a complete account of what rollback decided, not just what it did.

Together these give the bounded-logging guarantee: rollback under N crashes writes the same records as rollback under none.

### 6. Concurrency under replay

The only ordering ARIES preserves during redo is per page. Records for different pages may be applied in any order, in parallel. For a journal, the analog is: steps that touched disjoint parts of the world may replay concurrently, and the journal needs a per-target order, not a global one, to reconstruct the world. Global order is still needed for the undo pass, which the paper runs as a single reverse sweep.

### 7. Replay or snapshot

ARIES checkpoints are not snapshots of data. A checkpoint records the transaction table and the dirty-pages table, and its only job is to bound the analysis and redo scans (`RedoLSN` is the minimum `RecLSN` in the table). The data itself reaches disk whenever the buffer manager chooses, under the WAL rule. The pattern separates the two things "snapshot" usually conflates: a compaction point for the log, which is cheap and fuzzy, and a materialized state, which the log never needs.

### 8. Testing

The paper's own validation method is the crash-during-restart scenario: §10.1 constructs a failure between the undo of `U1` and the write-back of the page, then asks what the _next_ restart sees. That construction, a crash at every point of recovery, not just of forward processing, is the test the CLR design exists to pass, and it is the one a durable program must run.

### 9. Journal integrity and the single writer

ARIES is the origin of this dimension, and almost every mechanism the surveyed
systems use is a restatement of something in it.

**The protocol rule is the whole of write-ahead:** a log record describing a change
must reach stable storage before the changed page may replace its previous version
on disk. Everything in this catalog that writes an intent before performing an
effect is applying that rule to a different kind of change.

**Redo is conditional on a token stamped in the world.** A log record's update is
redone only when the affected page's `page_LSN` is less than the record's own LSN,
which makes redo idempotent under arbitrarily many crashes without any bookkeeping
about which passes have run. This is the mechanism a durable-execution layer lacks
whenever the effect it performed leaves no trace of which record produced it: if the
world can be stamped, reconciliation becomes a single comparison.

**Undo is itself logged, and the log records are never undone.** A compensation log
record is redo-only and carries an `UndoNxtLSN` pointer to the next record still to
be undone, so a crash during rollback resumes rollback rather than restarting it,
and the total logging stays bounded across repeated crashes. Every system in this
survey that registers compensations without journaling them has given this up.

**Recovery repeats history first, then undoes.** The analysis pass establishes what
was in flight, the redo pass restores the state as of the crash including the effects
of transactions that will be rolled back, and only then does undo run. The ordering
is load-bearing: undo must operate against the state it originally saw.

**The checkpoint is a bookkeeping record, not a copy of the data.** A fuzzy
checkpoint writes the transaction table and the dirty-page table and bounds how far
back the analysis pass must scan. A durable-execution layer's equivalent is a record
naming the open scopes and the steps in flight — not a snapshot of the program's
state.

### 10. Operator recovery and intervention

**Partial rollback is the one operator-adjacent affordance**, and it is expressed in
the same machinery as recovery: a transaction may roll back to a savepoint rather
than to its beginning, and the compensation log records written during that partial
rollback are ordinary log records. So "undo the last N operations and continue" is
not a special mode; it is the undo pass with a different stopping point. That is
precisely the shape Golem's revert-to-an-index and Temporal's reset take, arrived at
four decades earlier.

**Nothing else in the paper addresses intervention**, and the absence is
structural: the recovery manager's audience is the system, not a person.

---

## Implications for a durable-execution library

- **Write the intent before performing the effect, and make that the rule rather
  than a convention.** Every durable-execution system that distinguishes started
  from completed is applying the write-ahead protocol to effects instead of pages.
- **Stamp the world with the record's identity where the world allows it.** Redo is
  idempotent because the page carries the sequence number of the last record applied
  to it, so reconciliation is one comparison. A library whose effects can carry a
  step id — in a message, a tag, a record it writes — can have the same property, and
  should take it.
- **Only work that started without completing needs to consult the world.** The
  analysis pass identifies exactly that set, and everything else is replayed as a
  value. Re-observing indiscriminately is both slower and less defensible.
- **Journal the compensation, and never compensate a compensation.** A redo-only
  compensation record with a pointer to the next thing to undo makes rollback
  resumable and keeps logging bounded across repeated crashes. Registering
  compensations in memory gives up both properties.
- **Repeat history before undoing.** Selective redo that skips the work about to be
  rolled back corrupts the state undo runs against — a result the paper establishes
  and a mistake a library can make by trying to be efficient.
- **A checkpoint should record what is in flight, not what the state is.** The
  transaction table and dirty-page table bound recovery without copying data, and the
  analogue for a durable program is a record of open scopes and unfinished steps.
- **Partial rollback to a savepoint is the undo pass with a stopping point** — which
  means a library that journals compensations correctly gets operator-facing
  "rewind N steps" for free, rather than needing a separate mechanism.
- **A record format needs to say where a record ends.** The paper's recovery
  argument assumes a log whose partial tail is detectable; a library appending lines
  to a file must supply that itself, with a length prefix or a checksum, or a torn
  last write becomes an ambiguous record rather than an absent one.

---

## Sources

- Mohan, Haderle, Lindsay, Pirahesh, Schwarz, "ARIES: A Transaction Recovery Method Supporting Fine-Granularity Locking and Partial Rollbacks Using Write-Ahead Logging", ACM TODS 17(1), 1992 — [DOI][aries-doi]; text read from the [Stanford CS345 mirror][aries-pdf] (sections cited: 1.1, 2, 3, 4.1–4.4, 6.2, 6.3, 10.1, 11, 12)
- PostgreSQL 18 documentation, [§28.3 Write-Ahead Logging (WAL)][pg-wal-intro] and [§28.6 WAL Internals][pg-wal-internals]
- Sibling: [Idempotence and the outside world (Helland)][idempotence], which takes the same rule to a world that has no `page_LSN`
- [Durable-execution catalog index][index] · [Event Horizon spec][eh-spec]

<!-- References -->

[aries-doi]: https://doi.org/10.1145/128765.128770
[aries-pdf]: https://cs.stanford.edu/people/chrismre/cs345/rl/aries.pdf
[pg-wal-intro]: https://www.postgresql.org/docs/current/wal-intro.html
[pg-wal-internals]: https://www.postgresql.org/docs/current/wal-internals.html
[idempotence]: ./idempotence.md
[index]: ./index.md
[eh-spec]: ../../../specs/event-horizon/SPEC.md
