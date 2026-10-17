----------------------------- MODULE ParkingLot -----------------------------
(***************************************************************************)
(* Oracle 10, part S1: the parking lot of docs/specs/base/sync/SPEC.md §3, *)
(* §4, §4a and §6, written from the specification alone.                  *)
(*                                                                         *)
(* Keys are 1..NKeys; each key is its own protocol (tag k), so SYP14's     *)
(* tag rewrite on requeue is observable.  Buckets are explicit locks: an   *)
(* operation acquires its bucket (or, for a requeue, both buckets in       *)
(* ascending order) in one step and runs its body, the validate, callback  *)
(* or filter code of SYP12, in the next, releasing the bucket(s).          *)
(*                                                                         *)
(* The parker is abstract (SYK2): a sleep returns woken, timed out or,     *)
(* only when armed interruptible, cancelled, at any point; the parking     *)
(* lot decides the outcome under the bucket lock (SYP4, SYP5, SYI3).  The  *)
(* thread parker's word is `wflag`: `prepare` clears it, a delivery sets   *)
(* it.  A wake handle is the waiter's identity, never its record (SYK8).   *)
(*                                                                         *)
(* The client protocol is a flag per key: a waiter parks on k while        *)
(* word[k] = 0; a signaller sets word[k] := 1 and then unparks all of k.   *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Procs,          \* simulated threads
  Waiters,        \* threads that park
  Wakers,         \* threads that signal, kick, filter, requeue and reset
  NKeys,          \* number of keys
  WaitKeys,       \* the keys waiters park on (requeues move from them)
  SharedBucket,   \* TRUE: every key hashes to bucket 1 (SYP1 collisions)
  Timed,          \* waiters whose parks carry a deadline
  Interruptible,  \* waiters whose parks are interruptible; cancellations
                  \* arrive for them
  EnableReset,    \* wakers may reset a flag to 0
  EnableKick,     \* unparkOne that registers a designation (SYP15)
  EnableFilter,   \* unparkFilter (SYP9)
  EnableRequeue,  \* unparkRequeue (SYP8, SYP14)
  EnableFork,     \* one fork (SYX1)
  \* Seeded faults; each must be reported (see check.sh).
  FaultValidateOutsideLock,  \* validate reads the word before the bucket lock
  FaultTimeoutIgnoresToken,  \* a timed-out sleep ignores a committed unpark
  FaultDeliverThroughRecord, \* a delivery writes the record (violates SYK8)
  FaultNoRetire,             \* a designated waiter returns still registered
  FaultSettleOnSpurious,     \* settle is called for a spurious cancellation
  FaultRequeueKeepsMode      \* requeue keeps interruptibility and deadline

ASSUME /\ Waiters \subseteq Procs /\ Wakers \subseteq Procs /\ NKeys \in 1..2
       /\ WaitKeys \subseteq 1..NKeys
       /\ Timed \subseteq Waiters /\ Interruptible \subseteq Waiters

None == "none"
Keys == 1..NKeys
Buckets == IF SharedBucket THEN {1} ELSE Keys
BucketOf(k) == IF SharedBucket THEN 1 ELSE k
Min(a, b) == IF a < b THEN a ELSE b
Max(a, b) == IF a < b THEN b ELSE a

Range(s) == {s[i] : i \in DOMAIN s}
Without(s, x) == SelectSeq(s, LAMBDA y : y # x)
\* The subsequence of s at the indices in I, and the rest, in order.
Pick(s, I) == LET F[i \in 0..Len(s)] ==
                    IF i = 0 THEN << >>
                    ELSE IF i \in I THEN Append(F[i - 1], s[i]) ELSE F[i - 1]
              IN F[Len(s)]
Rest(s, I) == Pick(s, (1..Len(s)) \ I)

VARIABLES
  pc,        \* [Procs -> program counter]
  op,        \* [Procs -> parameters of the current operation]
  word,      \* [Keys -> {0, 1}], the client protocol's state
  queue,     \* [Keys -> Seq(Procs)], FIFO per key (SYP6)
  rec,       \* [Procs -> waiter record] (SYK3: one record per thread)
  wflag,     \* [Procs -> BOOLEAN], the thread parker's word
  slp,       \* [Procs -> [intr, dl]], how the current sleep was armed
  res,       \* [Procs -> tentative sleep result]
  inflight,  \* SUBSET Procs: committed, undelivered wakes (SYP10)
  reg,       \* [Procs -> key of the registration, or 0] (SYP15)
  creq,      \* [Procs -> BOOLEAN], a pending cancellation request
  bl,        \* [Buckets -> holder or None]
  sig,       \* [Procs -> key a signal is in progress on, or 0]
  forked,    \* the one fork has happened
  outc,      \* [Procs -> outcome of the last park] (ghost)
  nset       \* [Procs -> settle calls during the current park] (ghost)

vars == <<pc, op, word, queue, rec, wflag, slp, res, inflight, reg, creq, bl,
          sig, forked, outc, nset>>

NoRec == [key |-> 0, tag |-> 0, intr |-> FALSE, dl |-> FALSE, st |-> "idle",
          tok |-> None, moved |-> FALSE]
NoOp == [k |-> 1, to |-> 1, intr |-> FALSE, dl |-> FALSE, early |-> 0,
         hb |-> 1]

Init ==
  /\ pc = [p \in Procs |-> "idle"]
  /\ op = [p \in Procs |-> NoOp]
  /\ word = [k \in Keys |-> 0]
  /\ queue = [k \in Keys |-> << >>]
  /\ rec = [p \in Procs |-> NoRec]
  /\ wflag = [p \in Procs |-> FALSE]
  /\ slp = [p \in Procs |-> [intr |-> FALSE, dl |-> FALSE]]
  /\ res = [p \in Procs |-> None]
  /\ inflight = {}
  /\ reg = [p \in Procs |-> 0]
  /\ creq = [p \in Procs |-> FALSE]
  /\ bl = [b \in Buckets |-> None]
  /\ sig = [p \in Procs |-> 0]
  /\ forked = FALSE
  /\ outc = [p \in Procs |-> None]
  /\ nset = [p \in Procs |-> 0]

-----------------------------------------------------------------------------
(* Helpers *)

Goto(p, l) == pc' = [pc EXCEPT ![p] = l]

\* Acquire bucket b and continue at l (one step; SYP13 is not modelled).
Acquire(p, b, l) ==
  /\ bl[b] = None
  /\ bl' = [bl EXCEPT ![b] = p]
  /\ op' = [op EXCEPT ![p].hb = b]
  /\ Goto(p, l)

Release(b) == [bl EXCEPT ![b] = None]

\* Return to user code, forgetting the finished operation's parameters.
Idle(p) == Goto(p, "idle") /\ op' = [op EXCEPT ![p] = NoOp]

\* A waiter's operation returns: its record may be reclaimed (SYK4).
Finish(p) ==
  /\ Idle(p)
  /\ rec' = [rec EXCEPT ![p] = NoRec]
  /\ res' = [res EXCEPT ![p] = None]
  /\ slp' = [slp EXCEPT ![p] = [intr |-> FALSE, dl |-> FALSE]]
  /\ outc' = [outc EXCEPT ![p] = None]
  /\ nset' = [nset EXCEPT ![p] = 0]

\* Commit a wake of every record in W with token t (SYP7, SYP10): dequeued
\* under the bucket lock, delivered later by Deliver.
Commit(W, t) ==
  /\ rec' = [q \in Procs |->
               IF q \in W THEN [rec[q] EXCEPT !.st = "dequeued", !.tok = t]
               ELSE rec[q]]
  /\ inflight' = inflight \cup W

-----------------------------------------------------------------------------
(* Park (SYP2–SYP5, SYP14, SYI3) *)

StartWait(p) ==
  /\ p \in Waiters /\ pc[p] = "idle"
  /\ \E k \in WaitKeys :
       op' = [op EXCEPT ![p] = [NoOp EXCEPT !.k = k,
                                   !.intr = p \in Interruptible,
                                   !.dl = p \in Timed]]
  /\ Goto(p, IF FaultValidateOutsideLock THEN "w_read" ELSE "w_lock")
  /\ outc' = [outc EXCEPT ![p] = None]
  /\ nset' = [nset EXCEPT ![p] = 0]
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, bl,
                 sig, forked>>

\* Fault: the validation's read happens before the bucket is locked.
ReadEarly(p) ==
  /\ pc[p] = "w_read"
  /\ op' = [op EXCEPT ![p].early = word[op[p].k]]
  /\ Goto(p, "w_lock")
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, bl,
                 sig, forked, outc, nset>>

WLock(p) ==
  /\ pc[p] = "w_lock"
  /\ Acquire(p, BucketOf(op[p].k), "w_body")
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, sig,
                 forked, outc, nset>>

\* SYP2: validate and enqueue under the bucket lock; prepare (SYK2) before
\* the record is enqueued.
WBody(p) ==
  /\ pc[p] = "w_body"
  /\ LET k == op[p].k
         valid == IF FaultValidateOutsideLock THEN op[p].early = 0
                  ELSE word[k] = 0
     IN /\ bl' = Release(op[p].hb)
        /\ IF valid
           THEN /\ queue' = [queue EXCEPT ![k] = Append(@, p)]
                /\ rec' = [rec EXCEPT ![p] =
                             [key |-> k, tag |-> k, intr |-> op[p].intr,
                              dl |-> op[p].dl, st |-> "queued", tok |-> None,
                              moved |-> FALSE]]
                /\ wflag' = [wflag EXCEPT ![p] = FALSE]
                /\ slp' = [slp EXCEPT ![p] =
                             [intr |-> op[p].intr, dl |-> op[p].dl]]
                /\ Goto(p, "w_sleep")
                /\ UNCHANGED outc
           ELSE /\ outc' = [outc EXCEPT ![p] = "invalid"]
                /\ Goto(p, "w_ret")
                /\ UNCHANGED <<queue, rec, wflag, slp>>
  /\ UNCHANGED <<op, word, res, inflight, reg, creq, sig, forked, nset>>

