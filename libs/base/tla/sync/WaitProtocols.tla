---------------------------- MODULE WaitProtocols ----------------------------
(***************************************************************************)
(* Oracle 10, part S3: the Semaphore and RwLock protocols of              *)
(* docs/specs/base/sync/primitives.md §7 and §9, over the parking lot of   *)
(* SPEC.md §3, written from the specification.                             *)
(*                                                                         *)
(* As in LockProtocols.tla, every parking-lot operation is one atomic      *)
(* step that performs at most one read-modify-write of the primitive's     *)
(* word.  A wake is committed under the bucket lock: the record leaves the *)
(* queue with its token, and from then on its timeout cannot win (SYP5);   *)
(* the waiter returns with the token at a later step.  ParkingLot.tla      *)
(* checks the delivery, arbitration and bucket locks this takes as given.  *)
(*                                                                         *)
(* Every thread loops forever, so the liveness properties are about        *)
(* unbounded runs: under weak fairness, every waiter whose wait has no     *)
(* deadline acquires.  A thread in Timed may also give up while its record *)
(* is queued; for the semaphore, a cancellation behaves the same way.      *)
(*                                                                         *)
(* Semaphore (Kind = "semaphore"): every thread acquires one permit, holds *)
(* it, and releases it.  RwLock (Kind = "rwlock"): Readers take shared     *)
(* mode, Writers exclusive mode, Upgraders upgradable mode; those in       *)
(* Upgrading upgrade to exclusive before they release.                     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets, TLC

CONSTANTS
  Procs,
  Kind,             \* "semaphore" or "rwlock"
  Permits,          \* the semaphore's initial count
  Readers, Writers, Upgraders, Upgrading,
  Timed,            \* threads whose waits have a deadline
  \* Seeded faults; each must be reported (see check.sh).
  FaultRaiseCount,          \* a release raises the count past parked waiters
  FaultTimeoutDrops,        \* a timeout after a handoff drops the permit
  FaultReadersBarge,        \* shared acquirers ignore the parked bit
  FaultNoDrainWake,         \* the last reader does not wake a pending upgrade
  FaultGrantOverUpgradable  \* a pass grants a writer past an upgradable holder

ASSUME
  /\ Kind \in {"semaphore", "rwlock"}
  /\ Kind = "rwlock" => Readers \cup Writers \cup Upgraders = Procs
  /\ Readers \cap Writers = {} /\ Readers \cap Upgraders = {}
  /\ Writers \cap Upgraders = {}
  /\ Upgrading \subseteq Upgraders
  /\ Timed \subseteq Procs
  /\ Permits \in 1..3

None == "none"
Range(s) == {s[i] : i \in DOMAIN s}
Without(s, x) == SelectSeq(s, LAMBDA y : y # x)

VARIABLES
  pc,        \* [Procs -> program counter]
  count,     \* Semaphore: the permit count
  parked,    \* the parked bit of either word
  writer,    \* RwLock: the writer bit (exclusive held, or pending a drain)
  upg,       \* RwLock: the upgradable bit
  readers,   \* RwLock: the reader count
  queue,     \* Seq(Procs): the main key's queue
  dq,        \* Seq(Procs): the RwLock's drain key's queue (SYR4)
  tok,       \* [Procs -> token]: "handoff" once a wake is committed
  wd         \* ghost: a waiter withdrew by timeout

vars == <<pc, count, parked, writer, upg, readers, queue, dq, tok, wd>>

Init ==
  /\ pc = [p \in Procs |-> "idle"]
  /\ count = Permits
  /\ parked = FALSE
  /\ writer = FALSE /\ upg = FALSE /\ readers = 0
  /\ queue = << >> /\ dq = << >>
  /\ tok = [p \in Procs |-> None]
  /\ wd = FALSE

Goto(p, l) == pc' = [pc EXCEPT ![p] = l]
Queued(p) == p \in Range(queue)
Granted(p) == tok[p] = "handoff"

-----------------------------------------------------------------------------
(* Semaphore (SYS1-SYS5) *)

\* tryAcquire: take a permit if one is available, else park.
SIdle(p) ==
  /\ pc[p] = "idle"
  /\ IF count > 0
     THEN count' = count - 1 /\ Goto(p, "hold")
     ELSE Goto(p, "park") /\ UNCHANGED count
  /\ UNCHANGED <<parked, writer, upg, readers, queue, dq, tok, wd>>

\* park: the validation takes a permit that is free, else sets the parked
\* bit and enqueues.
SPark(p) ==
  /\ pc[p] = "park"
  /\ IF count > 0
     THEN count' = count - 1 /\ Goto(p, "hold")
          /\ UNCHANGED <<parked, queue>>
     ELSE parked' = TRUE /\ queue' = Append(queue, p) /\ Goto(p, "sleep")
          /\ UNCHANGED count
  /\ UNCHANGED <<writer, upg, readers, dq, tok, wd>>

\* The handed-off waiter returns owning the permit (SYS3).
SWake(p) ==
  /\ pc[p] = "sleep" /\ ~Queued(p) /\ Granted(p)
  /\ tok' = [tok EXCEPT ![p] = None]
  /\ Goto(p, "hold")
  /\ UNCHANGED <<count, parked, writer, upg, readers, queue, dq, wd>>

\* A deadline or a cancellation wins only while the record is queued; the
\* parked bit follows the queue (SYP15).  The fault lets it win after a
\* handoff, dropping the permit.
STimeout(p) ==
  /\ p \in Timed /\ pc[p] = "sleep"
  /\ \/ /\ Queued(p)
        /\ queue' = Without(queue, p)
        /\ parked' = (queue' # << >>)
        /\ wd' = TRUE
        /\ UNCHANGED tok
     \/ /\ FaultTimeoutDrops /\ ~Queued(p) /\ Granted(p)
        /\ tok' = [tok EXCEPT ![p] = None]
        /\ UNCHANGED <<queue, parked, wd>>
  /\ Goto(p, "idle")
  /\ UNCHANGED <<count, writer, upg, readers, dq>>

\* release(1): with nobody parked, raise the count; otherwise hand the
\* permit to the head of the queue (SYS3).
SRelease(p) ==
  /\ pc[p] = "hold"
  /\ IF ~parked
     THEN count' = count + 1 /\ UNCHANGED <<parked, queue, tok>>
     ELSE IF queue # << >> /\ ~FaultRaiseCount
     THEN LET h == Head(queue) IN
          /\ queue' = Tail(queue)
          /\ tok' = [tok EXCEPT ![h] = "handoff"]
          /\ parked' = (Tail(queue) # << >>)
          /\ UNCHANGED count
     ELSE /\ count' = count + 1
          /\ parked' = IF FaultRaiseCount THEN parked ELSE FALSE
          /\ UNCHANGED <<queue, tok>>
  /\ Goto(p, "idle")
  /\ UNCHANGED <<writer, upg, readers, dq, wd>>

SStep(p) == SIdle(p) \/ SPark(p) \/ SWake(p) \/ STimeout(p) \/ SRelease(p)

-----------------------------------------------------------------------------
(* RwLock (SYR1-SYR7) *)

Mode(p) == IF p \in Readers THEN "S" ELSE IF p \in Writers THEN "X" ELSE "U"

\* Whether a mode is compatible with the word, ignoring the queue.
Admits(m, w, u) == IF m = "S" THEN ~w ELSE ~w /\ ~u

\* An acquisition from the word with nobody queued ahead: the new values
\* and where the acquirer continues; exclusive mode with readers present
\* sets the writer bit and drains (SYR4).
Acquire(p) ==
  CASE Mode(p) = "S" -> /\ readers' = readers + 1 /\ Goto(p, "holdS")
                        /\ UNCHANGED <<writer, upg>>
    [] Mode(p) = "U" -> /\ upg' = TRUE /\ Goto(p, "holdU")
                        /\ UNCHANGED <<writer, readers>>
    [] OTHER         -> /\ writer' = TRUE
                        /\ Goto(p, IF readers = 0 THEN "holdX" ELSE "drain")
                        /\ UNCHANGED <<upg, readers>>

\* The fast paths fail while anyone is parked (SYR3); the fault lets
\* shared acquirers through.
RIdle(p) ==
  /\ pc[p] = "idle"
  /\ IF Admits(Mode(p), writer, upg)
        /\ (~parked \/ (FaultReadersBarge /\ Mode(p) = "S"))
     THEN Acquire(p)
     ELSE Goto(p, "park") /\ UNCHANGED <<writer, upg, readers>>
  /\ UNCHANGED <<count, parked, queue, dq, tok, wd>>

\* park: acquire if nobody is queued and the mode is admitted, else set
\* the parked bit and enqueue behind everyone.
RPark(p) ==
  /\ pc[p] = "park"
  /\ IF queue = << >> /\ Admits(Mode(p), writer, upg)
     THEN Acquire(p) /\ UNCHANGED <<parked, queue>>
     ELSE /\ parked' = TRUE /\ queue' = Append(queue, p) /\ Goto(p, "sleep")
          /\ UNCHANGED <<writer, upg, readers>>
  /\ UNCHANGED <<count, dq, tok, wd>>

\* A waiter a pass granted its mode returns holding it.
RWake(p) ==
  /\ pc[p] = "sleep" /\ ~Queued(p) /\ Granted(p)
  /\ tok' = [tok EXCEPT ![p] = None]
  /\ Goto(p, CASE Mode(p) = "S" -> "holdS" [] Mode(p) = "U" -> "holdU"
                  [] OTHER -> "holdX")
  /\ UNCHANGED <<count, parked, writer, upg, readers, queue, dq, wd>>

(* The release pass (SYR5): from the word without the releaser's mode,  *)
(* grant the head of the queue one exclusive waiter, or every shared     *)
(* waiter and at most one upgradable waiter up to the first writer.      *)
RECURSIVE Pass(_, _, _, _, _, _)
\* s: [w, u, r, ex]; q: the queue still to offer; kept: the records left
Pass(w, u, r, ex, q, kept) ==
  IF q = << >> THEN [w |-> w, u |-> u, r |-> r, kept |-> kept, done |-> TRUE]
  ELSE LET h == Head(q)
           m == Mode(h)
           stop == [w |-> w, u |-> u, r |-> r, kept |-> kept \o q, done |-> TRUE]
       IN IF ex THEN stop
          ELSE IF m = "X"
          THEN IF w \/ (u /\ ~FaultGrantOverUpgradable) \/ r > 0 THEN stop
               ELSE Pass(TRUE, u, r, TRUE, Tail(q), kept)
          ELSE IF m = "S"
          THEN IF w THEN stop ELSE Pass(w, u, r + 1, ex, Tail(q), kept)
          ELSE IF w THEN stop
          ELSE IF u THEN Pass(w, u, r, ex, Tail(q), Append(kept, h))
          ELSE Pass(w, TRUE, r, ex, Tail(q), kept)

\* Replace the releaser's bits with (w, u, r), granting from the queue.
Release(w, u, r) ==
  IF ~parked
  THEN /\ writer' = w /\ upg' = u /\ readers' = r
       /\ UNCHANGED <<parked, queue, tok>>
  ELSE LET g == Pass(w, u, r, FALSE, queue, << >>)
           woken == Range(queue) \ Range(g.kept)
       IN /\ writer' = g.w /\ upg' = g.u /\ readers' = g.r
          /\ queue' = g.kept
          /\ parked' = (g.kept # << >>)
          /\ tok' = [q \in Procs |-> IF q \in woken THEN "handoff" ELSE tok[q]]

\* The writer bit is set: wait on the drain key for the readers to leave.
RDrain(p) ==
  /\ pc[p] = "drain"
  /\ IF readers > 0
     THEN dq' = Append(dq, p) /\ Goto(p, "dsleep")
     ELSE Goto(p, "holdX") /\ UNCHANGED dq
  /\ UNCHANGED <<count, parked, writer, upg, readers, queue, tok, wd>>

RDWake(p) ==
  /\ pc[p] = "dsleep" /\ ~(p \in Range(dq)) /\ Granted(p)
  /\ tok' = [tok EXCEPT ![p] = None]
  /\ Goto(p, IF readers = 0 THEN "holdX" ELSE "drain")
  /\ UNCHANGED <<count, parked, writer, upg, readers, queue, dq, wd>>

\* A deadline passes while queued on the main key: withdraw; the waiters
\* behind may then be admitted, so a pass follows (SYR7).
RTimeout(p) ==
  /\ p \in Timed /\ pc[p] = "sleep" /\ Queued(p)
  /\ queue' = Without(queue, p)
  /\ parked' = (queue' # << >>)
  /\ wd' = TRUE
  /\ Goto(p, "repass")
  /\ UNCHANGED <<count, writer, upg, readers, dq, tok>>

RRepass(p) ==
  /\ pc[p] = "repass"
  /\ Release(writer, upg, readers)
  /\ Goto(p, "idle")
  /\ UNCHANGED <<count, dq, wd>>

\* A drain's deadline passes: give the writer bit back.  An upgrader keeps
\* upgradable mode (SYR4); either way the queue may now be admitted.
RDTimeout(p) ==
  /\ p \in Timed /\ pc[p] = "dsleep" /\ p \in Range(dq)
  /\ dq' = Without(dq, p)
  /\ wd' = TRUE
  /\ IF p \in Upgraders
     THEN Release(FALSE, TRUE, readers) /\ Goto(p, "holdU2")
     ELSE Release(FALSE, upg, readers) /\ Goto(p, "idle")
  /\ UNCHANGED count

\* unlockShared: the last reader runs the pass, or, with a drain pending,
\* wakes the drainer (SYR7).
RUnlockS(p) ==
  /\ pc[p] = "holdS"
  /\ IF readers = 1 /\ parked /\ ~writer
     THEN Release(writer, upg, 0) /\ UNCHANGED dq
     ELSE /\ readers' = readers - 1
          /\ IF readers = 1 /\ writer /\ dq # << >> /\ ~FaultNoDrainWake
             THEN /\ dq' = Tail(dq)
                  /\ tok' = [tok EXCEPT ![Head(dq)] = "handoff"]
             ELSE UNCHANGED <<dq, tok>>
          /\ UNCHANGED <<writer, upg, parked, queue>>
  /\ Goto(p, "idle")
  /\ UNCHANGED <<count, wd>>

RUnlockX(p) ==
  /\ pc[p] = "holdX"
  /\ Release(FALSE, upg, readers)
  /\ Goto(p, "idle")
  /\ UNCHANGED <<count, dq, wd>>

\* An upgradable holder upgrades (if in Upgrading, the first time) or
\* releases; holdU2 is upgradable mode after an upgrade timed out.
RHoldU(p) ==
  /\ pc[p] \in {"holdU", "holdU2"}
  /\ IF p \in Upgrading /\ pc[p] = "holdU"
     THEN /\ upg' = FALSE /\ writer' = TRUE
          /\ Goto(p, IF readers = 0 THEN "holdX" ELSE "drain")
          /\ UNCHANGED <<readers, parked, queue, tok>>
     ELSE Release(writer, FALSE, readers) /\ Goto(p, "idle")
  /\ UNCHANGED <<count, dq, wd>>

RStep(p) == RIdle(p) \/ RPark(p) \/ RWake(p) \/ RDrain(p) \/ RDWake(p)
            \/ RTimeout(p) \/ RRepass(p) \/ RDTimeout(p) \/ RUnlockS(p)
            \/ RUnlockX(p) \/ RHoldU(p)

-----------------------------------------------------------------------------

Step(p) == IF Kind = "semaphore" THEN SStep(p) ELSE RStep(p)

Next == \E p \in Procs : Step(p)

Fairness == \A p \in Procs : WF_vars(Step(p))

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Invariants *)

TypeOK ==
  /\ count \in 0..Permits
  /\ readers \in 0..Cardinality(Procs)
  /\ \A p \in Procs : tok[p] \in {None, "handoff"}

\* SYS4: available plus handed off plus held is the initial count.
Handed == {p \in Procs : pc[p] = "sleep" /\ ~Queued(p) /\ Granted(p)}
Holders == {p \in Procs : pc[p] = "hold"}
SemBalance == Kind = "semaphore" =>
  count + Cardinality(Handed) + Cardinality(Holders) = Permits

\* No permit is left in the count while a waiter is parked (SYS3).
NoStrandedPermit == Kind = "semaphore" => (queue # << >> => count = 0)

\* The parked bit is backed by the queue (SYP15).
ParkedBit == parked <=> queue # << >>

InMode(m) == {p \in Procs : Mode(p) = m /\
                (pc[p] = "hold" \o m \/ (m = "U" /\ pc[p] = "holdU2")
                 \/ (pc[p] = "sleep" /\ ~Queued(p) /\ Granted(p)))}

\* SYR2: exclusive excludes every other mode; one upgradable holder.
MutualExclusion == Kind = "rwlock" =>
  LET X == InMode("X") \cup {p \in Procs : pc[p] = "holdX"} IN
  /\ Cardinality(X) <= 1
  /\ X # {} => InMode("S") = {} /\ InMode("U") = {}
  /\ Cardinality(InMode("U")) <= 1

\* The word counts exactly the holders, granted waiters included.
WordMatches == Kind = "rwlock" =>
  /\ readers = Cardinality(InMode("S"))
  /\ upg <=> (InMode("U") # {})
  /\ writer <=> (\E p \in Procs : pc[p] \in {"holdX", "drain", "dsleep"}
                   \/ (Mode(p) = "X" /\ pc[p] = "sleep" /\ ~Queued(p)
                       /\ Granted(p)))

Safety == TypeOK /\ SemBalance /\ NoStrandedPermit /\ ParkedBit
          /\ MutualExclusion /\ WordMatches

\* Witness: the model admits a waiter that withdraws (oracle 10).
NoWithdrawal == ~wd

-----------------------------------------------------------------------------
(* Liveness: every waiter without a deadline acquires (SYS3, SYR7). *)

Waiting(p) == pc[p] \in {"park", "sleep", "drain", "dsleep"}
Holding(p) == pc[p] \in {"hold", "holdS", "holdU", "holdU2", "holdX"}

Acquires == \A p \in Procs \ Timed : Waiting(p) ~> Holding(p)
=============================================================================
