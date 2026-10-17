---------------------------- MODULE LockProtocols ----------------------------
(***************************************************************************)
(* Oracle 10, part S2: the Mutex (LockBits), InterruptibleMutex and        *)
(* Condition protocols of docs/specs/base/sync/primitives.md §2–§4 and §6, *)
(* over the parking lot of SPEC.md §3, written from the specification.     *)
(*                                                                         *)
(* Key M is the lock's address, key C the condition's.  Every parking-lot  *)
(* operation is one atomic step: a bucket lock serializes it against every *)
(* other operation on its bucket, and it performs at most one              *)
(* read-modify-write of the lock word, so interleaving it with the word's  *)
(* lock-free operations (the fast paths) at that one point is exact.       *)
(* ParkingLot.tla checks the bucket locks, the requeue lock order and the  *)
(* parker's arbitration that this module takes as given.                   *)
(*                                                                         *)
(* The lock word is three bits: locked, parked, designated (SYL1).  The    *)
(* interruptible mutex uses locked and parked only.  `own` is a ghost: the *)
(* thread the lock belongs to, set at acquisition or at handoff commit.    *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Procs,            \* simulated threads
  Kind,             \* "mutex" or "imutex": the lock
  Lockers,          \* threads that lock, run a critical section, unlock
  CondWaiters,      \* threads that lock, wait on the condition, unlock
  Notifiers,        \* threads that notify, holding the lock or not
  Timed,            \* Lockers: lockUntil; CondWaiters: waitUntil
  Interruptible,    \* threads cancellations are sent to; CondWaiters use
                    \* waitInterruptible
  StarvationBound,  \* SYM8
  EnableFork,       \* one fork (SYX1)
  EnableSpurious,   \* sleeps may return spuriously (late deliveries still do)
  \* Seeded faults; each must be reported (see check.sh).
  FaultNoHandoff,        \* SYM8's direct handoff is never made
  FaultPureValidate,     \* the park's validation only checks, never acquires
  FaultNoPassOn,         \* a designated waker that times out does not wake
  FaultTwoDesignated,    \* unlock wakes although a designation is pending
  FaultCancelBeatsGrant, \* a cancelled sleep ignores a committed handoff
  FaultInterruptibleReacquire \* a condition reacquires interruptibly

ASSUME
  /\ Kind \in {"mutex", "imutex"}
  /\ Lockers \cup CondWaiters \cup Notifiers = Procs
  /\ Lockers \cap CondWaiters = {} /\ Lockers \cap Notifiers = {}
  /\ CondWaiters \cap Notifiers = {}
  /\ Timed \subseteq Lockers \cup CondWaiters
  /\ Interruptible \subseteq Procs
  /\ StarvationBound \in 1..3

None == "none"
Dead == "dead"       \* the owner vanished in a fork
M == 1               \* the lock's key
C == 2               \* the condition's key
Keys == {M, C}

Range(s) == {s[i] : i \in DOMAIN s}
Without(s, x) == SelectSeq(s, LAMBDA y : y # x)

VARIABLES
  pc,        \* [Procs -> program counter]
  op,        \* [Procs -> the current operation's parameters]
  locked,    \* lock word: locked bit
  parked,    \* lock word: parked bit
  desig,     \* lock word: designated bit (Mutex only)
  cbound,    \* Condition state: non-null, bound to the lock (SYC1)
  own,       \* ghost: the lock's owner, None or Dead
  queue,     \* [Keys -> Seq(Procs)]
  rec,       \* [Procs -> waiter record]
  wflag,     \* [Procs -> BOOLEAN], the thread parker's word
  slp,       \* [Procs -> [intr, dl]], how the current sleep was armed
  res,       \* [Procs -> tentative sleep result]
  inflight,  \* SUBSET Procs: committed, undelivered wakes
  reg,       \* [Procs -> BOOLEAN]: registered designation under M (SYP15)
  creq,      \* [Procs -> BOOLEAN]: a pending cancellation request
  sel,       \* ghost [Procs -> BOOLEAN]: a notification selected the waiter
  nset,      \* ghost [Procs -> settle calls during the current operation]
  forked

vars == <<pc, op, locked, parked, desig, cbound, own, queue, rec, wflag, slp,
          res, inflight, reg, creq, sel, nset, forked>>
lockw == <<locked, parked, desig>>
parker == <<wflag, slp, res, inflight>>

\* phase: "none" in user code, "lock" while acquiring, "hold" while holding,
\* "cwait" while waiting on the condition.  ret: where a successful
\* acquisition continues.  cres: the condition wait's result.
NoOp == [phase |-> "none", dl |-> FALSE, intr |-> FALSE, lost |-> 0,
         ret |-> "cs", uret |-> "idle", cres |-> None]
NoRec == [key |-> 0, intr |-> FALSE, dl |-> FALSE, st |-> "idle",
          tok |-> None, hoff |-> FALSE, moved |-> FALSE]

Init ==
  /\ pc = [p \in Procs |-> "idle"]
  /\ op = [p \in Procs |-> NoOp]
  /\ locked = FALSE /\ parked = FALSE /\ desig = FALSE
  /\ cbound = FALSE
  /\ own = None
  /\ queue = [k \in Keys |-> << >>]
  /\ rec = [p \in Procs |-> NoRec]
  /\ wflag = [p \in Procs |-> FALSE]
  /\ slp = [p \in Procs |-> [intr |-> FALSE, dl |-> FALSE]]
  /\ res = [p \in Procs |-> None]
  /\ inflight = {}
  /\ reg = [p \in Procs |-> FALSE]
  /\ creq = [p \in Procs |-> FALSE]
  /\ sel = [p \in Procs |-> FALSE]
  /\ nset = [p \in Procs |-> 0]
  /\ forked = FALSE

-----------------------------------------------------------------------------
(* Helpers *)

Goto(p, l) == pc' = [pc EXCEPT ![p] = l]
TryLabel == IF Kind = "mutex" THEN "m_try" ELSE "i_try"

\* A designated bit is backed by a registration (SYP15); every bucket
\* section that touches registrations recomputes it, which both retires
\* and reconciles.
Backed(r) == \E q \in Procs : r[q]

\* Enqueue p's record under key k, at the head or the tail, and prepare.
Enqueue(p, k, r, atHead) ==
  /\ queue' = [queue EXCEPT ![k] = IF atHead THEN <<p>> \o @ ELSE Append(@, p)]
  /\ rec' = [rec EXCEPT ![p] = r]
  /\ wflag' = [wflag EXCEPT ![p] = FALSE]
  /\ slp' = [slp EXCEPT ![p] = [intr |-> r.intr, dl |-> r.dl]]

LockRec(p) == [NoRec EXCEPT !.key = M, !.intr = op[p].intr, !.dl = op[p].dl,
                            !.st = "queued"]

\* Start acquiring the lock; continue at ret on success.
StartLock(p, ret, dl, intr) ==
  op' = [op EXCEPT ![p] = [@ EXCEPT !.phase = "lock", !.dl = dl, !.intr = intr,
                                    !.lost = 0, !.ret = ret,
                                    !.cres = None]]

\* A successful acquisition continues at op.ret, holding the lock.
Acquired(p) ==
  /\ op' = [op EXCEPT ![p].phase = "hold"]
  /\ Goto(p, op[p].ret)

\* A failed acquisition (timeout or cancellation) returns to user code.  A
\* condition's reacquisition cannot fail (SYC3); if it did, the wait would
\* return without the lock: "c_lost" records that, and WaitReturn rejects it.
Failed(p, why) ==
  IF op[p].ret = "c_done"
  THEN Goto(p, "c_lost") /\ UNCHANGED op
  ELSE op' = [op EXCEPT ![p] = [NoOp EXCEPT !.cres = why]] /\ Goto(p, "idle")

-----------------------------------------------------------------------------
(* User programs *)

\* Lockers and CondWaiters start a lock; the critical section of a Locker
\* or a Notifier may run with the lock held.
UserLock(p) ==
  /\ pc[p] = "idle"
  /\ StartLock(p, "cs", p \in Lockers /\ p \in Timed, Kind = "imutex")
  /\ Goto(p, TryLabel)
  /\ nset' = [nset EXCEPT ![p] = 0]
  /\ UNCHANGED <<lockw, cbound, own, queue, rec, parker, reg, creq, sel,
                 forked>>

\* Every holder eventually releases (oracle 10's assumption).
Critical(p) ==
  /\ pc[p] = "cs"
  /\ IF p \in CondWaiters THEN Goto(p, "c_park") ELSE Goto(p, "unlock")
  /\ op' = [op EXCEPT ![p].uret = "idle"]
  /\ UNCHANGED <<lockw, cbound, own, queue, rec, parker, reg, creq, sel, nset,
                 forked>>

AfterWait(p) ==
  /\ pc[p] = "c_done"
  /\ Goto(p, "unlock")
  /\ op' = [op EXCEPT ![p].uret = "idle"]
  /\ UNCHANGED <<lockw, cbound, own, queue, rec, parker, reg, creq, sel, nset,
                 forked>>

-----------------------------------------------------------------------------
(* Mutex (SYM2–SYM9) *)

\* The compare-and-swap of a lock attempt (SYM2, SYM7: barging).
MTry(p) ==
  /\ pc[p] = "m_try"
  /\ IF ~locked
     THEN /\ locked' = TRUE /\ own' = p
          /\ IF reg[p] THEN /\ Goto(p, "m_retire") /\ UNCHANGED op
                       ELSE Acquired(p)
     ELSE /\ Goto(p, "m_park")
          /\ UNCHANGED <<locked, own, op>>
  /\ UNCHANGED <<parked, desig, cbound, queue, rec, parker, reg, creq, sel,
                 nset, forked>>

\* The designated waker that acquired retires its registration (SYP15).
MRetire(p) ==
  /\ pc[p] = "m_retire"
  /\ reg' = [reg EXCEPT ![p] = FALSE]
  /\ desig' = Backed(reg')
  /\ Acquired(p)
  /\ UNCHANGED <<locked, parked, cbound, own, queue, rec, parker, creq, sel,
                 nset, forked>>

\* park(M): under the bucket lock, retire any registration and reconcile
\* the designated bit (SYP15), then validate.  The validation is one
\* read-modify-write: held, set parked and enqueue; free, take it.  A
\* woken waiter that finds it held has lost a race (SYM8); the one that
\* reaches the bound parks at the head, to be handed the lock.
MPark(p) ==
  /\ pc[p] = "m_park"
  /\ LET lost == IF reg[p] THEN op[p].lost + 1 ELSE op[p].lost
         hoff == lost >= StarvationBound /\ ~FaultNoHandoff
         reg2 == [reg EXCEPT ![p] = FALSE]
     IN /\ reg' = reg2
        /\ desig' = Backed(reg2)
        /\ IF locked
           THEN /\ parked' = TRUE
                /\ Enqueue(p, M, [LockRec(p) EXCEPT !.hoff = hoff], hoff)
                /\ op' = [op EXCEPT ![p].lost = IF lost > StarvationBound
                                                THEN StarvationBound
                                                ELSE lost]
                /\ Goto(p, "sleep")
                /\ UNCHANGED <<locked, own>>
           ELSE IF FaultPureValidate
           THEN /\ Goto(p, "m_try")    \* invalid: try again
                /\ op' = [op EXCEPT ![p].lost = lost]
                /\ UNCHANGED <<locked, parked, own, queue, rec, wflag, slp>>
           ELSE /\ locked' = TRUE /\ own' = p
                /\ Acquired(p)
                /\ UNCHANGED <<parked, queue, rec, wflag, slp>>
  /\ UNCHANGED <<cbound, res, inflight, creq, sel, nset, forked>>

\* lockUntil's deadline passes while the caller runs (SYM3).  A designated
\* waker that gives up ends its designation and passes it on (SYM6).
MGiveUp(p) ==
  /\ pc[p] = "m_park" /\ op[p].phase = "lock" /\ op[p].dl
  /\ IF reg[p]
     THEN LET q == queue[M] IN
          IF q # << >> /\ ~FaultNoPassOn
          THEN LET h == Head(q) IN
               /\ queue' = [queue EXCEPT ![M] = Tail(q)]
               /\ rec' = [rec EXCEPT ![h].st = "dequeued", ![h].tok = "retry"]
               /\ inflight' = inflight \cup {h}
               /\ reg' = [reg EXCEPT ![p] = FALSE, ![h] = TRUE]
               /\ desig' = TRUE
               /\ parked' = (Tail(q) # << >>)
          ELSE /\ reg' = [reg EXCEPT ![p] = FALSE]
               /\ desig' = Backed([reg EXCEPT ![p] = FALSE])
               /\ UNCHANGED <<queue, rec, inflight, parked>>
     ELSE UNCHANGED <<queue, rec, inflight, reg, desig, parked>>
  /\ Failed(p, "timedOut")
  /\ UNCHANGED <<locked, cbound, own, wflag, slp, res, creq, sel, nset,
                 forked>>

\* unlock (SYM5, SYM6): one read-modify-write.  With nobody parked, or a
\* designated waker pending, it releases without touching the lot.
MUnlock(p) ==
  /\ pc[p] = "unlock" /\ Kind = "mutex"
  /\ own' = None
  /\ op' = [op EXCEPT ![p] = IF @.uret = "idle" THEN NoOp
                               ELSE [@ EXCEPT !.phase = "cwait"]]
  /\ IF ~parked \/ (desig /\ ~FaultTwoDesignated)
     THEN locked' = FALSE /\ Goto(p, op[p].uret)
     ELSE Goto(p, "m_unlock_slow") /\ UNCHANGED locked
  /\ UNCHANGED <<parked, desig, cbound, queue, rec, parker, reg, creq, sel,
                 nset, forked>>

\* The slow unlock, under M's bucket: hand off to a promoted head (SYM8),
\* else free the lock and designate the head (SYM6, SYM7); reconcile the
\* parked and designated bits against the queue (SYP15).
MUnlockSlow(p) ==
  /\ pc[p] = "m_unlock_slow"
  /\ LET q == queue[M] IN
       CASE desig /\ Backed(reg) /\ ~FaultTwoDesignated ->
              /\ locked' = FALSE
              /\ UNCHANGED <<parked, desig, own, queue, rec, inflight, reg>>
         [] q = << >> ->
              /\ locked' = FALSE /\ parked' = FALSE /\ desig' = Backed(reg)
              /\ UNCHANGED <<own, queue, rec, inflight, reg>>
         [] rec[Head(q)].hoff ->
              /\ own' = Head(q)
              /\ queue' = [queue EXCEPT ![M] = Tail(q)]
              /\ rec' = [rec EXCEPT ![Head(q)].st = "dequeued",
                                    ![Head(q)].tok = "handoff"]
              /\ inflight' = inflight \cup {Head(q)}
              /\ parked' = (Tail(q) # << >>)
              /\ desig' = Backed(reg)
              /\ UNCHANGED <<locked, reg>>
         [] OTHER ->
              /\ locked' = FALSE
              /\ queue' = [queue EXCEPT ![M] = Tail(q)]
              /\ rec' = [rec EXCEPT ![Head(q)].st = "dequeued",
                                    ![Head(q)].tok = "retry"]
              /\ inflight' = inflight \cup {Head(q)}
              /\ reg' = [reg EXCEPT ![Head(q)] = TRUE]
              /\ desig' = TRUE
              /\ parked' = (Tail(q) # << >>)
              /\ UNCHANGED own
  /\ Goto(p, op[p].uret)
  /\ UNCHANGED <<op, cbound, wflag, slp, res, creq, sel, nset, forked>>