SleepResult(p, r) ==
  /\ res' = [res EXCEPT ![p] = r]
  /\ Goto(p, "w_res")
  /\ UNCHANGED <<op, word, queue, rec, wflag, slp, inflight, reg, creq, bl,
                 sig, forked, outc, nset>>

\* The parker's sleep (SYK2): woken by a delivery (fair), or spuriously, by
\* its deadline, or by a cancellation only when armed interruptible.
SleepWake(p) == pc[p] = "w_sleep" /\ wflag[p] /\ SleepResult(p, "woken")
SleepSpurious(p) == pc[p] = "w_sleep" /\ SleepResult(p, "woken")
SleepTimeout(p) == pc[p] = "w_sleep" /\ slp[p].dl /\ SleepResult(p, "timedOut")
SleepCancel(p) ==
  pc[p] = "w_sleep" /\ slp[p].intr /\ creq[p] /\ SleepResult(p, "cancelled")

\* A committed record is seen without the bucket lock; otherwise the
\* outcome is decided under the bucket of the record's current key (SYP8).
WRes(p) ==
  /\ pc[p] = "w_res"
  /\ IF rec[p].st = "dequeued"
     THEN /\ outc' = [outc EXCEPT ![p] =
                        IF FaultTimeoutIgnoresToken /\ res[p] = "timedOut"
                        THEN "timedOut" ELSE "unparked"]
          /\ Goto(p, "w_ret")
     ELSE /\ Goto(p, "w_rlock")
          /\ UNCHANGED outc
  /\ UNCHANGED <<op, word, queue, rec, wflag, slp, res, inflight, reg, creq, bl,
                 sig, forked, nset>>

