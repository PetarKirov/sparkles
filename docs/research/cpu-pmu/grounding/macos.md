# Grounding ledger — `macos.md`

Claim-by-claim source verification of [`docs/research/cpu-pmu/macos.md`](../macos.md).
Kernel claims are checked against the **local** pinned XNU / DTrace source drops
`$REPOS/c/xnu` (`xnu-12377.1.9`, read-only) and `$REPOS/c/apple-dtrace`
(`dtrace-413`); the Apple reverse-engineering repo is `applecpu@0e6bc3f`
(dougallj, cross-reference only). Hardware observations are read off `mac-bsn` =
Apple **M4 Max** (`Mac16,5`, SoC **T6041**, `hw.cpufamily 0x17d5b93a`), macOS
**26.3.1** (build 25D771280a), **SIP enabled**, uid 501 (non-root), Apple clang
21.0.0, `xctrace` 16.0. `$REPOS = /home/petar/code/repos`.

> Not published research. Do not link to it from the survey pages.

## Status legend

| Mark | Meaning                                                                                |
| ---- | -------------------------------------------------------------------------------------- |
| `✓`  | Verified against the cited local artifact / recorded transcript (locator recorded)     |
| `≈`  | Faithful paraphrase / inference from absence (no single line to point at)              |
| `⚠`  | Discrepancy — open contradiction or a refuted prompt hypothesis, flagged in the page   |
| `◯`  | Not locally groundable — synthesis/consequence, or surface closed (reverse-engineered) |

**Types:** `quote` (verbatim) · `src` (xnu/dtrace source-read, `[source-verified]`) ·
`hw` (`mac-bsn`, `[hw-verified: aarch64-darwin]`) · `synth` (derived consequence).

## Verification note

**Every hardware row was run unprivileged (uid 501)** — `sudo -n` needs a password
on `mac-bsn`, so nothing requiring root was attempted; the EPERM boundary is
observed from _outside_ the wall, and the privileged side (what `kpc` returns to
root) is `src` only. There is **no `[hw-verified: aarch64-darwin]` observation of
a privileged `kpc` read** anywhere in the page, by design. The closed userspace
frameworks (`kperf.framework`, `kperfdata.framework`, `CoreSymbolication`,
`xctrace` internals) are observed from the outside (`dlopen`, transcripts), never
read — those rows are `hw`/`◯`, not `src`.

## Claim ledger

