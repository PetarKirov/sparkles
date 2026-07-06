#!/usr/bin/env bash
# walk-bench.sh — multi-axis walk benchmark for sparkles:event-horizon.
#
# Three axes, the "why" beside the "how fast":
#   1. TREE SHAPE   — breadth × depth × files-per-dir (gen-tree.d), so the
#                     comparison isolates geometry: wide/shallow vs narrow/deep
#                     vs balanced vs dense-flat.
#   2. PAGE CACHE   — hot (warmed) vs cold (dropped). Cold is where a proactor
#                     could hide real I/O latency; it needs to evict the
#                     dentry/inode cache, which requires root (drop_caches).
#                     Configure the drop command via $EH_BENCH_DROP; the harness
#                     runs hot-only with a clear note when it is unavailable.
#   3. SYSCALLS     — strace -f -c counts per walker (a separate pass — ptrace
#                     perturbs timing but not counts), reported next to the
#                     wall-clock so a win/loss is explained, not just stated.
#
# Competitors: rust-rayon (incumbent), the D std.parallelism.taskPool walker,
# and event-horizon (cpuBound pool) at its 16-worker optimum + all-cores default.
#
# Usage:
#   walk-bench.sh [--quick] [--shapes "name b d f;..."] [--reps N]
# Env:
#   EH_BENCH_WORK   fixture root (default: a fresh mktemp dir, removed on exit)
#   EH_BENCH_DROP   cold-cache eviction command (default: sudo -n drop_caches)
#   EH_RAYON        path to walk-rust-rayon   (default: search polyglot-walks)
#   EH_TASKPOOL     path to the D taskPool walker
set -uo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPS=20
QUICK=0
SHAPES_SPEC=""
while [ $# -gt 0 ]; do
  case "$1" in
    --quick) QUICK=1; REPS=8; shift ;;
    --reps) REPS="$2"; shift 2 ;;
    --shapes) SHAPES_SPEC="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# name breadth depth files  (each ~90-220k files, deliberately different shapes)
default_shapes=(
  "wide     100 2 10"    # shallow, huge fan-out (10101 dirs)
  "deep     3   9 3"     # deep nesting, small fan-out (29524 dirs)
  "balanced 6   5 10"    # middle (9331 dirs)
  "dense    10  3 200"   # few dirs, many files each (1111 dirs, 222k files)
)
if [ $QUICK -eq 1 ]; then
  default_shapes=("balanced 6 4 10" "dense 8 3 150")
fi
if [ -n "$SHAPES_SPEC" ]; then
  IFS=';' read -ra default_shapes <<< "$SHAPES_SPEC"
fi

# Cold cache needs to evict the dentry/inode cache — root-only (drop_caches).
# As root, write it directly; otherwise try passwordless sudo. Override with
# $EH_BENCH_DROP (e.g. run `sudo -v` first, then EH_BENCH_DROP='sudo sh -c ...').
if [ -n "${EH_BENCH_DROP:-}" ]; then DROP="$EH_BENCH_DROP"
elif [ "$(id -u)" = "0" ]; then DROP="sh -c 'echo 3 > /proc/sys/vm/drop_caches'"
else DROP="sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches'"; fi
WORK="${EH_BENCH_WORK:-$(mktemp -d)}"
OWNED_WORK=0; [ -z "${EH_BENCH_WORK:-}" ] && OWNED_WORK=1
mkdir -p "$WORK"
cleanup() { [ $OWNED_WORK -eq 1 ] && rm -rf "$WORK"; }
trap cleanup EXIT

echo "== walk-bench =="
echo "work dir: $WORK"

# ── locate / build the walkers ──────────────────────────────────────────────
GEN="$BENCH_DIR/build/gen_tree"
EH="$BENCH_DIR/build/walk_event_horizon"
[ -x "$GEN" ] || { echo "building gen-tree..."; ( cd "$BENCH_DIR" && dub build --single gen-tree.d >/dev/null 2>&1 ); }
[ -x "$EH" ]  || { echo "building walker...";   ( cd "$BENCH_DIR" && dub build --single walk-event-horizon.d >/dev/null 2>&1 ); }

RAYON="${EH_RAYON:-$HOME/code/repos/polyglot-walks/lang/rust/target/release/walk-rust-rayon}"
TASKPOOL="${EH_TASKPOOL:-/tmp/claude-1002/walk-d-taskpool}"

declare -A WALKERS
WALKERS["rust-rayon"]="$RAYON"
[ -x "$TASKPOOL" ] && WALKERS["d-taskpool"]="$TASKPOOL"
WALKERS["event-horizon-16w"]="$EH __ARG__ --workers=16"
WALKERS["event-horizon-32w"]="$EH __ARG__"
ORDER=("rust-rayon" "d-taskpool" "event-horizon-16w" "event-horizon-32w")

# ── cold-cache availability + validity probe ─────────────────────────────────
# Two traps `drop_caches` walks into, both detected from the fixture's fs:
#   tmpfs — RAM-backed, drop_caches is a no-op → no cold is possible.
#   zfs   — metadata lives in the ARC, which drop_caches does NOT evict; the
#           column then reflects cold-START (drop_caches also repages the
#           executables, penalizing the larger dynamically-linked binary), not
#           a cold-from-disk directory walk. Honest label > misleading number.
FSTYPE="$(findmnt -no FSTYPE --target "$WORK" 2>/dev/null || echo unknown)"
COLD_OK=0; COLD_KIND="valid"
case "$FSTYPE" in
  tmpfs) COLD_KIND="tmpfs-noop" ;;
  zfs)   COLD_KIND="zfs-arc" ;;