WRLock(p) ==
  /\ pc[p] = "w_rlock"
  /\ Acquire(p, BucketOf(rec[p].key), "w_rbody")
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, sig,
                 forked, outc, nset>>

WRBody(p) ==
  /\ pc[p] = "w_rbody"
  /\ bl' = Release(op[p].hb)
  /\ LET k == rec[p].key
         removed == [rec EXCEPT ![p].st = "idle"]
         dq == [queue EXCEPT ![k] = Without(@, p)]
     IN CASE rec[p].st = "dequeued" ->
               /\ outc' = [outc EXCEPT ![p] = "unparked"]
               /\ Goto(p, "w_ret")
               /\ UNCHANGED <<queue, rec, wflag, slp, creq, nset>>
          [] BucketOf(k) # op[p].hb ->
               \* requeued to another bucket meanwhile: retry
               /\ Goto(p, "w_rlock")
               /\ UNCHANGED <<queue, rec, wflag, slp, creq, outc, nset>>
          [] res[p] = "timedOut" /\ rec[p].dl ->
               /\ queue' = dq /\ rec' = removed
               /\ outc' = [outc EXCEPT ![p] = "timedOut"]
               /\ Goto(p, "w_ret")
               /\ UNCHANGED <<wflag, slp, creq, nset>>
          [] res[p] = "cancelled" /\ rec[p].intr ->
               \* SYI3: settle exactly once, here; the scheduler consumes
               /\ queue' = dq /\ rec' = removed
               /\ outc' = [outc EXCEPT ![p] = "cancelled"]
               /\ nset' = [nset EXCEPT ![p] = @ + 1]
               /\ creq' = [creq EXCEPT ![p] = FALSE]
               /\ Goto(p, "w_ret")
               /\ UNCHANGED <<wflag, slp>>
          [] OTHER ->
               \* spurious (SYP4, SYP14): prepare again and sleep again,
               \* armed as the record's current registration says
               /\ wflag' = [wflag EXCEPT ![p] = FALSE]
               /\ slp' = [slp EXCEPT ![p] =
                            [intr |-> rec[p].intr, dl |-> rec[p].dl]]
               /\ IF FaultSettleOnSpurious /\ res[p] = "cancelled"
                  THEN /\ nset' = [nset EXCEPT ![p] = @ + 1]
                       /\ creq' = [creq EXCEPT ![p] = FALSE]
                  ELSE UNCHANGED <<nset, creq>>
               /\ Goto(p, "w_sleep")
               /\ UNCHANGED <<queue, rec, outc>>
  /\ UNCHANGED <<op, word, res, inflight, reg, sig, forked>>

