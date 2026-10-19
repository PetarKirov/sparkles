#!/bin/sh
# Oracle 10: run every TLC configuration of the sync protocol model.
#
# Passing configurations must finish without an error.  Witness and
# seeded-fault configurations must FAIL, with the named invariant violated
# (TLC exit 12) or with a temporal property violated (TLC exit 13).
#
# Needs `tlc` on PATH, for example:
#   nix shell nixpkgs#tlaplus18 nixpkgs#jdk21_headless -c ./check.sh
# Arguments, if any, restrict the run to configurations whose name matches
# one of them as a shell pattern (./check.sh 'mx-*').
set -eu

here=$(cd "$(dirname "$0")" && pwd)
meta=${TLA_META_DIR:-${TMPDIR:-/tmp}/sparkles-tla-meta}
workers=${TLA_WORKERS:-auto}
mkdir -p "$meta"

# name spec expectation; expectation is "pass", "inv:<Name>" or "temporal"
configs='
pl-wait              ParkingLot     pass
pl-designate         ParkingLot     pass
pl-filter            ParkingLot     pass
pl-requeue           ParkingLot     pass
pl-requeue-shared    ParkingLot     pass
pl-fork              ParkingLot     pass
pl-live-designate    ParkingLot     pass
pl-live-requeue      ParkingLot     pass
pl-witness-withdraw  ParkingLot     inv:NoWithdrawal
pl-witness-race      ParkingLot     inv:NoLostRace
pl-witness-late      ParkingLot     inv:NoLateDelivery
pl-fault-validate    ParkingLot     inv:NoLostWakeup
pl-fault-timeout     ParkingLot     inv:ReturnConsistent
pl-fault-delivery    ParkingLot     inv:QueueConsistent
pl-fault-retire      ParkingLot     inv:RegistrationsSound
pl-fault-settle      ParkingLot     inv:SettleOnlyOnCancel
pl-fault-requeue     ParkingLot     inv:ReturnConsistent
mx-deadline          LockProtocols  pass
mx-bound2            LockProtocols  pass
mx-fork              LockProtocols  pass
mx-witness-handoff   LockProtocols  inv:NoHandoff
mx-witness-withdraw  LockProtocols  inv:NoWithdrawal
mx-fault-nohandoff   LockProtocols  temporal
mx-fault-purevalidate LockProtocols temporal
mx-fault-nopasson    LockProtocols  temporal
mx-fault-twodesig    LockProtocols  inv:Designation
im-basic             LockProtocols  pass
im-fork              LockProtocols  pass
im-witness-baton     LockProtocols  inv:NoBatonPass
im-witness-withdraw  LockProtocols  inv:NoWithdrawal
im-fault-cancel      LockProtocols  inv:MutualExclusion
cv-mutex             LockProtocols  pass
cv-imutex            LockProtocols  pass
cv-mutex-live        LockProtocols  pass
cv-imutex-live       LockProtocols  pass
cv-witness-withdraw  LockProtocols  inv:NoWithdrawal
cv-fault-reacquire   LockProtocols  inv:WaitReturn
sem-basic            WaitProtocols  pass
sem-two              WaitProtocols  pass
sem-four             WaitProtocols  pass
sem-witness-withdraw WaitProtocols  inv:NoWithdrawal
sem-fault-raise      WaitProtocols  inv:NoStrandedPermit
sem-fault-drop       WaitProtocols  inv:SemBalance
rw-readers           WaitProtocols  pass
rw-upgrade           WaitProtocols  pass
rw-timed             WaitProtocols  pass
rw-upgraders         WaitProtocols  pass
rw-four              WaitProtocols  pass
rw-witness-withdraw  WaitProtocols  inv:NoWithdrawal
rw-fault-barge       WaitProtocols  temporal
rw-fault-nodrain     WaitProtocols  temporal
rw-fault-grant       WaitProtocols  inv:MutualExclusion
'

selected() {
    [ $# -le 1 ] && return 0
    n=$1
    shift
    for pat in "$@"; do
        # shellcheck disable=SC2254
        case $n in $pat) return 0 ;; esac
    done
    return 1
}

failures=0
rm -f "$meta/failures"
start_all=$(date +%s)
out=$(mktemp)
trap 'rm -f "$out"' EXIT

printf '%s\n' "$configs" | while read -r name spec expect; do
    [ -n "$name" ] || continue
    selected "$name" "$@" || continue
    start=$(date +%s)
    set +e
    (cd "$here" && tlc -workers "$workers" -metadir "$meta/$name" -cleanup \
        -noGenerateSpecTE -config "$name.cfg" "$spec.tla") \
        > "$out" 2>&1
    rc=$?
    set -e
    secs=$(($(date +%s) - start))
    states=$(sed -n 's/.* generated, \([0-9,]*\) distinct states found.*/\1/p' \
        "$out" | tail -n 1)
    case $expect in
        pass)
            if [ $rc -eq 0 ] && grep -q 'No error has been found' "$out"; then
                verdict=ok
            else
                verdict=FAILED
            fi
            ;;
        inv:*)
            inv=${expect#inv:}
            if [ $rc -eq 12 ] &&
                grep -q "Invariant $inv is violated" "$out"; then
                verdict="ok (rejected: $inv)"
            else
                verdict="FAILED (expected $inv violated)"
            fi
            ;;
        temporal)
            if [ $rc -eq 13 ] &&
                grep -q 'Temporal properties were violated' "$out"; then
                verdict="ok (rejected: liveness)"
            else
                verdict='FAILED (expected a liveness violation)'
            fi
            ;;
    esac
    printf '%-22s %-14s %10s states %5ss  %s\n' \
        "$name" "$spec" "${states:-?}" "$secs" "$verdict"
    case $verdict in
        FAILED*)
            sed -n '/^Error/,$p' "$out" | head -n 40
            echo "$name" >> "$meta/failures"
            ;;
    esac
done

if [ -s "$meta/failures" ]; then
    failures=$(wc -l < "$meta/failures")
    rm -f "$meta/failures"
fi
printf 'total %ss, %s failing configuration(s)\n' \
    "$(($(date +%s) - start_all))" "$failures"
[ "$failures" -eq 0 ]
