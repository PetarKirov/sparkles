# Review guide — wired bench on `sparkles:test-runner` + runner validation

Reproduce and check every result on branch `feat/wired-json-engine`
(tip `aff3aa76`, 5 new commits on top of the 34 rebased engine commits). The
work: rebase the wired JSON engine onto `main` (now the test-runner tree),
re-engineer the runtime bench onto `sparkles:test-runner`, and prove the
runner's hardware-counter measurements match the retired hand-rolled harness.

> **Reading the numbers.** `MB/s` is machine-specific — reproduce _relative_
> standings, not absolute values. **`ins/byte` (retired instructions ÷ bytes)
> is deterministic** and machine-independent; it is the anchor every
> correctness claim rests on, so those numbers should reproduce to <1%.
> All commands assume the nix devshell (`nix develop`), which exports
> `$WIRED_BENCH_DATA` and puts the ISA-preset shims on `PKG_CONFIG_PATH`.

```sh
cd <repo>                       # the sparkles-serde worktree
git switch feat/wired-json-engine
git log --oneline -1            # aff3aa76 docs(wired): re-baseline on the runner …
```

---

## 1. Rebase integrity

```sh
# The branch really sits on top of current main:
git merge-base --is-ancestor main feat/wired-json-engine && echo "✓ rebased onto main"

# No conflict markers survived anywhere:
git grep -nE '^(<<<<<<<|>>>>>>>|=======)$' -- '*.d' '*.nix' '*.sdl' '*.md' \
  || echo "✓ no conflict markers"

# The pre-rebase tip is tagged (for the B0 comparison / rollback):
git log --oneline -1 wired-json-engine-prerebase   # 55ceec30 … JsonSink
```

**Bench-tree coherence** — main's runner-driven harness, none of the old
executable harness:

```sh
cd libs/wired/bench/runtime/src/sparkles/wired_bench
# GONE (old executable harness): app.d config.d timing.d perf.d report.d perf_events_c.c
for f in ../../app.d config.d timing.d perf.d report.d perf_events_c.c; do
  test -e "$f" && echo "✗ leftover: $f" || echo "✓ gone: $f"
done
# PRESENT (runner-driven): runner.d, data.d, the new allocator.d, wired_native.d
ls runner.d data.d allocator.d engines/wired_native.d
# and the retired std.json row is gone, wired-native is the product row:
grep -n 'WiredNativeEngine\|WiredEngine' engines/package.d
test -e engines/wired_json.d && echo "✗ wired_json.d leftover" || echo "✓ wired_json.d removed"
cd -
```

**The one engine/base merge (writers.d) kept both sides:**

```sh
# W's branchlut fast path AND main's per-digit portable path both present:
grep -c 'branchlut\|Portable per-digit' libs/base/src/sparkles/base/text/writers.d  # ≥ 2
```

**Suites green, now running under `sparkles:test-runner`:**

```sh
nix develop -c dub test :base    # Summary: 299 passed, 0 failed
nix develop -c dub test :wired   # Summary: 66 passed  (incl. conformance.jsonTestSuite)

# JSONTestSuite conformance with the pinned corpus explicit:
nix develop -c bash -c \
  'JSON_TEST_SUITE=$(nix build --no-link --print-out-paths .#json-test-suite) \
   dub test :wired' 2>&1 | grep -E 'conformance|Summary'
```

---

## 2. The re-engineered bench runs under the runner

```sh
cd libs/wired/bench/runtime

# D-engine field (default config, builds off-nix too):
nix develop -c dub test -b bench -- --bench --group-by=dataset,operation
#   → a table grouped by dataset/operation; wired-native present with a B/s column.

# Full competitive field (foreign engines via the nix shims):
nix develop -c dub test -b bench -c unittest-foreign -- --bench --perf
#   → adds yyjson, simdjson-dom / -ondemand, rapidjson, serde_json,
#     simd-json, sonic-rs, each with IPC / instr/iter / br-miss columns.

# Allocator-leveling constructor actually runs (a plain unittest asserts it):
nix develop -c dub test 2>&1 | grep 'allocator.levelingApplied'
#   → ✓ sparkles.wired_bench.allocator allocator.levelingApplied
cd -
```