\* The park has returned.  A designated waiter retires its registration
\* under the bucket lock before its operation returns (SYP15).
WRet(p) ==
  /\ pc[p] = "w_ret"
  /\ IF reg[p] # 0 /\ ~FaultNoRetire
     THEN /\ Goto(p, "w_retlock")
          /\ UNCHANGED <<op, rec, res, slp, outc, nset>>
     ELSE Finish(p)
  /\ UNCHANGED <<word, queue, wflag, inflight, reg, creq, bl, sig, forked>>

RetLock(p) ==
  /\ pc[p] = "w_retlock"
  /\ Acquire(p, BucketOf(reg[p]), "w_retbody")
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, sig,
                 forked, outc, nset>>

RetBody(p) ==
  /\ pc[p] = "w_retbody"
  /\ bl' = Release(op[p].hb)
  /\ reg' = [reg EXCEPT ![p] = 0]
  /\ Finish(p)
  /\ UNCHANGED <<word, queue, wflag, inflight, creq, sig, forked>>

-----------------------------------------------------------------------------
(* Unpark operations (SYP6–SYP9) *)

\* Signal: set the flag outside the lock, then unpark all of the key.
Signal(p) ==
  /\ p \in Wakers /\ pc[p] = "idle"
  /\ \E k \in Keys :
       /\ word' = [word EXCEPT ![k] = 1]
       /\ sig' = [sig EXCEPT ![p] = k]
       /\ op' = [op EXCEPT ![p] = [NoOp EXCEPT !.k = k]]
  /\ Goto(p, "s_lock")
  /\ UNCHANGED <<queue, rec, wflag, slp, res, inflight, reg, creq, bl, forked,
                 outc, nset>>