esac
if [ "$COLD_KIND" != "tmpfs-noop" ] && eval "$DROP" >/dev/null 2>&1; then COLD_OK=1; fi

if [ "$COLD_KIND" = "tmpfs-noop" ]; then
  echo "cold cache: N/A — fixture is on tmpfs ($WORK); drop_caches cannot evict RAM. Set \$EH_BENCH_WORK to a disk-backed path."
elif [ $COLD_OK -eq 0 ]; then
  echo "cold cache: UNAVAILABLE (drop failed — needs root; set \$EH_BENCH_DROP). Running hot only."
elif [ "$COLD_KIND" = "zfs-arc" ]; then
  echo "cold cache: PARTIAL — fixture fs is ZFS. drop_caches flushes the VFS cache but NOT the ZFS ARC (metadata stays warm) and repages the binaries, so 'cold' here means cold-START, not cold-disk. Interpret accordingly."
else
  echo "cold cache: available on $FSTYPE (drop = $DROP)"
fi

cmd_for() { # walker-name, root  -> full command line
  local tmpl="${WALKERS[$1]}"
  case "$tmpl" in
    *__ARG__*) echo "${tmpl/__ARG__/$2}" ;;
    *) echo "$tmpl $2" ;;
  esac
}

# ── the matrix ───────────────────────────────────────────────────────────────
run_shape() {
  local name="$1" breadth="$2" depth="$3" files="$4"
  local root="$WORK/$name"
  echo
  echo "### shape: $name (breadth=$breadth depth=$depth files/dir=$files)"
  [ -d "$root" ] || "$GEN" "$root" "$breadth" "$depth" "$files" >/dev/null
  local nd nf
  nd=$(find "$root" -type d | wc -l); nf=$(find "$root" -type f | wc -l)
  echo "tree: $nd dirs, $nf files"

  # --- wall-clock: hot (and cold if available) ---
  local jhot="$WORK/$name.hot.json" jcold="$WORK/$name.cold.json"
  local hargs=(); for w in "${ORDER[@]}"; do [ -n "${WALKERS[$w]:-}" ] && hargs+=(-n "$w" "$(cmd_for "$w" "$root")"); done
  hyperfine -N --warmup 5 -r "$REPS" --export-json "$jhot" "${hargs[@]}" >/dev/null 2>&1
  if [ $COLD_OK -eq 1 ]; then
    hyperfine -N --prepare "$DROP" -r "$((REPS<10?REPS:10))" --export-json "$jcold" "${hargs[@]}" >/dev/null 2>&1
  fi

  # --- syscalls: strace -c per walker (separate pass) ---
  declare -A SC
  for w in "${ORDER[@]}"; do
    [ -n "${WALKERS[$w]:-}" ] || continue
    local out="$WORK/$name.$w.strace"
    strace -f -c -o "$out" $(cmd_for "$w" "$root") >/dev/null 2>&1 || true
    SC[$w]=$(sc_pick "$out")
  done

  # --- report table ---
  printf "\n%-20s %10s %10s %9s | %9s %8s %7s %6s %7s\n" \
    "walker" "hot(ms)" "cold(ms)" "vs rayon" "getdents" "openat" "futex" "yield" "clone3"
  local rayon_hot; rayon_hot=$(mean_ms "$jhot" "rust-rayon")
  for w in "${ORDER[@]}"; do
    [ -n "${WALKERS[$w]:-}" ] || continue
    local hm cm ratio; hm=$(mean_ms "$jhot" "$w")
    cm="-"; [ $COLD_OK -eq 1 ] && cm=$(mean_ms "$jcold" "$w")
    ratio=$(awk -v a="$rayon_hot" -v b="$hm" 'BEGIN{ if(b>0) printf "%.2fx", a/b; else print "-" }')
    printf "%-20s %10s %10s %9s | %s\n" "$w" "$hm" "$cm" "$ratio" "${SC[$w]}"
  done
}

mean_ms() { # json, name -> mean in ms (2dp)
  # hyperfine records the command string, not our label; match by index order.
  jq -r --argjson i "$(idx_of "$2")" \
    '.results[$i].mean * 1000 | (.*100|round)/100' "$1" 2>/dev/null || echo "-"
}
idx_of() { local i=0; for w in "${ORDER[@]}"; do [ -n "${WALKERS[$w]:-}" ] || continue; [ "$w" = "$1" ] && { echo "$i"; return; }; i=$((i+1)); done; echo 0; }

sc_pick() { # strace -c file -> "getdents openat futex yield clone3" aligned counts
  local f="$1"
  awk '
    function g(n){ return (n in c)? c[n] : 0 }
    /^[ ]*[0-9]/ { c[$NF]=$4 }
    END{ printf "%9s %8s %7s %6s %7s",
        g("getdents64"), g("openat"), g("futex"), g("sched_yield"), g("clone3") }
  ' "$f" 2>/dev/null || printf "%9s %8s %7s %6s %7s" - - - - -
}

for s in "${default_shapes[@]}"; do
  # shellcheck disable=SC2086
  set -- $s
  run_shape "$1" "$2" "$3" "$4"
done

echo
echo "note: syscall counts are from a strace -f -c pass (counts are timing-independent);"
echo "      wall-clock is hyperfine -N ($REPS reps). event-horizon uses the cpuBound pool."
if [ "$COLD_KIND" = "zfs-arc" ] && [ $COLD_OK -eq 1 ]; then
  echo "      cold column = cold-START on ZFS (ARC keeps metadata warm; drop_caches"
  echo "      also repages binaries — the larger dynamically-linked D binary pays more)."
fi