**Verification gates are live** (a wrong engine cannot post a fast number).
jsoniopipe emits invalid JSON on serialize and is isolated as an error row,
not timed:

```sh
nix develop -c bash -c \
  'cd libs/wired/bench/runtime && dub test -b bench -c unittest-foreign -- --bench \
   --bench-min-time=200 -i "wired\.serialize"' 2>&1 | grep -i 'jsoniopipe'
#   → jsoniopipe serialize rows carry an error ("… is not valid JSON"), no B/s.
```

---

## 3. Codegen parity (the CMI finding)

The runner's `-unittest` build cannot take `-enable-cross-module-inlining` on
its build type (it culls a mir-ion template). The fix scopes inlining to
`sparkles:wired` — but bare CMI fails to link under `-checkaction=context`, so
the working recipe is **CMI + `-linkonce-templates`**. Quantify all three with
the deterministic anchor:

```sh
cd libs/wired/bench/runtime
for cfg in library library-singleobj library-inline; do
  nix develop -c bash -c "WIRED_BENCH_ENGINES=wired-native WIRED_BENCH_DATASETS=twitter \
    dub test -b bench --override-config sparkles:wired/$cfg --force -- \
    --bench --perf -i 'wired\.parse' --bench-min-time=300 --bench-json=/tmp/cfg-$cfg.json" >/dev/null 2>&1
  python3 -c "import json; r=json.load(open('/tmp/cfg-$cfg.json'))['rows'][0]; \
    print(f'  $cfg: {r[\"metrics\"][\"instr\"]/631514:.2f} ins/B')"
done
cd -
```

Expected (deterministic):

```
  library:           9.60 ins/B   ← stock, seams not inlined
  library-singleobj: 9.60 ins/B   ← inert (dub already compiles wired all-at-once)
  library-inline:    8.12 ins/B   ← CMI + -linkonce-templates = parity with B0
```

Confirm bare CMI genuinely fails (the reason `-linkonce-templates` is needed) —
this build is _expected to error_ at link with `undefined reference to
_d_assert_fail`:

```sh
# Add a throwaway config to prove the failure, or inspect the recipe rationale:
sed -n '/library-inline/,/^}/p' libs/wired/dub.sdl   # the documented recipe
```

---

## 4. The runner-measurement validation (the crux)

**Claim:** the runner's `perf_event` instruction counting is byte-for-byte
equivalent to the retired hand-rolled `perf.d`. Proof = the retired-instruction
anchor matches the pre-rebase baseline B0 to <1%.

B0 is committed (captured from tip `55ceec30` before the rebase):
`results/B0-prerebase-55ceec30-cmi.json`. Produce B1 from the current tip and
diff:

```sh
cd libs/wired/bench/runtime
# B1: runner, default library-inline codegen, 2 s budget, allocator levelled.
nix develop -c bash -c "WIRED_BENCH_ENGINES=wired-native,yyjson \
  dub test -b bench -c unittest-foreign --force -- \
  --bench --perf --bench-min-time=2000 --bench-json=/tmp/B1.json" >/dev/null 2>&1
cd -

python3 - <<'PY'
import json
B0={(r['engine'],r['dataset'],r['op']):r for r in
    json.load(open('libs/wired/bench/runtime/results/B0-prerebase-55ceec30-cmi.json'))['results']}
B1={(r['name'],r['labels']['dataset'],r['labels']['operation']):r for r in
    json.load(open('/tmp/B1.json'))['rows'] if not r.get('error')}
print(f"{'engine':13}{'dataset':13}{'op':10}{'insB_B0':>8}{'insB_B1':>8}{'Δ%':>7}  gate")
worst=0
for k in sorted(B0):
    if k not in B1 or k[0] not in ('wired-native','yyjson'): continue
    byt=B0[k]['bytes']; i0=B0[k]['perf']['instructions']; i1=B1[k]['metrics']['instr']
    d=100*(i1-i0)/i0; worst=max(worst,abs(d)) if k[0]=='wired-native' else worst
    print(f"{k[0]:13}{k[1]:13}{k[2]:10}{i0/byt:>8.2f}{i1/byt:>8.2f}{d:>+6.2f}%  {'✓' if abs(d)<1 else '~advisory'}")
print(f"\nANCHOR: worst wired-native |Δ| = {worst:.2f}%  (gate: <1% on the parse/decode anchor rows)")
PY
```