SLock(p) ==
  /\ pc[p] = "s_lock"
  /\ Acquire(p, BucketOf(op[p].k), "s_body")
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, sig,
                 forked, outc, nset>>

SBody(p) ==
  /\ pc[p] = "s_body"
  /\ LET k == op[p].k IN
       /\ Commit(Range(queue[k]), "woken")
       /\ queue' = [queue EXCEPT ![k] = << >>]
  /\ bl' = Release(op[p].hb)
  /\ sig' = [sig EXCEPT ![p] = 0]
  /\ Idle(p)
  /\ UNCHANGED <<word, wflag, slp, res, reg, creq, forked, outc, nset>>

\* Reset the flag; parked waiters stay parked.
Reset(p) ==
  /\ EnableReset /\ p \in Wakers /\ pc[p] = "idle"
  /\ \E k \in Keys : word[k] = 1 /\ word' = [word EXCEPT ![k] = 0]
  /\ UNCHANGED <<pc, op, queue, rec, wflag, slp, res, inflight, reg, creq, bl,
                 sig, forked, outc, nset>>

\* Pick an operation that runs under one bucket of key k.
StartKeyed(p, enable, l) ==
  /\ enable /\ p \in Wakers /\ pc[p] = "idle"
  /\ \E k \in Keys : op' = [op EXCEPT ![p] = [NoOp EXCEPT !.k = k]]
  /\ Goto(p, l)
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, bl,
                 sig, forked, outc, nset>>

KeyedLock(p, l, body) ==
  /\ pc[p] = l
  /\ Acquire(p, BucketOf(op[p].k), body)
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, sig,
                 forked, outc, nset>>

\* Kick: unparkOne that designates the woken record, registering it in the
\* bucket (SYP15).
KBody(p) ==
  /\ pc[p] = "k_body"
  /\ LET k == op[p].k IN
       IF queue[k] = << >>
       THEN UNCHANGED <<queue, rec, inflight, reg>>
       ELSE LET h == Head(queue[k]) IN
              /\ Commit({h}, "designated")
              /\ queue' = [queue EXCEPT ![k] = Tail(@)]
              /\ reg' = [reg EXCEPT ![h] = k]
  /\ bl' = Release(op[p].hb)
  /\ Idle(p)
  /\ UNCHANGED <<word, wflag, slp, res, creq, sig, forked, outc, nset>>