-----------------------------------------------------------------------------
(* InterruptibleMutex (SYJ1–SYJ5) *)

ITry(p) ==
  /\ pc[p] = "i_try"
  /\ IF ~locked
     THEN locked' = TRUE /\ own' = p /\ Acquired(p)
     ELSE Goto(p, "i_park") /\ UNCHANGED <<locked, own, op>>
  /\ UNCHANGED <<parked, desig, cbound, queue, rec, parker, reg, creq, sel,
                 nset, forked>>

\* park(M), FIFO at the tail; interruptible and timed as the operation is.
IPark(p) ==
  /\ pc[p] = "i_park"
  /\ IF locked
     THEN /\ parked' = TRUE
          /\ Enqueue(p, M, LockRec(p), FALSE)
          /\ Goto(p, "sleep")
          /\ UNCHANGED <<locked, own, op>>
     ELSE /\ locked' = TRUE /\ own' = p
          /\ Acquired(p)
          /\ UNCHANGED <<parked, queue, rec, wflag, slp>>
  /\ UNCHANGED <<desig, cbound, res, inflight, reg, creq, sel, nset, forked>>

\* Guard destruction: with waiters parked, hand the lock to the head
\* (SYJ5); the handoff is committed under the bucket lock (SYJ3).
IUnlock(p) ==
  /\ pc[p] = "unlock" /\ Kind = "imutex"
  /\ own' = None
  /\ op' = [op EXCEPT ![p] = IF @.uret = "idle" THEN NoOp
                               ELSE [@ EXCEPT !.phase = "cwait"]]
  /\ IF ~parked
     THEN locked' = FALSE /\ Goto(p, op[p].uret)
     ELSE Goto(p, "i_unlock_slow") /\ UNCHANGED locked
  /\ UNCHANGED <<parked, desig, cbound, queue, rec, parker, reg, creq, sel,
                 nset, forked>>