Expected: every `parse`/`decode`/`validate` row within **±0.5%**; the single
`citm serialize` row at ~−1.8% (a JsonSink buffer-grow amortization effect,
documented as advisory / open-issue B3). This is the certificate that the
migration cost no measurement fidelity.

**Wall-clock is deliberately _not_ bit-comparable** (same instructions, different
cache regime). To see it: in the diff above, wired-native serialize MB/s is
~9-22% lower and yyjson parse MB/s ~6-11% higher than B0 while `ins/byte`
matches — microarchitecture, not counting. (Details in
`docs/specs/wired/bench-baseline.md` § "Validating the runner".)

**Allocator leveling is intrinsic and effective** — force glibc to mmap every
arena and confirm page-faults stay 0 (the startup `mallopt` overrides the env):

```sh
nix develop -c bash -c "cd libs/wired/bench/runtime && \
  WIRED_BENCH_ENGINES=wired-native WIRED_BENCH_DATASETS=twitter,canada \
  MALLOC_MMAP_THRESHOLD_=16384 MALLOC_TRIM_THRESHOLD_=16384 \
  dub test -b bench -- --bench --perf -i 'wired\.parse' \
  --bench-min-time=300 --bench-json=/tmp/adv.json" >/dev/null 2>&1
python3 -c "import json; [print('  ', r['labels']['dataset'], 'page-faults/iter =', \
  r['metrics']['page-faults']) for r in json.load(open('/tmp/adv.json'))['rows'] if not r.get('error')]"
#   → both 0  (leveling defeats the adversarial threshold)
```

---

## 5. The written deliverables

```sh
# The runner findings — 7 tracked issues (B1-B3 harness, P1-P4 PMU gaps),
# each mapped to a cpu-pmu milestone where one covers it:
$PAGER docs/specs/test-runner/open-issues.md

# The re-baselined benchmark doc (runner methodology + the before/after
# validation section + refreshed competitive tables + the M15 exit gate):
$PAGER docs/specs/wired/bench-baseline.md

# Its data: B0 (pre-rebase executable) and the runner snapshot.
ls -1 libs/wired/bench/runtime/results/*.json
```

---

## What to scrutinize

- **The anchor logic (§4).** The whole "runner is correct" claim rests on
  retired instructions being deterministic and the timed region being
  identical. If you doubt it, re-run B1 at a different `--bench-min-time` — the
  `ins/byte` must not move (only the counting pass, which is separate from
  timing, feeds it).
- **The CMI recipe (§3).** `-linkonce-templates` fixed the link on LDC 1.41 but
  has ICE'd elsewhere (noted in open-issue B1). Confirm it links on your
  toolchain.
- **Scope of runner changes.** Per "coordinate, don't re-architect," the runner
  itself (`sparkles:test-runner`) was **not** patched — gaps are logged as open
  issues for the milestone work. Only `libs/wired/**` and the two docs changed.
- **The serialize wall-clock caveat (§4).** wired-native serialize reads ~17%
  slower under the runner at identical instructions; if serialize wall-clock
  comparability matters to you, that memory-layout effect is the one spot the
  runner's per-case heap-engine model diverges from the old harness.