\* unparkFilter (SYP9): each record in queue order answers wake, skip or
\* stop; the filter is arbitrary caller code, so every answer is explored.
FBody(p) ==
  /\ pc[p] = "f_body"
  /\ LET k == op[p].k
         q == queue[k]
     IN \E d \in [1..Len(q) -> {"wake", "skip", "stop"}] :
          LET W == {i \in 1..Len(q) :
                      d[i] = "wake" /\ \A j \in 1..(i - 1) : d[j] # "stop"}
          IN /\ Commit(Range(Pick(q, W)), "woken")
             /\ queue' = [queue EXCEPT ![k] = Rest(q, W)]
  /\ bl' = Release(op[p].hb)
  /\ Idle(p)
  /\ UNCHANGED <<word, wflag, slp, res, reg, creq, sig, forked, outc, nset>>

\* unparkRequeue(from, to) (SYP8): both buckets in ascending order.
StartRequeue(p) ==
  /\ EnableRequeue /\ NKeys = 2 /\ p \in Wakers /\ pc[p] = "idle"
  /\ \E f \in WaitKeys :
       op' = [op EXCEPT ![p] = [NoOp EXCEPT !.k = f, !.to = 3 - f]]
  /\ Goto(p, "r_lock1")
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, bl,
                 sig, forked, outc, nset>>

RB1(p) == Min(BucketOf(op[p].k), BucketOf(op[p].to))
RB2(p) == Max(BucketOf(op[p].k), BucketOf(op[p].to))

RLock1(p) ==
  /\ pc[p] = "r_lock1"
  /\ Acquire(p, RB1(p), IF RB1(p) = RB2(p) THEN "r_body" ELSE "r_lock2")
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, sig,
                 forked, outc, nset>>

RLock2(p) ==
  /\ pc[p] = "r_lock2"
  /\ Acquire(p, RB2(p), "r_body")
  /\ UNCHANGED <<word, queue, rec, wflag, slp, res, inflight, reg, creq, sig,
                 forked, outc, nset>>

\* A moved record takes the destination's tag and becomes non-interruptible
\* with no deadline (SYP14).
Moved(r, to) ==
  [r EXCEPT !.key = to, !.tag = to, !.moved = TRUE,
            !.intr = FaultRequeueKeepsMode /\ r.intr,
            !.dl = FaultRequeueKeepsMode /\ r.dl]

RBody(p) ==
  /\ pc[p] = "r_body"
  /\ LET f == op[p].k
         t == op[p].to
         q == queue[f]
         \* validate: abort when the destination is already signalled, so
         \* that no record moves onto a key whose wake has passed
         choices == IF word[t] = 1 \/ q = << >> THEN {"abort"}
                    ELSE {"wake1move", "move1", "moveall", "abort"}
     IN \E c \in choices :
          LET woken == IF c = "wake1move" THEN {1} ELSE {}
              moved == CASE c = "wake1move" -> 2..Len(q)
                         [] c = "move1" -> {1}
                         [] c = "moveall" -> 1..Len(q)
                         [] OTHER -> {}
              M == Range(Pick(q, moved))
              W == Range(Pick(q, woken))
          IN /\ queue' = [queue EXCEPT ![f] = Rest(q, woken \cup moved),
                                       ![t] = @ \o Pick(q, moved)]
             /\ rec' = [r \in Procs |->
                          CASE r \in W ->
                                 [rec[r] EXCEPT !.st = "dequeued",
                                                !.tok = "woken"]
                            [] r \in M -> Moved(rec[r], t)
                            [] OTHER -> rec[r]]
             /\ inflight' = inflight \cup W
  /\ bl' = [Release(RB2(p)) EXCEPT ![RB1(p)] = None]
  /\ Idle(p)
  /\ UNCHANGED <<word, wflag, slp, res, reg, creq, sig, forked, outc, nset>>

-----------------------------------------------------------------------------
(* The environment *)

\* A committed wake is delivered after the bucket is released; it may reach
\* the waiter after its park returned, even during a later park (SYK8).
Deliver(q) ==
  /\ q \in inflight
  /\ inflight' = inflight \ {q}
  /\ wflag' = [wflag EXCEPT ![q] = TRUE]
  /\ IF FaultDeliverThroughRecord /\ rec[q].st = "queued"
     THEN rec' = [rec EXCEPT ![q].st = "dequeued", ![q].tok = "stale"]
     ELSE UNCHANGED rec
  /\ UNCHANGED <<pc, op, word, queue, slp, res, reg, creq, bl, sig, forked,
                 outc, nset>>