IUnlockSlow(p) ==
  /\ pc[p] = "i_unlock_slow"
  /\ LET q == queue[M] IN
       IF q = << >>
       THEN /\ locked' = FALSE /\ parked' = FALSE
            /\ UNCHANGED <<own, queue, rec, inflight>>
       ELSE /\ own' = Head(q)
            /\ queue' = [queue EXCEPT ![M] = Tail(q)]
            /\ rec' = [rec EXCEPT ![Head(q)].st = "dequeued",
                                  ![Head(q)].tok = "handoff"]
            /\ inflight' = inflight \cup {Head(q)}
            /\ parked' = (Tail(q) # << >>)
            /\ UNCHANGED locked
  /\ Goto(p, op[p].uret)
  /\ UNCHANGED <<op, desig, cbound, wflag, slp, res, reg, creq, sel, nset,
                 forked>>

-----------------------------------------------------------------------------
(* Condition (SYC1–SYC9) *)

\* wait: park(C) with validation that binds the condition to the lock
\* (SYC1, SYC4); beforeSleep releases the lock (SYP3, SYC2).
CPark(p) ==
  /\ pc[p] = "c_park"
  /\ cbound' = TRUE
  /\ Enqueue(p, C, [NoRec EXCEPT !.key = C, !.st = "queued",
                                 !.intr = p \in Interruptible,
                                 !.dl = p \in Timed], FALSE)
  /\ sel' = [sel EXCEPT ![p] = FALSE]
  /\ nset' = [nset EXCEPT ![p] = 0]
  /\ op' = [op EXCEPT ![p].uret = "sleep", ![p].cres = None]
  /\ Goto(p, "unlock")
  /\ UNCHANGED <<lockw, own, res, inflight, reg, creq, forked>>