| #    | Claim (short)                                                                                                                   | Type   | Source (local + locator)                                                                                                                                                                                           | Status |
| ---- | ------------------------------------------------------------------------------------------------------------------------------- | ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------ |
| C1   | Userspace counting surface = `kpc` via private `kperf.framework`, thin wrappers over `kpc.*` sysctls                            | src+hw | `kern_kpc.c:380-500` (`kpc_sysctl` dispatcher); `dlopen` of `kperf.framework/kperf` resolves `kpc_*` (Exp. a)                                                                                                      | ✓      |
| C2   | Only 3 `kpc` sysctls public (`classes`/`config_count`/`counter_count`); rest need ktrace access                                 | src    | `kern_kpc.c:398-413` (`REQ_*` break out; `default:` → `ktrace_read_check()`)                                                                                                                                       | ✓      |
| C3   | `ktrace_read_check()` = owns ktrace **or** superuser; entitlement path dev/debug-only                                           | src    | `kern_ktrace.c:288-297`, `:273-285` (`_current_task_can_own_ktrace`), `:279-282` (`#if DEVELOPMENT\|\|DEBUG`), `:73` (`com.apple.private.ktrace-allow`)                                                            | ✓      |
| Q1   | _"Require kperf access to read or write anything else. / This is either root or the blessed pid."_                              | quote  | `kern_kpc.c:405-408`                                                                                                                                                                                               | ✓      |
| C4   | Unpriv EPERM boundary matches source: enumerate ✓, every configure/read → EPERM (errno 1)                                       | hw     | Exp. a (`kpc_set_config`, `kpc_set_thread_counting`, `kpc_get_thread_counters`, `force_all_ctrs`, `kpc.counting`)                                                                                                  | ✓      |
| C5   | Fixed counters = 2 = monotonic `MT_CORE_CYCLES`/`MT_CORE_INSTRS`, read from fixed PMC0 `S3_2_C15_C0_0`                          | src    | `kern_monotonic.c:154,167,182-199`                                                                                                                                                                                 | ✓      |
| C6   | `proc_pid_rusage(RUSAGE_INFO_V4)` unpriv `ri_instructions`/`ri_cycles`; IPC 2.82 measured                                       | src+hw | `bsd/sys/resource.h:365-366` (v4 fields); Exp. b delta 300 055 815 inst / 106 386 622 cyc, IPC 2.820                                                                                                               | ✓      |
| C7   | `kpc` single-owner arbitration → `EBUSY` when CPMU claimed                                                                      | src    | `kern_kpc.c:417-419` (`cpc_hw_in_use(CPC_HW_CPMU)`) → `cpc.c:44-70` (atomic `cmpxchg NULL→owner`); handoff `kpc_common.c:167-264`                                                                                  | ✓      |
| C8   | Sampling = `kperf` timers/PMI → `kperf_sample` walks callstack; PET samples all threads on a timer                              | src    | `pet.c:30-46`; `kpc_common.c:556-579` (`kpc_sample_kperf` → `kperf_sample`)                                                                                                                                        | ✓      |
| Q4   | _"Profile Every Thread (PET) provides a profile of all threads on the system when a timer fires."_                              | quote  | `pet.c:30-31`                                                                                                                                                                                                      | ✓      |
| C9   | Hardware PC-capture on overflow (`S3_1_C15_C14_1`, `HAS_CPMU_PC_CAPTURE`, `PC_CAPTURE_PC`); else skid                           | src+hw | `osfmk/arm64/kpc.c:824-838` (`kpc_pmi_handler`); `kpc.pc_capture_supported = 1` (Exp. a)                                                                                                                           | ✓      |
| C10  | **No PEBS/SPE-style data-source/data-address sampling exposed** — PC on overflow only                                           | src≈   | absence: `bsd/kern/kern_kpc.c` + `osfmk/kern/kpc*.c` expose only counters/configs/periods/actionids; `PMTRHLD*` in HW unexposed (applecpu `PMCKext2.c`)                                                            | ✓      |
| C11  | Module map from **dyld** (`_dyld_image_count`/`_dyld_get_image_*`), not per-mmap records; 45 images                             | hw     | Exp. b (`<mach-o/dyld.h>` API; dyld open but **not cloned**)                                                                                                                                                       | ✓      |
| C12  | System dylibs share **one** `vmaddr_slide` (dyld shared cache); main exe has its own                                            | hw     | Exp. b (`libSystem`…`libc++` slide `0x1b00000`; `/private/tmp/mt_probe` slide `0x4a08000`)                                                                                                                         | ✓      |
| C13  | Symbolization = Mach-O + dSYM (DWARF) via `atos`/`symbols`; engine `CoreSymbolication` (closed)                                 | hw     | Exp. c (`atos … → square (in sym2) (sym2.c:2)`; `symbols … [Dwarf, FunctionStarts]`; `dladdr` = symbol-only)                                                                                                       | ✓      |
| C13a | One-shot `clang -g src -o bin` → **empty dSYM** (temp `.o` deleted); two-step build fixes it                                    | hw     | Exp. c (`dsymutil … no debug symbols`; retained-`.o` build yields DWARF)                                                                                                                                           | ✓      |
| C14  | macOS tracing = kdebug/ktrace + DTrace, but **no DTrace `cpc` provider**                                                        | src    | xnu `bsd/dev/dtrace/` ships fbt/sdt/systrace/profile/fasttrap/lockstat/lockprof — no `dcpc`/`cpc`; `apple-dtrace@dtrace-413` has no `*cpc*`                                                                        | ✓ ⚠    |
| C15  | DTrace unusable unprivileged under SIP (`dtrace -l` fails at init)                                                              | hw     | Exp. d ("system integrity protection is on … DTrace requires additional privileges")                                                                                                                               | ✓      |
| Q5   | _"dtrace: failed to initialize dtrace: DTrace requires additional privileges"_                                                  | quote  | Exp. d transcript                                                                                                                                                                                                  | ✓      |
| C16  | Apple Silicon is **UMA** — no NUMA nodes; only topology axis is `hw.nperflevels=2` (P/E)                                        | hw     | Exp. e (`hw.memsize` single value, no `hw.*node*`; `hw.physicalcpu=14`, page 16384, cacheline 128)                                                                                                                 | ✓      |
| C17  | Event names → PMESR via on-disk **kpep** DB plists (`/usr/share/kpep/`, world-readable, per-cpufamily)                          | hw     | Exp. e (`cpu_100000c_2_17d5b93a.plist -> as4-1.plist` symlink; consumed by closed `kperfdata.framework`)                                                                                                           | ✓      |
| C18  | Kernel `RESTRICT_TO_KNOWN` allowlist by default — **even root** can't program arbitrary selectors; 102 events T6041 vs 59 T6000 | src    | `cpc_arm64_events.c:74` (`_cpc_event_policy = CPC_EVPOL_DEFAULT`), `:92-111` (`cpc_event_allowed`), `:379-485` (T6041); `cpc_arm64.h:34-43` (`= RESTRICT_TO_KNOWN` when `!CPC_INSECURE`)                           | ✓      |
| Q3   | _"Change how event restrictions are applied."_ (event-policy setter doc)                                                        | quote  | `cpc_arm64.h:47-49`                                                                                                                                                                                                | ✓      |
| C19  | T6041 (M4) uses **PMUv3-architected** selectors for the common subset; T6000 (M1) Apple-proprietary                             | src    | `cpc_arm64_events.c:382-484` (T6041: `INST_ALL=0x0008`, `CORE_ACTIVE_CYCLE=0x0011`, `ARM_BR_MIS_PRED=0x0010`, `STALL_FE/BE=0x23/0x24`, SME block) vs `:118-177` (T6000: `INST_ALL=0x8c`, `CORE_ACTIVE_CYCLE=0x02`) | ✓      |
| A1   | xctrace `CPU Counters` template runs **unprivileged** and produces real counter data (Tier 2 broker)                            | hw     | Exp. e (`xctrace record --template 'CPU Counters' … Recording completed` exit 0, no root; export `--toc` shows metricLegend + `kernel.release.t6041`)                                                              | ✓      |
| A2   | Seven-concern map + three-tier counting framing + capability advertisement for the sparkles backend                             | synth  | derived from C1–C19                                                                                                                                                                                                | ◯      |