CancelArrives(p) ==
  /\ p \in Interruptible /\ ~creq[p]
  /\ creq' = [creq EXCEPT ![p] = TRUE]
  /\ UNCHANGED <<pc, op, word, queue, rec, wflag, slp, res, inflight, reg, bl,
                 sig, forked, outc, nset>>

\* SYX1: the forking thread f continues in the child; every other thread
\* is gone, and the child starts fresh threads in their place.  The
\* handler resets the table: buckets unlocked, queues empty, no
\* registration, no record.  Memory, the words, is copied.
Fork(f) ==
  /\ EnableFork /\ ~forked /\ pc[f] = "idle"
  /\ forked' = TRUE
  /\ pc' = [p \in Procs |-> "idle"]
  /\ op' = [p \in Procs |-> NoOp]
  /\ queue' = [k \in Keys |-> << >>]
  /\ rec' = [p \in Procs |-> NoRec]
  /\ wflag' = [p \in Procs |-> FALSE]
  /\ res' = [p \in Procs |-> None]
  /\ inflight' = {}
  /\ reg' = [p \in Procs |-> 0]
  /\ creq' = [p \in Procs |-> IF p = f THEN creq[p] ELSE FALSE]
  /\ bl' = [b \in Buckets |-> None]
  /\ sig' = [p \in Procs |-> 0]
  /\ outc' = [p \in Procs |-> None]
  /\ nset' = [p \in Procs |-> 0]
  /\ UNCHANGED <<word, slp>>

-----------------------------------------------------------------------------

LockSteps(p) ==
  \/ WLock(p) \/ WRLock(p) \/ RetLock(p) \/ SLock(p)
  \/ KeyedLock(p, "k_lock", "k_body") \/ KeyedLock(p, "f_lock", "f_body")
  \/ RLock1(p) \/ RLock2(p)

OtherSteps(p) ==
  \/ ReadEarly(p) \/ WBody(p) \/ SleepWake(p) \/ WRes(p) \/ WRBody(p)
  \/ WRet(p) \/ RetBody(p) \/ SBody(p) \/ KBody(p) \/ FBody(p) \/ RBody(p)

Choices(p) ==
  \/ StartWait(p) \/ Signal(p) \/ Reset(p) \/ StartRequeue(p)
  \/ StartKeyed(p, EnableKick, "k_lock")
  \/ StartKeyed(p, EnableFilter, "f_lock")

Env(p) ==
  \/ SleepSpurious(p) \/ SleepTimeout(p) \/ SleepCancel(p)
  \/ Deliver(p) \/ CancelArrives(p) \/ Fork(p)

Next == \E p \in Procs : LockSteps(p) \/ OtherSteps(p) \/ Choices(p) \/ Env(p)