\* A record moved onto the lock's queue continues as the lock's waiter: it
\* is non-interruptible and has no deadline (SYP14).
MovedRec(r) == [r EXCEPT !.key = M, !.intr = FALSE, !.dl = FALSE,
                         !.moved = TRUE, !.hoff = FALSE]

\* notifyOne / notifyAll (SYC5, SYC6, SYC8).  With no waiters, one load.
\* Otherwise one requeue under both buckets (SYP8): move onto a held lock;
\* on a free lock wake one and move the rest, or, for a handoff lock,
\* acquire it for the woken waiter.  The condition is reconciled to null
\* once its queue is empty.
Notify(p, all) ==
  /\ IF ~cbound
     THEN UNCHANGED <<lockw, cbound, own, queue, rec, inflight, sel>>
     ELSE LET q == queue[C]
              S == IF q = << >> THEN << >>
                   ELSE IF all THEN q ELSE <<Head(q)>>
              rest == IF q = << >> THEN << >>
                      ELSE IF all THEN << >> ELSE Tail(q)
              h == S[1]
              moveAll == locked
              W == IF moveAll \/ S = << >> THEN {} ELSE {h}
              Mv == IF moveAll THEN S ELSE IF S = << >> THEN << >> ELSE Tail(S)
              tok == IF Kind = "imutex" /\ all THEN "handoff" ELSE "notified"
          IN /\ sel' = [r \in Procs |-> sel[r] \/ r \in Range(S)]
             /\ queue' = [queue EXCEPT ![C] = rest, ![M] = @ \o Mv]
             /\ rec' = [r \in Procs |->
                          CASE r \in W ->
                                 [rec[r] EXCEPT !.st = "dequeued", !.tok = tok]
                            [] r \in Range(Mv) -> MovedRec(rec[r])
                            [] OTHER -> rec[r]]
             /\ inflight' = inflight \cup W
             /\ parked' = (parked \/ Mv # << >>)
             /\ cbound' = (rest # << >>)
             /\ IF W # {} /\ tok = "handoff"
                THEN locked' = TRUE /\ own' = h
                ELSE UNCHANGED <<locked, own>>
             /\ UNCHANGED desig
  /\ UNCHANGED <<pc, op, wflag, slp, res, reg, creq, nset, forked>>