## Discrepancies

- **D1 (⚠ prompt hypothesis refuted).** The prompt's **DTrace `cpc` one-liner
  hypothesis (3b) is wrong for macOS** (C14). There is **no `cpc`/`dcpc`
  provider** anywhere in Apple's stack — absent from both the xnu kernel provider
  set (`bsd/dev/dtrace/`) and the `apple-dtrace@dtrace-413` userland; the Solaris
  `dcpc` provider was never ported. So even _with_ root the provider is
  unavailable. Documented in the page as a `> [!WARNING]` in the
  [event-space section](../macos.md#event-space-and-tracing--kdebug-dtrace-no-cpc-provider).
  `src`.
- **D2 (version skew, provenance note).** `mac-bsn` **runs** kernel
  **xnu-12377.91.3** (`RELEASE_ARM64_T6041`); the public open-source drop is
  **xnu-12377.1.9**. Same `12377` base for the same T6041 die, so the code read is
  representative, but every line number in the page is from `12377.1.9`. Flagged in
  the page's opening `> [!IMPORTANT]` scope box. Not a contradiction — a source
  provenance caveat. `src` vs `hw`.
- **D3 (OPEN ⚠, cross-page).** kpep reports **`fixed_counters: 3`** on _every_
  Apple generation (the ARM page's E2 kpep table), but the box's unprivileged
  `kpc_get_counter_count(FIXED)` returns **2** (Exp. a), matching the XNU
  monotonic model's two fixed PMCs (C5). The third fixed counter kpep advertises is
  unmodeled by the counting path exercised here (candidate: a fixed
  reference/uptime counter). **Flagged, not resolved.** This is the same open item
  as [`arm.md`'s D3][arm-d3], which owns the surfaced discussion in its Apple
  sidebar; `macos.md` does not re-assert it to avoid a duplicated unresolved claim.
  `hw` vs `src`. ⚠
- **D4 (versioning note, resolved).** `force_all_ctrs` is **no longer a userspace
  sysctl.** Older reverse-engineered headers expose `kpc_force_all_ctrs_set`; on
  `12377` the whole-machine arbitration moved inside the kernel (`cpc.c`
  single-owner + `kpc_common.c:167-264` power-management handoff), and the
  framework call returns `EPERM` unprivileged regardless (C4/C7). Documented in the
  page's [Tier-1 prose](../macos.md#tier-1--kpc-and-the-eperm-boundary). Not a
  contradiction — a version-drift note. `src`+`hw`.
- **D5 (surprise, resolved).** The cheap path is **richer than Linux's.**
  `proc_pid_rusage` delivers true retired-instructions and core-cycles
  unprivileged; the Linux `/proc`/tier0 equivalent gives only
  context-switch/fault-style counters, not instructions — so macOS's low-privilege
  whole-process IPC story is genuinely _better_ than Linux's (C6). Surfaced as the
  lead [Strength](../macos.md#strengths). Not a discrepancy — a documented finding.
  `hw`.

## Claims dropped / weakened

- **Q2 (RAWPMU fence quote) not used verbatim.** The sub-report offered
  `kern_kpc.c:471-473` (_"Client shouldn't ask for config words that aren't
  available…"_) as a candidate; the page states the RAWPMU/`POWER` fence in prose
  (`classes=11`, `POWER(4)` absent to userspace) rather than quoting it, to keep to
  one quote per section. The fact is source-grounded; only the verbatim quote is
  omitted. `src`.
- **D3 (fixed-counter 3-vs-2) carried, not surfaced in-page.** Left as an OPEN
  ledger item cross-referenced to `arm.md`'s D3 (which owns it) rather than
  re-asserted in `macos.md`. Nothing else dropped: the page carries all 19
  sub-report claims (C1–C19), the four used quote candidates (Q1, Q3, Q4, Q5), the
  empty-dSYM gotcha (C13a), and the `xctrace` Tier-2 evidence (A1).

**Net:** 0 fabrications. Every kernel mechanism is `[source-verified]` against
`xnu-12377.1.9` / `dtrace-413`; every measurement is `[hw-verified: aarch64-darwin]`
off `mac-bsn` (unprivileged). **One refuted prompt hypothesis** (D1, no DTrace
`cpc` provider — recorded as a page WARNING), **one open discrepancy** (D3, kpep
`fixed_counters` 3 vs `kpc` FIXED 2, ⚠ flagged not resolved, owned by `arm.md`),
one source-version skew (D2, running `12377.91.3` vs drop `12377.1.9`, noted), and
two documented findings (D4 `force_all_ctrs` internalized, D5 `rusage` richer than
Linux). No privileged `kpc` read was hardware-observed — the EPERM wall is verified
from outside and the privileged side is source-read only.

<!-- References -->

[arm-d3]: ./arm.md#discrepancies
