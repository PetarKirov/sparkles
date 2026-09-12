# Idempotence and the outside world (Helland)

Pat Helland's two essays are the source for the premise every durable-execution engine stands on: the transport will deliver a message zero or more times, the world it acts on does not roll back, and the only correct response is a recipient that remembers what it has already seen, keyed by an identifier the caller chose.

| Field        | Value                                                                                                                                                                                                                               |
| ------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Pat Helland (Amazon at the time of the 2007 paper; Microsoft, then independent, for the 2012 article)                                                                                                                               |
| Venue / year | "Idempotence Is Not a Medical Condition", _ACM Queue_ 10(4), pp. 30–46, April 2012 · "Life beyond Distributed Transactions: an Apostate's Opinion", CIDR 2007 (position paper, pp. 132–141); reprinted in _ACM Queue_ 14(5), 2016   |
| DOI or URL   | Queue 2012: [`10.1145/2181796.2187821`][queue-doi] ([article page][queue-2012]) · CIDR 2007: [`cidr07p15.pdf`][cidr-pdf] · Queue 2016 reprint: [article page][queue-2016]                                                           |
| Category     | theory                                                                                                                                                                                                                              |
| Grounds      | 1 (step identity: caller-generated keys and dedup by key), 2 (journal versus world: the point of confusion and the recipient's memory), 4 (compensation: tentative/confirm/cancel, effects that cannot be uncommitted), 8 (testing) |

**Last reviewed:** September 12, 2026.

---

## What it establishes

Neither essay proves a theorem. What they establish is a vocabulary and a set of consequences that follow from one assumption, stated in the 2012 article ([Queue 2012][queue-2012], "Zero or more times… guaranteed!"):

> _"When considering the behavior of the underlying message transport, it is best to remember what is promised. Each message is guaranteed to be delivered zero or more times! That is a guarantee you can count on. There is a lovely probability spike showing that most messages are delivered one time."_

From that premise the definition follows ([Queue 2012][queue-2012], "Avoiding embarrassment when talking about idempotence"):

> _"To review, idempotence means that multiple invocations of some work are identical to exactly one invocation."_

The article's examples are the whole argument in miniature: _"Withdrawing $1 billion is not idempotent. Stuttering and retrying might be annoying."_ and, one line later, _"Processing withdrawal XYZ for $1 billion if not already processed is idempotent."_ The difference between the two is a name (`XYZ`) and a memory (`if not already processed`). Everything else in both essays is an elaboration of where that name comes from and where that memory lives.

The 2007 paper supplies the structural half. Its abstract sets out to _"name and formalize some abstractions implicitly in use for years to implement scalable systems"_, and its conclusion names them ([CIDR 2007][cidr-pdf], §7):

> _"Entities are collections of named (keyed) data which may be atomically updated within the entity but never atomically updated across entities. Activities comprise the collection of state within the entities used to manage messaging relationships with a single partner entity."_

Two further definitions matter for this catalog. The 2007 paper's definition of idempotent processing is deliberately application-relative ([CIDR 2007][cidr-pdf], §5):

> _"The processing of a message is idempotent if a subsequent execution of the processing does not perform a substantive change to the entity. This is an amorphous definition which leaves open to the application the specification of what is and what is not substantive."_

and its footnote 13 grounds "substantive" in the [ARIES page from this catalog][wal]: _"in a physiological logging (ARIES-style) system, a logical undo of a transaction will leave the system with the same records as before the transaction. In doing so, the layout of the pages in the Btree may be different. This is not substantive to the record-level interpretation of the contents of the Btree."_ The 2012 article makes the same allowance in its own words: heap fragmentation, log lines and consumed CPU are side effects of a retry that are _"not relevant to the semantics of the application behavior, so the processing of an idempotent request is still considered idempotent even if side effects exist."_

---

## The model

### At-least-once is a choice, and it is the right one

The 2007 paper explains why the transport retries rather than drops. Its "Most Applications Use At-Least-Once Messaging" subsection walks the failure window ([CIDR 2007][cidr-pdf], §1): _"The message is consumed but not yet acknowledged. The database is updated and then the message is acknowledged. In a failure, this is restarted and the message is processed again."_ The plumbing accepts duplicates _"because its only other recourse is to occasionally lose messages ('at-most-once' messaging) and that is even more onerous to deal with."_ Footnote 8 records the author's preference for exactly-once in-order delivery and his conclusion that _"these facilities are rarely available to the programmer building scalable applications."_

The 2012 article lays the same window out as three options for ordering message consumption against the work ([Queue 2012][queue-2012], "Messages, data, and transactions"):

- _"Message consumption is recorded before processing."_ Rare: if the work then fails, _"the message is effectively not delivered at all."_
- _"The message is consumed as part of the database transaction."_ Easiest for the application, _"but it is not commonly available"_ (SQL Service Broker is the cited exception).
- _"The message is consumed after processing. This is the most common case. The application must be designed so that each and every message is idempotent in its processing. There is a failure window in which the work is successfully applied to the database, but a failure prevents the messaging system from knowing the message was consumed. The messaging system will re-drive the delivery of the message."_

### The world does not roll back

Both essays treat an effect on the outside world as something that, once it has happened, cannot be made not to have happened. The 2007 paper's argument for transactional enqueuing states it from the sender's side ([CIDR 2007][cidr-pdf], §3):

> _"It would be horribly complex for an application developer to send a message while working on a transaction, have the message sent, and then the transaction abort. This would mean that you have no memory of causing something to happen and yet it does happen!"_

The 2012 article states it from the sender's epistemic position ([Queue 2012][queue-2012], "Knowing what you don't know when sending messages"): before sending, _"you are very confident the work hasn't been done"_; after sending but before the answer, _"This is the point of confusion. You have absolutely no idea if the other guy has done anything. The work may be done soon, may already be done, or may never get done."_ And it warns that a transport acknowledgement does not resolve that confusion: _"ACK means sending the message again won't help."_ Only an application-level reply does.

The same article names what happens when a system forgets across a crash: _"Of course, there is a technical term for unusual behavior when a system crash intervenes; it is called a bug."_

### Entities and activities

The 2007 model has three parts.

**An entity** is the unit of atomicity: _"Each entity is defined as a collection of data with a unique key known to live within a single scope of serializability. Because it lives within a single scope of serializability, we are ensured that we may always do atomic transactions within a single entity."_ ([CIDR 2007][cidr-pdf], §2). The key is not decoration: _"We observe that the boundary of the disjoint scope of serializability (i.e. the 'entity') is always identified by a unique key in practice."_ Transactions never span entities, because repartitioning may move any two entities to different machines.

**Messages** are the only link between entities, they are addressed by entity key, and they are asynchronous with respect to the sending transaction: _"Messages are the stimuli coming from one transaction and arriving into a new entity causing transactions."_ (§3). Under repartitioning, _"Messages are repeated. Later messages arrive before earlier ones. Life gets messier."_

**An activity** is the recipient's memory of one partner. The paper's shortest definition is in its Figure caption: _"Activities are simple. They are what an entity remembers about other entities it works with. This includes knowledge about received messages."_ (§5). It is where duplicate elimination lives, and the paper is explicit that it lives there because the plumbing cannot do it for a moving entity ([CIDR 2007][cidr-pdf], §5): _"The knowledge of which messages have been delivered to the entity must travel with the entity when it moves due to repartitioning. In practice, the low-level management of this knowledge rarely occurs; messages may be delivered more than once."_

### The recipient remembers, and replays its reply

This is the recommendation both essays converge on. From the 2007 paper's opinions section ([CIDR 2007][cidr-pdf], §1):

> _"To ensure idempotence (i.e. guarantee the processing of retried messages is harmless), the recipient entity is typically designed to remember that the message has been processed. Once it has been, the repeated message will typically generate a new response (or outgoing message) which mimics the behavior of the earlier processed message."_

and from §5, which adds that the memory must be durable and keyed by something unique to the message:

> _"Processing messages that are not naturally idempotent requires ensuring each message is processed at-most-once (i.e. the substantive impact of the message must happen at-most-once). To do this, there must be some unique characteristic of the message that is remembered to ensure it will not be processed more than once. The entity must durably remember the transition from a message being OK to process into the state where the message will not have substantive impact."_

The reply is part of the memory: _"In addition to remembering that a message has been processed, if a reply is required, the same reply must be returned. After all, we don't know if the original sender has received the reply or not."_ (§5).

Put together: the transport gives at-least-once delivery, the activity gives at-most-once substantive acceptance, and the composition is effectively exactly-once processing. That is the whole reasoning, and it puts the exactly-once guarantee in the recipient's durable state rather than in the transport.

### Keys come from the caller

The "unique characteristic of the message" is generated by the sender. The 2007 paper's example is an order application that _"will send messages to the shipping application and include the shipping-id and the sending order-id"_ (§1), and its account of workflow across entities is built on it: _"Everything must be formally knit together using a web of two-party relationships. The knitting is with the entity-keys."_ (§5). The 2012 article draws the same conclusion for a load-balanced service in its initiation-stage discussion ([Queue 2012][queue-2012]): a first message may be retried to a different back-end server, so _"the initiation messages in a dialog protocol must be idempotent"_, and the three ways to make them so (trivial work, read-only work, or _"pending work"_ that accumulates and is applied only after a round trip) all amount to the caller carrying enough identity for the recipient to recognise its own retry.

### Tentative, confirm, cancel

The 2007 paper's §6 is the model for what "compensation" can mean when nothing can be uncommitted. A request across entities is a _tentative operation_: _"a message which requests a commitment but leaves open the possibility of cancellation."_ Then: _"Essential to a tentative operation, is the right to cancel. Sometimes, the entity that requested the tentative operation decides it is not going to proceed forward. That is a cancelling operation. When the right to cancel is released, that is a confirming operation. Every tentative operation eventually confirms or cancels."_ Uncertainty is not hidden in a lock but carried in the business state: _"The uncertainty of the outcome is held in the business semantics rather than in the record lock. This is simply workflow."_

---

## Results

The essays' results are principles with worked failure cases rather than proofs. The 2012 article closes with four ([Queue 2012][queue-2012], "Conclusion"):

> _"Every message may be retried and, hence, must be idempotent. · Messages may be reordered. · Your partner may experience amnesia as a result of failures, poorly managed durable state, or load-balancing switchover to its evil twin. · Guaranteed delivery of the last message is impossible."_

The last one is the closing-stage ambiguity: _"The penultimate message can be guaranteed (by receiving the notification in the ultimate message). The ultimate message must be best effort."_ A protocol therefore cannot end with a message whose receipt matters.

The 2007 paper's results are the two named abstractions plus a negative one: alternate indices over entities cannot be kept transactionally consistent at scale, so _"Workflow-style updates via asynchronous messaging are all that is left to the almost-infinite scale application."_ (§2).

On testing, the 2012 article is candid that these behaviours are hard to provoke: retries and reorderings _"are not spoken about too often and rarely crop up during testing. They typically happen when the application is under its greatest stress."_ and, in the opening: _"Ensuring that the application behaves as intended can be very hard to design and implement. It is even harder to test."_

---

## Relevance to durable execution

A durable-execution runtime is the "plumbing" Helland keeps asking for and keeps finding absent: it records consumption, runs the work, and re-drives on failure. The essays say what the application must still do even when that plumbing exists.

### 1. Step identity and replay matching

Helland's answer is the caller-generated key. The recipient cannot infer identity from the message's content or arrival, because content is duplicated on retry and arrival order is not preserved; the sender must name the unit of work (`withdrawal XYZ`, `order-id` plus `shipping-id`), and the recipient must key its memory by that name. Matching on retry is a lookup by key in durable state that travels with the entity. A journaled step id is this key with the runtime as the sender: the workflow's stable step name plus attempt counter is `XYZ`, and the journal entry is the activity's memory of it. The argument-hash component of a step key is Helland's "unique characteristic of the message" made explicit.

### 2. Journal versus world

The 2012 article's three stages are the whole question. A `started` record with no `completed` record is a step in _"the point of confusion"_: the work may be done, may be in progress, or may never have started. Helland's rule for that state is that only an application-level reply resolves it, and transport-level signals (an exit code from a launcher, a write that returned) do not. Two consequences for a journal: when the recipient is under the runtime's control (a step that writes to its own store), the recipient's memory decides; when the recipient is the outside world, the runtime must ask the world in the world's own terms, and the answer is a re-observation, not a replay. The memory also stores the reply, so that a duplicate produces _"a new response which mimics the behavior of the earlier processed message"_: a replayed step must return the recorded result, not re-derive one.

### 4. Compensation and failure handling

Helland's world has no rollback of effects, only forward messages. Compensation is therefore not undo; it is the cancel half of a tentative operation, a new message that the recipient interprets against its own state. Three things follow. First, a cancel is itself a message and so is subject to duplication; it needs a key and a memory like any other. Second, whether an effect can be cancelled at all is a property of the recipient's protocol: a tentative reservation can, a confirmed one cannot, and a message that is not tentative (money moved, email sent) has no cancel at all and can only be answered with a further forward action. Third, uncertainty between the request and its confirmation is state the requester must hold durably, which is what a registered-but-not-yet-triggered compensation is.

### 8. Testing

The essays do not propose a method, but they specify the adversary: a transport that duplicates, reorders, delays by days, and delivers a retry to a fresh replica that has forgotten the first attempt. A durable-program test suite has to be that adversary. Crashing the workflow at every recorded event and resuming produces the duplicate-delivery case; mutating the world between crash and resume produces the amnesiac-partner case. The article's remark that these failures _"rarely crop up during testing"_ is the argument for making them the default test rather than an occasional one.

---

## Relevance to sparkles

- **The `started` record is Helland's "record consumption before processing", and it is the right choice for `release`.** He calls that option rare because a failure after it looks like non-delivery. In a durable workflow the runtime resumes, so the record is not a lost message but a resume point that says "in the point of confusion, go ask the world". That is exactly the design's observation-and-reconcile rule for a `started`-without-`completed` step, and the [ARIES page][wal] adds the flush discipline it needs.

- **The reconciliation table is an activity keyed by the tag name, and the table's two rows are Helland's two outcomes.** A git tag name is the caller-generated key; the boundary SHA is the substantive content. "Tag exists on the boundary SHA, therefore done" is the recipient recognising its own earlier processing and returning the mimicked reply. "Tag exists elsewhere, therefore conflict" is a case Helland's model does not have: entity keys are unique by construction, so two messages with the same key and different content cannot occur. In `release` they can, because a human or another run shares the key space. The design is right to treat it as a stop, not a dedup hit, and the ARIES page's suggestion to stamp the tag annotation with the run and step id is what turns that ambiguity back into a key comparison.

- **Store the reply, not just the fact.** Helland requires the recipient to return _the same reply_ on a duplicate. For `release`, the LLM-written notes, the suggested bump and the segmentation plan are replies that must be journaled in `completed` and replayed verbatim; re-deriving them on resume would give a different release than the one half-published. This confirms "decisions replay verbatim" and says why: a re-derived decision is a second, different message under the same key.

- **Classify every outward effect as tentative or confirmed, and register compensations only for tentative ones.** A local tag and a draft GitHub release are tentative: they carry a right to cancel (delete). A pushed tag is confirmed the moment another clone can fetch it; a published release, a registry submission and a sent notification are money moved. The design's "explicit-only" compensation rule should be sharpened into a rule about which effects may appear in a compensable scope at all: confirming operations must be the last action of their scope, after which the scope has no cancel and the only recovery is forward. That ordering, tentative work first and one confirming act last, is the shape of `release --split`'s chain of segments if each segment ends in its publish.

- **Compensations are messages with their own keys.** A `delete tag` compensation can be retried and must be journaled and matched like a forward step; Helland's model gives no special status to a cancel. This is the same conclusion the ARIES page reaches from the other direction (a CLR is a redo-only record with a resume pointer).

- **The last message cannot be guaranteed, so the workflow's final act must not matter.** Helland's closing-stage ambiguity applies to a `release` run that ends by writing a receipt or posting a notification: a crash after the publish and before the receipt is indistinguishable, from outside, from a crash before the publish. The receipt must be derivable from the world (the tag and release exist) rather than be the thing that makes the release "done". The UI-as-projection-of-the-journal decision is compatible with this only if the projection also consults the world for the final step.

- **Test the adversary Helland describes, not just the crash.** Crash-at-every-index gives duplicate delivery; mutate-the-world gives the amnesiac partner. The reorder case is missing from the design's test list. It applies whenever concurrent steps exist (question 6), and Helland's transport reorders by default, so the test harness should permute completion order of concurrent steps between crash and resume.

---

## Sources

- Pat Helland, "Idempotence Is Not a Medical Condition", _ACM Queue_ 10(4), April 14, 2012 — [DOI][queue-doi] · [article][queue-2012] (read via the Internet Archive capture, since the publisher's site refuses non-browser clients; sections cited: "Messages, data, and transactions", "Knowing what you don't know when sending messages", "Zero or more times… guaranteed!", "Avoiding embarrassment when talking about idempotence", "The initiation-stage ambiguity", "The closing-stage ambiguity", "Conclusion")
- Pat Helland, "Life beyond Distributed Transactions: an Apostate's Opinion", CIDR 2007, pp. 132–141 — [PDF][cidr-pdf] (sections cited: Abstract, 1, 2, 3, 5, 6, 7); reprinted as _ACM Queue_ 14(5), 2016 — [article][queue-2016]
- Sibling: [Write-ahead logging (ARIES)][wal], the log discipline Helland's footnote 13 leans on
- [Durable-execution catalog index][index] · [Event Horizon spec][eh-spec] · [Release spec][release-spec]

<!-- References -->

[queue-doi]: https://doi.org/10.1145/2181796.2187821
[queue-2012]: https://queue.acm.org/detail.cfm?id=2187821
[queue-2016]: https://queue.acm.org/detail.cfm?id=3025012
[cidr-pdf]: https://www.cidrdb.org/cidr2007/papers/cidr07p15.pdf
[wal]: ./write-ahead-logging.md
[index]: ./index.md
[eh-spec]: ../../../specs/event-horizon/SPEC.md
[release-spec]: ../../../specs/release/SPEC.md