NotifyFree(p) ==
  /\ p \in Notifiers /\ pc[p] = "idle"
  /\ \E all \in BOOLEAN : Notify(p, all)

NotifyHeld(p) ==
  /\ p \in Notifiers /\ pc[p] = "cs"
  /\ \E all \in BOOLEAN : Notify(p, all)

-----------------------------------------------------------------------------
(* The parker, and the parking lot's arbitration (SYP4, SYP5, SYI3) *)

SleepResult(p, r) ==
  /\ res' = [res EXCEPT ![p] = r]
  /\ Goto(p, "res")
  /\ UNCHANGED <<op, lockw, cbound, own, queue, rec, wflag, slp, inflight, reg,
                 creq, sel, nset, forked>>

SleepWake(p) == pc[p] = "sleep" /\ wflag[p] /\ SleepResult(p, "woken")
SleepSpurious(p) ==
  EnableSpurious /\ pc[p] = "sleep" /\ SleepResult(p, "woken")
SleepTimeout(p) == pc[p] = "sleep" /\ slp[p].dl /\ SleepResult(p, "timedOut")
SleepCancel(p) ==
  pc[p] = "sleep" /\ slp[p].intr /\ creq[p] /\ SleepResult(p, "cancelled")

\* The condition wait reacquires the lock, never interruptibly (SYC3,
\* SYJ1), whatever woke it.
Reacquire(p, cres) ==
  /\ op' = [op EXCEPT ![p] = [@ EXCEPT !.phase = "lock", !.dl = FALSE,
                                       !.intr = FaultInterruptibleReacquire
                                                /\ Kind = "imutex",
                                       !.lost = 0, !.ret = "c_done",
                                       !.cres = cres]]
  /\ Goto(p, TryLabel)