\* Every loop keeps running and every committed wake is delivered.  Bucket
\* acquisition is strongly fair: SYP13 promises no fairness of its own, so
\* a bucket that is free infinitely often must eventually be taken.
Fairness ==
  \A p \in Procs :
    /\ WF_vars(OtherSteps(p))
    /\ SF_vars(LockSteps(p))
    /\ WF_vars(Deliver(p))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Safety (oracle 1's invariants, at the protocol level) *)

TypeOK ==
  /\ word \in [Keys -> {0, 1}]
  /\ queue \in [Keys -> Seq(Procs)]
  /\ inflight \subseteq Procs
  /\ reg \in [Procs -> 0..NKeys]
  /\ bl \in [Buckets -> Procs \cup {None}]

\* SYK4: a record is in at most one queue, once; it is queued exactly when
\* its state says so, under the key it records; SYP14: tags match the key.
QueueConsistent ==
  /\ \A k1, k2 \in Keys : \A i \in DOMAIN queue[k1], j \in DOMAIN queue[k2] :
       queue[k1][i] = queue[k2][j] => k1 = k2 /\ i = j
  /\ \A p \in Procs :
       rec[p].st = "queued" <=> \E k \in Keys : p \in Range(queue[k])
  /\ \A k \in Keys : \A p \in Range(queue[k]) : rec[p].key = k

TagsConsistent ==
  \A k \in Keys : \A p \in Range(queue[k]) : rec[p].tag = k

\* SYP2: no lost wakeup.  A record waiting for a flag that is set has a
\* signal in progress on that key that will still find it.
NoLostWakeup ==
  \A p \in Procs :
    rec[p].st = "queued" /\ word[rec[p].key] = 1 =>
      \E s \in Procs : sig[s] = rec[p].key

\* SYP4, SYP5, SYI3, SYP14: at its return a park has exactly one outcome;
\* it is unparked exactly when an unpark dequeued its record; settle ran
\* once exactly when it ended cancelled; a moved record only reacquires.
ReturnConsistent ==
  \A p \in Procs : pc[p] = "w_ret" =>
    /\ outc[p] \in {"unparked", "invalid", "timedOut", "cancelled"}
    /\ (outc[p] = "unparked") <=> (rec[p].st = "dequeued")
    /\ nset[p] = (IF outc[p] = "cancelled" THEN 1 ELSE 0)
    /\ rec[p].moved => outc[p] = "unparked"

\* SYI3: settle never runs except for a park that ends cancelled.
SettleOnlyOnCancel ==
  \A p \in Procs : nset[p] <= 1 /\ (nset[p] > 0 => outc[p] = "cancelled")

\* SYP15: a registration belongs to a dequeued, designated record, and is
\* retired before its operation returns or parks again.
RegistrationsSound ==
  \A p \in Procs : reg[p] # 0 =>
    /\ pc[p] \in {"w_sleep", "w_res", "w_rlock", "w_rbody", "w_ret",
                  "w_retlock", "w_retbody"}
    /\ rec[p].st = "dequeued" /\ rec[p].tok = "designated"

\* SYX1: after the fork no bucket is left locked by a vanished thread: every
\* held bucket is held by a thread in a step that holds it.
BucketsHeldByHolders ==
  \A b \in Buckets : bl[b] # None =>
    pc[bl[b]] \in {"w_body", "w_rbody", "w_retbody", "s_body", "k_body",
                   "f_body", "r_lock2", "r_body"}

Safety ==
  /\ QueueConsistent /\ TagsConsistent /\ NoLostWakeup /\ ReturnConsistent
  /\ SettleOnlyOnCancel /\ RegistrationsSound /\ BucketsHeldByHolders

(* Witnesses: each is expected to be violated, which shows the trace is   *)
(* accepted (oracle 10: the model must accept a withdrawal).              *)

NoWithdrawal ==
  \A p \in Procs : pc[p] = "w_ret" => outc[p] \notin {"timedOut", "cancelled"}

\* SYP5: a deadline or cancellation that loses to a committed unpark.
NoLostRace ==
  \A p \in Procs :
    ~(pc[p] = "w_ret" /\ outc[p] = "unparked"
      /\ res[p] \in {"timedOut", "cancelled"})

\* SYK8: a delivery still in flight while its waiter parks again.
NoLateDelivery ==
  \A p \in Procs : ~(p \in inflight /\ rec[p].st = "queued")

-----------------------------------------------------------------------------
(* Liveness *)

ParkedPcs == {"w_sleep", "w_res", "w_rlock", "w_rbody"}

\* Every committed wake makes its park return (SYP10, SYK2).
WakesReturn ==
  \A p \in Procs :
    (rec[p].st = "dequeued" /\ pc[p] \in ParkedPcs)
      ~> (pc[p] = "w_ret" \/ forked)

\* No registration lasts forever (SYP15).
RegistrationsRetire == \A p \in Procs : (reg[p] # 0) ~> (reg[p] = 0)

\* Every unpark operation completes: bucket order admits no deadlock.
SignalsComplete == \A p \in Procs : (sig[p] # 0) ~> (sig[p] = 0)

=============================================================================