\* A record an unparker dequeued: the token decides how the park's caller
\* continues.  A condition waiter that was selected reports a notification
\* (SYC7) and continues as the lock's waiter (SYC2).
Unparked(p) ==
  LET tok == rec[p].tok
      cw == op[p].phase = "cwait"
  IN CASE tok = "handoff" ->
            IF cw THEN /\ op' = [op EXCEPT ![p].phase = "hold",
                                           ![p].cres = "notified"]
                       /\ Goto(p, "c_done")
                  ELSE Acquired(p)
       [] tok = "retry" ->
            /\ op' = IF cw THEN [op EXCEPT ![p].phase = "lock", ![p].dl = FALSE,
                                           ![p].intr = FALSE, ![p].lost = 0,
                                           ![p].ret = "c_done",
                                           ![p].cres = "notified"]
                     ELSE op
            /\ Goto(p, "m_try")
       [] OTHER -> Reacquire(p, "notified")

Resolve(p) ==
  /\ pc[p] = "res"
  /\ LET k == rec[p].key
         dq == [queue EXCEPT ![k] = Without(@, p)]
         cw == op[p].phase = "cwait"
         \* the removal's callback: the key's queue-derived bit
         after == /\ queue' = dq
                  /\ rec' = [rec EXCEPT ![p] = NoRec]
                  /\ IF k = M THEN parked' = (dq[M] # << >>) /\ cbound' = cbound
                     ELSE cbound' = (dq[C] # << >>) /\ parked' = parked
     IN CASE rec[p].st = "dequeued" ->
               IF FaultCancelBeatsGrant /\ res[p] = "cancelled" /\ ~cw
               THEN /\ Failed(p, "cancelled")
                    /\ nset' = [nset EXCEPT ![p] = @ + 1]
                    /\ creq' = [creq EXCEPT ![p] = FALSE]
                    /\ rec' = [rec EXCEPT ![p] = NoRec]
                    /\ UNCHANGED <<parked, cbound, queue, slp, wflag>>
               ELSE /\ Unparked(p)
                    /\ rec' = [rec EXCEPT ![p] = NoRec]
                    /\ UNCHANGED <<parked, cbound, queue, slp, wflag, creq,
                                   nset>>
          [] res[p] = "timedOut" /\ rec[p].dl ->
               /\ after
               /\ IF cw THEN Reacquire(p, "timedOut")
                  ELSE Failed(p, "timedOut")
               /\ UNCHANGED <<slp, wflag, creq, nset>>
          [] res[p] = "cancelled" /\ rec[p].intr ->
               /\ after
               /\ nset' = [nset EXCEPT ![p] = @ + 1]   \* settle (SYI3)
               /\ creq' = [creq EXCEPT ![p] = FALSE]
               /\ IF cw THEN Reacquire(p, "cancelled")
                  ELSE Failed(p, "cancelled")
               /\ UNCHANGED <<slp, wflag>>
          [] OTHER ->
               \* spurious: prepare again, armed as the record now says
               /\ wflag' = [wflag EXCEPT ![p] = FALSE]
               /\ slp' = [slp EXCEPT ![p] =
                            [intr |-> rec[p].intr, dl |-> rec[p].dl]]
               /\ Goto(p, "sleep")
               /\ UNCHANGED <<op, parked, cbound, queue, rec, creq, nset>>
  /\ UNCHANGED <<locked, desig, own, res, inflight, reg, sel, forked>>

-----------------------------------------------------------------------------
(* The environment *)

\* Deliveries name the waiter's parker word, never its record (SYK8).
Deliver(q) ==
  /\ q \in inflight
  /\ inflight' = inflight \ {q}
  /\ wflag' = [wflag EXCEPT ![q] = TRUE]
  /\ UNCHANGED <<pc, op, lockw, cbound, own, queue, rec, slp, res, reg, creq,
                 sel, nset, forked>>

CancelArrives(p) ==
  /\ p \in Interruptible /\ ~creq[p]
  /\ creq' = [creq EXCEPT ![p] = TRUE]
  /\ UNCHANGED <<pc, op, lockw, cbound, own, queue, rec, parker, reg, sel,
                 nset, forked>>

\* SYX1: the forking thread continues in user code; the others vanish and
\* the child starts fresh threads.  The table is reset; the lock word and
\* the condition are memory and keep their bits.  A lock held by anyone
\* but the forking thread, or being released, stays held.
Fork(f) ==
  /\ EnableFork /\ ~forked /\ pc[f] \in {"idle", "cs"}
  /\ forked' = TRUE
  /\ own' = IF locked /\ own # f THEN Dead ELSE own
  /\ pc' = [p \in Procs |-> IF p = f THEN pc[f] ELSE "idle"]
  /\ op' = [p \in Procs |-> IF p = f THEN op[f] ELSE NoOp]
  /\ queue' = [k \in Keys |-> << >>]
  /\ rec' = [p \in Procs |-> NoRec]
  /\ wflag' = [p \in Procs |-> FALSE]
  /\ slp' = [p \in Procs |-> [intr |-> FALSE, dl |-> FALSE]]
  /\ res' = [p \in Procs |-> None]
  /\ inflight' = {}
  /\ reg' = [p \in Procs |-> FALSE]
  /\ creq' = [p \in Procs |-> p = f /\ creq[f]]
  /\ sel' = [p \in Procs |-> FALSE]
  /\ nset' = [p \in Procs |-> 0]
  /\ UNCHANGED <<lockw, cbound>>

-----------------------------------------------------------------------------

Steps(p) ==
  \/ Critical(p) \/ AfterWait(p)
  \/ MTry(p) \/ MRetire(p) \/ MPark(p) \/ MUnlock(p) \/ MUnlockSlow(p)
  \/ ITry(p) \/ IPark(p) \/ IUnlock(p) \/ IUnlockSlow(p)
  \/ CPark(p) \/ NotifyHeld(p)
  \/ SleepWake(p) \/ Resolve(p)

Choices(p) == UserLock(p) \/ NotifyFree(p)

Env(p) ==
  \/ MGiveUp(p) \/ SleepSpurious(p) \/ SleepTimeout(p) \/ SleepCancel(p)
  \/ Deliver(p) \/ CancelArrives(p) \/ Fork(p)

\* A child whose lock was held by a vanished thread waits forever, as POSIX
\* says it must (SYX1): that is not a deadlock of the protocol.
Stuck == forked /\ own = Dead

Next ==
  \/ \E p \in Procs : Steps(p) \/ Choices(p) \/ Env(p)
  \/ Stuck /\ UNCHANGED vars

\* Every loop keeps running, every holder releases, every committed wake is
\* delivered: weak fairness only.
Fairness == \A p \in Procs : WF_vars(Steps(p)) /\ WF_vars(Deliver(p))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Safety *)

Holding(p) ==
  pc[p] \in {"cs", "c_park", "c_done", "unlock", "m_retire"}
  /\ op[p].phase = "hold"

\* Mutual exclusion: the lock has one owner, every thread in a critical
\* section is it, and an owned lock is locked.  A handoff in flight belongs
\* to its waiter (SYM8, SYJ3).
MutualExclusion ==
  /\ \A p \in Procs : Holding(p) => own = p
  /\ own # None => locked
  /\ own \in Procs =>
       \/ Holding(own)
       \/ rec[own].st = "dequeued" /\ rec[own].tok = "handoff"
          /\ pc[own] \in {"sleep", "res"}
       \/ pc[own] = "m_retire"

\* SYK4, SYP14: records are queued once, under the key they record.
QueueConsistent ==
  /\ \A k1, k2 \in Keys : \A i \in DOMAIN queue[k1], j \in DOMAIN queue[k2] :
       queue[k1][i] = queue[k2][j] => k1 = k2 /\ i = j
  /\ \A p \in Procs :
       rec[p].st = "queued" <=> \E k \in Keys : p \in Range(queue[k])
  /\ \A k \in Keys : \A p \in Range(queue[k]) : rec[p].key = k
  \* a moved record only reacquires
  /\ \A p \in Range(queue[M]) : rec[p].moved => ~rec[p].intr /\ ~rec[p].dl

\* SYM6: at most one designated waker; the designated bit is exactly the
\* registrations behind it, except for what a fork leaves to reconcile.
Designation ==
  /\ Cardinality({p \in Procs : reg[p]}) <= 1
  /\ ~forked => (desig <=> Backed(reg))
  /\ \A p \in Procs : reg[p] => Kind = "mutex"

\* SYP15: the parked bit is backed by the queue (a fork may leave it stale).
ParkedBit == ~forked => (parked <=> queue[M] # << >>)

\* SYC1, SYC8: the condition is bound exactly while it has waiters.
ConditionBit == ~forked => (cbound <=> queue[C] # << >>)

\* SYM8: only the head is promoted, and it parked there.
HandoffAtHead ==
  \A i \in DOMAIN queue[M] : rec[queue[M][i]].hoff => i = 1

\* SYJ5: a handoff lock with waiters is never free.
HandoffLockNeverFreeWithWaiters ==
  Kind = "imutex" => (queue[M] # << >> => locked)

\* No lost wakeup: waiters parked on a free lock always have someone on the
\* way to it: a designated waker, or a woken condition waiter.
NoLostWakeup ==
  (queue[M] # << >> /\ ~locked) =>
    \E p \in Procs :
      \/ reg[p]
      \/ rec[p].st = "dequeued" /\ rec[p].tok = "notified"
      \/ op[p].phase = "lock" /\ op[p].ret = "c_done"
         /\ pc[p] \in {"m_try", "i_try", "m_park", "i_park"}

\* SYC2, SYC3, SYC7, SYI3: a condition wait returns holding the lock; it
\* reports a notification exactly when one selected it; settle ran once
\* exactly when it ended cancelled.
WaitReturn ==
  \A p \in Procs : pc[p] # "c_lost" /\ (pc[p] = "c_done" =>
    /\ own = p
    /\ (op[p].cres = "notified") <=> sel[p]
    /\ nset[p] = (IF op[p].cres = "cancelled" THEN 1 ELSE 0))

\* SYI3 for the lock operation: settle only when it ended cancelled, which
\* leaves it in user code without the lock.
SettleOnce == \A p \in Procs : nset[p] <= 1

\* SYX1: a lock held at the fork stays held in the child.
HeldStaysHeld == own = Dead => locked

Safety ==
  /\ MutualExclusion /\ QueueConsistent /\ Designation /\ ParkedBit
  /\ ConditionBit /\ HandoffAtHead /\ HandoffLockNeverFreeWithWaiters
  /\ NoLostWakeup /\ WaitReturn /\ SettleOnce /\ HeldStaysHeld

(* Witnesses, expected to be violated. *)

\* A lock operation or a condition wait ends by timeout or cancellation.
NoWithdrawal ==
  \A p \in Procs :
    /\ ~(pc[p] = "idle" /\ op[p].cres \in {"timedOut", "cancelled"})
    /\ ~(pc[p] = "c_done" /\ op[p].cres \in {"timedOut", "cancelled"})

\* SYM8: a promoted waiter is handed the lock.
NoHandoff == \A p \in Procs : ~(rec[p].st = "dequeued" /\ rec[p].tok = "handoff"
                                /\ Kind = "mutex")

\* SYJ3: a cancellation loses to a committed handoff.
NoBatonPass ==
  \A p \in Procs : ~(pc[p] = "res" /\ res[p] = "cancelled"
                     /\ rec[p].st = "dequeued")

-----------------------------------------------------------------------------
(* Liveness *)

\* SYM8, SYJ5: every lock operation ends: acquired, or withdrawn by timeout
\* or cancellation.
AcquisitionsEnd ==
  \A p \in Procs : (op[p].phase = "lock") ~> (op[p].phase # "lock" \/ Stuck)

\* SYM6, SYP15: no designation lasts forever.
DesignationsEnd == \A p \in Procs : reg[p] ~> ~reg[p]

\* SYM6, SYP15: a designated bit with waiters parked behind it clears: by
\* its waker acquiring or parking again, or, when a fork left it stale, by
\* the next park, which reconciles it.
DesignatedBitClears ==
  (desig /\ queue[M] # << >>) ~> (~desig \/ queue[M] = << >>)

\* SYC7: every selected condition waiter returns (holding the lock).
SelectedReturn ==
  \A p \in Procs :
    (op[p].phase = "cwait" /\ sel[p]) ~> (pc[p] = "c_done" \/ Stuck)

=============================================================================
