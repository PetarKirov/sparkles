# `sparkles:fuzzy` specification and delivery-plan review

This review consolidates the two independent adversarial reviews of:

- **Document A:** `docs/specs/fuzzy/SPEC.md`
- **Document B:** `docs/specs/fuzzy/PLAN.md`
- **Document C:** `docs/specs/hue/picker.md`, only as the source of the `PKQ`,
  `PKR`, and `PKM` requirements A and B claim to satisfy

Findings are ordered approximately by severity. Each finding retains the
concrete failure scenarios needed to reproduce or reason about the defect.

## Findings

1. **A backwalk from the unconstrained Smith-Waterman maximum cannot preserve
   the prefilter's existential typo oracle.** **Document/section:** A
   sections 4.1, 4.2, and 4.4. **Scenario:** for needle `ab`, haystack `a`
   followed by twenty `x` bytes and `/b`, and `maxTypos = 0`, the LCS oracle
   passes because `ab` is a subsequence; the unconstrained final-row maximum
   can instead match the prefix `a` for 24 points and delete `b` for a
   six-point gap, scoring 18, while the valid zero-typo path across the long
   haystack gap scores less. A single traceback then rejects a candidate the
   normative oracle accepts. Finding the best valid alignment requires
   typo-constrained DP state or exploration of alternative paths. **Severity:**
   `breaks-correctness`.

2. **`Query.refines` is unsound because extending a query can increase the
   derived typo budget and grow the match set.** **Document/section:** A
   sections 4.1 and 8. **Scenario:** `abcdefghijk` has length 11 and budget 2;
   candidate `abcdefghl` has LCS 8 and is rejected. Appending `l` produces
   `abcdefghijkl`, length 12 and budget 3; the same candidate now has LCS 9
   and passes. Every fuzzy part was extended, constraints stayed equal, and
   there was no trailing negation. **Severity:** `breaks-correctness`.

3. **Rescoring only previous survivors loses matches whenever refinement
   occurs before the previous generation is exhausted.** **Document/section:**
   A section 8. **Scenario:** query `a` has scanned candidates 0 through 99
   when the user types `ab`; rescoring those survivors alone permanently omits
   an `ab` candidate at index 500. The protocol needs an exhausted precondition
   or a defined survivor-plus-unscanned-tail merge. **Severity:**
   `breaks-correctness`.

4. **The never-re-zeroed matrix argument is invalid for windows beginning
   after column zero because the recurrence has an uninitialized left halo.**
   **Document/section:** A section 4.3. **Scenario:** after one candidate writes
   a high value at row `r`, column 49, a candidate whose window begins at
   column 50 reads that stale value horizontally and later diagonally; a
   log-shift vector beginning mid-register can import all stale lanes preceding
   the window. Every window must be rebased to logical column 1 or have its
   scalar and vector halo explicitly cleared and masked. **Severity:**
   `breaks-correctness`.

5. **Borrowed query and candidate spans are unsafe across asynchronous
   generation changes without an explicit immutable-snapshot lifetime rule.**
   **Document/section:** A sections 1, 3.2, and 8; C `PIK6`-`PIK7`.
   **Scenario:** a worker for generation A retains spans into the editable line
   buffer; the GUI mutates that buffer and reparses generation B before A next
   probes cancellation, so A reads B's bytes. Arena growth can likewise
   relocate candidate paths still borrowed by workers. Cancellation does not
   extend either buffer's lifetime. **Severity:** `breaks-correctness`.

6. **The one-boundary top-K algorithm cannot return a page correctly when
   `offset > 0`.** **Document/section:** A section 5. **Scenario:** for
   `offset = 10` and `limit = 10`, selecting only the top-20 boundary leaves
   those values unordered; sorting positions 10 through 19 returns an arbitrary
   ten of the top 20 and can repeat ranks 1-10 while omitting ranks 11-20. A
   second selection boundary or sorting the whole top-20 prefix is required.
   **Severity:** `breaks-correctness`.

7. **The prefilter window is not conservative when an allowed typo deletes
   the first or last needle byte.** **Document/section:** A section 4.1.
   **Scenario:** needle `ab`, haystack `ba`, and budget 1 satisfy the LCS oracle,
   but the stated start is byte 1 and end is byte 0, producing a reversed
   window; `abc` against `bc` has no first-needle-byte occurrence from which to
   derive the required start. **Severity:** `breaks-correctness`.

8. **OR-combining all extension constraints makes negated extensions
   ineffective.** **Document/section:** A section 3.1. **Scenario:**
   `!*.rs !*.md foo` accepts `main.rs` because `not .md` is true and accepts
   `README.md` because `not .rs` is true. Positive extension alternatives must
   form an OR bucket while negated extensions are ANDed as exclusions.
   **Severity:** `breaks-correctness`.

9. **The default typo formula makes every two-byte query pass the prefilter,
   including candidates sharing no byte with it.** **Document/section:** A
   sections 3.1, 4.1, and 4.3. **Scenario:** `ab` remains an effective part but
   receives budget 2, so `LCS("ab", "zz") + 2 = 2`; the DP can return
   `matched` with score zero. With `comboOpenCount = 3`, that zero-score result
   receives 300 points and can outrank a genuine cold match scoring 100. This
   contradicts both ordinary match semantics and the claim that zero never
   silently represents degradation. **Severity:** `breaks-correctness`.

10. **The stated approximately 3,639-byte needle cap does not prevent default
    `ushort` score overflow, and runtime scoring makes a fixed default-derived
    cap invalid.** **Document/section:** A sections 4.2-4.3. **Scenario:** an
    exact 3,276-byte alternating string `aAaA...` enables smart case; lowercase
    matches earn 16, uppercase-after-lower matches 24, plus prefix and exact
    bonuses, totaling 65,540. Separately, `matchScore` and `prefixBonus` can
    each be 65,535 and overflow a one-byte match unless configuration validation
    and wider intermediates are specified. **Severity:** `breaks-correctness`.

11. **Composite ranking has unchecked integer-overflow paths, inconsistent
    percentage ordering, and positive scores for `base = 0`.**
    **Document/section:** A sections 5 and 6.3. **Scenario:**
    `65_535 * frecencyScore` overflows `int` for sufficiently large public
    inputs, and `comboOpenCount * comboMultiplier` is independently unbounded;
    `base / 5 * 2` yields zero for `base = 4` although truncating 40 percent
    after multiplication yields one; and combo points can promote a zero-score
    candidate. **Severity:** `breaks-correctness`.

12. **The long-candidate fallback cannot satisfy the declared result,
    positions, and ranking APIs.** **Document/section:** A sections 4.3-5.
    **Scenario:** a 100 KiB candidate matched at byte 70,000 cannot represent
    its end in `ushort endCol`, so filename ranking wraps or truncates it. No
    full matrix exists for the positions-tier traceback, and the fallback's
    substitution score, typo verification, tie-breaking, position
    reconstruction, and the `quality` used by filename scaling are undefined.
    **Severity:** `breaks-correctness`.

13. **A 1,024-column stride with structural column zero cannot hold a
    1,024-byte candidate as written.** **Document/section:** A section 4.3.
    **Scenario:** data columns 1 through 1,024 are required in addition to
    structural column 0, yet only candidates longer than 1,024 use the
    fallback. A candidate of exactly 1,024 bytes therefore needs 1,025 scalar
    columns or otherwise indexes the next row or out of bounds. **Severity:**
    `breaks-correctness`.

14. **The approximate `matchStart` can underflow and award a filename bonus to
    a match that crosses a path separator.** **Document/section:** A section 5.
    **Scenario:** query `abc` aligned to `a/xxbc` begins in the directory at
    byte 0 and ends at byte 5, but `5 - 3 + 1 = 3` lies inside the filename
    beginning at byte 2. If local alignment drops enough leading needle bytes
    that `endCol + 1 < needleLen`, unsigned subtraction wraps. **Severity:**
    `breaks-correctness`.

15. **Byte-wise UTF-8 matching can match and report a byte inside an unrelated
    code point.** **Document/section:** A sections 4.1 and 4.4. **Scenario:**
    UTF-8 `é` is `C3 A9` and `Ω` is `CE A9`; with budget 1 the LCS predicate can
    pass on their shared continuation byte and return byte offset 1 inside
    `Ω`. Segmenting after the fact cannot turn that into a character-level
    match, and one `(orig, flipped)` pair per byte cannot express general
    Unicode case mappings. **Severity:** `breaks-correctness`.

16. **The backslash bypass contradicts the plan's claim that it implements
    escaping.** **Document/section:** A section 3.1; B M1. **Scenario:** `\*`
    bypasses constraint dispatch but retains the backslash, so it searches for
    backslash-plus-asterisk rather than a literal asterisk; B nevertheless
    names this a `\*` escape test. **Severity:** `breaks-correctness`.

17. **The batch cursor is not tied to a query generation, candidate snapshot,
    or sink epoch.** **Document/section:** A section 8; C `PIK7`. **Scenario:**
    generation A returns `nextOffset = 100`; generation B refines A to a
    12-element survivor list, so reusing 100 misses all survivors while
    resetting to zero duplicates retained results. Inserting a candidate before
    an offset between calls also duplicates an old item and skips the new one;
    resetting a shared abort boolean lets an A worker observe false and resume
    stale appends. `SearchStatus` exposes no generation, cancellation reason,
    range identity, or sink epoch with which the host can reject these results.
    **Severity:** `breaks-correctness`.

18. **The long-lived frecency and combo tables have no safe key representation
    under the rule that the library owns no string.** **Document/section:** A
    sections 1 and 6. **Scenario:** borrowing `(project, query)` makes a combo
    key change or dangle when the prompt is edited; borrowed file paths fail
    when the candidate arena is rebuilt. Stable caller IDs, collision-safe
    hashes, or stable caller arenas could solve this, but none is part of the
    contract. **Severity:** `breaks-correctness`.

19. **`searchPage` cannot satisfy the picker frame-budget contract because it
    limits emitted matches rather than elapsed time or candidates examined.**
    **Document/section:** A section 8; C `PIK5`. **Scenario:** with
    `pageLimit = 20` and one million nonmatches, one call scans all one million
    before the host can check its clock; one arbitrarily long fallback candidate
    can likewise monopolize the call before the next abort probe. **Severity:**
    `breaks-contract`.

20. **The host integration plan has no compatible bridge to the specified
    work-stealing pool.** **Document/section:** context fact 6; A sections 1 and
    8; B M7; C interactivity rationale and `PIK6`. **Scenario:** each keystroke
    must submit work capturing a query, generation, range, and sink, but
    `WorkStealingPool.submit` uses a GC-allocated delegate while the pool keeps
    the GC disabled. This violates the no-allocation query path and can
    accumulate uncollectable submissions; the synchronous fallback covers pool
    startup failure, not this normal incompatibility. **Severity:**
    `breaks-contract`.

21. **`PKQ2` is not satisfied because the grammar produces no file-path-suffix
    constraint and cannot represent `git:ignored`.** **Document/section:** A
    sections 3.1-3.2; C `PKQ2`. **Scenario:** `ConstraintKind.filePath` is
    unreachable from the dispatch table and `GitStatusFilter` contains `clean`
    instead of `ignored`, so `src/app.d git:ignored` remains fuzzy text or
    errors. **Severity:** `breaks-contract`.

22. **The specification never defines how multiple fuzzy parts combine into
    matching, scoring, typo budgets, or positions.** **Document/section:** A
    sections 3.1-4. **Scenario:** `user controller` could mean two independent
    ANDed needles, one concatenated needle, or an ordered two-part match; each
    produces different candidates, budgets, scores, `endCol`, and highlights.
    Consequently `effectiveQuery.length` is undefined. **Severity:**
    `breaks-contract`.

23. **Section 10 is a symbol inventory rather than an implementable public
    API, and constraint evaluation has no candidate or metadata seam.**
    **Document/section:** A sections 3.1, 8, and 10; B M1 and M7. **Scenario:**
    `searchPage` has no signature for `Query`, candidate representation,
    filename offset, git-status resolver, rank context, output item, or sink
    failure, so a parsed `git:staged` constraint cannot be evaluated.
    `MatchConfig` is undefined, `Matcher.score` is omitted while
    `Matcher.positions` is listed, and most functions lack parameter, return,
    ownership, error, complexity, and hard-budget contracts. No milestone owns
    the missing evaluator. **Severity:** `breaks-contract`.

24. **Live downstream contracts are incompatible with the normative
    `nothrow` guarantee, and public mutable structs make failures externally
    reachable.** **Document/section:** context facts 1 and 5; A sections 3.2
    and 10. **Scenario:** callers can directly construct or mutate a `Query`
    containing a one-byte part, invalid enum, or inconsistent constraint;
    callers can likewise supply an invalid scoring configuration or out-of-range
    cursor. Checked-build `in` contracts then raise `AssertError`, an escaping
    `Throwable` under the supplied definition. `parseQuery` therefore is not
    the only boundary capable of producing invalid public values. **Severity:**
    `breaks-contract`.

25. **Attribute inference for caller-provided ranges, sinks, and resolvers
    cannot guarantee the universal public attribute policy.**
    **Document/section:** A sections 8 and 10. **Scenario:** a sink whose `put`
    allocates or throws, or a resolver that reads mutable global state, makes an
    instantiation of `positions`, `selectTopK`, or `searchPage` lose `@nogc`,
    `nothrow`, or `pure`, or fail to instantiate. Thus the abort read is not the
    only possible impurity. **Severity:** `breaks-contract`.

26. **The requirement audit has exactly three unsupported cases: `PKQ2`, the
    debug-toggle portion of `PKR4`, and absolute-purity requirement `PKM1`.**
    **Document/section:** A sections 1, 3.1, 5, and 10; B M5; C `PKQ2`, `PKR4`,
    and `PKM1`. **Scenario:** file suffix and `ignored` are missing; A/B return a
    score breakdown but assign no visible debug toggle; and C requires a 100
    percent pure library while A/B deliberately make `searchPage` impure
    without deferring or amending the requirement. Every other `PKQ`, `PKR`, or
    `PKM` row has at least a claimed section or explicit deferral. **Severity:**
    `breaks-contract`.

27. **The no-allocation claims are contradicted by ordinary query, output,
    result, and table operations, and `@nogc` tests cannot detect them.**
    **Document/section:** context fact 2; A sections 3.2, 4.4, 6, 8, and 10;
    B M1. **Scenario:** a ninth constraint or fifth fuzzy part invokes
    Mallocator; positions beyond a sink's inline capacity grow it; mutating a
    shared CoW result clones it; and inserting a table entry grows storage after
    construction. All are legal `@nogc` allocations, so attribute gating does
    not prove that parsing, candidate scoring, or a keystroke allocates nothing.
    **Severity:** `breaks-contract`.

28. **Exact typo verification is neither final-row-only nor bounded by the
    window, and it contradicts the promised zero-typo cost.**
    **Document/section:** A sections 4.1 and 4.4. **Scenario:** `abc` against
    `ac` requires earlier rows to identify the missing `b`; a 1,000-byte needle
    against a one-byte haystack with budget 999 requires about 1,000 traceback
    steps despite a one-byte window, and finding the minimum typo count across
    tied optima can require additional state or branching. The same mandatory
    walk makes `maxTypos = 0` cost more than a no-typo score path unless the
    baseline is redefined to pay unnecessary verification. **Severity:**
    `breaks-contract`.

29. **The composite ranking formula is too incomplete to produce deterministic
    results.** **Document/section:** A section 5. **Scenario:** the distance
    algorithm is only a value somewhere from 0 to -20; the entry-point list
    ends in an ellipsis; greedy filename `quality` has no formula; and
    path-alignment coverage lacks a denominator and rounding order. Two
    conforming implementations can reverse the same candidates. **Severity:**
    `breaks-contract`.

30. **Arbitrary brace alternation cannot be implemented by the stated
    allocation-free two-pointer backtracker with the promised
    `O(pattern * path)` bound.** **Document/section:** A section 7.
    **Scenario:** `{a,aa}{a,aa}{a,aa}...b` against a long run of `a` ending in
    `c` has exponentially many naive expansions; retaining branch states needs
    storage proportional to the pattern, while one two-pointer checkpoint is
    incomplete. No alternation-depth cap, caller workspace, automaton, or
    malformed-pattern error contract is specified. **Severity:**
    `breaks-contract`.

31. **The prefilter and kernel complexity claims omit required work.**
    **Document/section:** A sections 4.1-4.3. **Scenario:** for needle `ab` and
    haystack `ab` followed by 1,022 irrelevant bytes, the returned window is two
    bytes but finding the last `b` scans all 1,024 bytes. High-density chunks
    need a fresh comparison for every advanced needle position, generic mode
    scales with the host-overridable cursor count, and log-shift horizontal
    propagation contributes a `log(width)` factor omitted from the stated
    kernel bound. **Severity:** `breaks-contract`.

32. **The top-K complexity contract has no hard worst-case bound.**
    **Document/section:** A sections 1 and 5. **Scenario:** Hoare quickselect
    with an unspecified pivot is quadratic on adversarial ordering, and
    `offset + limit` can wrap `size_t` before boundary selection. The promised
    hard budget requires a bounded strategy or explicit input contracts.
    **Severity:** `breaks-contract`.

33. **The abort-pointer contract omits atomicity, visibility, lifetime, and
    zero-granularity rules.** **Document/section:** A sections 8 and 10.
    **Scenario:** another thread writes a plain `shared bool` while
    `searchPage` reads it without a specified atomic operation or memory order;
    copied options can outlive a local boolean, and `probeEvery = 0` has no
    defined rejection or interpretation and commonly causes division by zero
    or disables probes. **Severity:** `breaks-contract`.

34. **The final tie-break depends on candidate iteration order despite the
    invariant explicitly excluding that dependency.** **Document/section:** A
    sections 1 and 5; C's pool-based walker. **Scenario:** equal-score,
    equal-recency paths discovered in opposite worker orders get opposite
    candidate indices and reverse rank. The API does not require a stable corpus
    identifier rather than enumeration position. **Severity:**
    `breaks-contract`.

35. **Frecency lacks the numeric and time-order contracts needed for
    deterministic integer ranking.** **Document/section:** A sections 1, 5,
    and 6. **Scenario:** exponential sums, square roots, and piecewise-linear
    scores are fractional but `RankContext.frecencyScore` is `int`, with no
    rounding, saturation, or return type specified; a soft-knee result near
    10.5 can become 10 or 11, and libm differences near a boundary can change
    ties. Future timestamps, out-of-order insertions, or clock rollback make
    `daysAgo` negative, invalidate newest-first early exit, and can exceed the
    claimed practical maximum. **Severity:**
    `breaks-contract`.

36. **Empty and constraints-only queries have no complete matching or ranking
    semantics and cannot satisfy frecency ranking under the stated formula.**
    **Document/section:** A sections 3.1-5. **Scenario:** `Query.init`, `git:m`,
    or a query containing only one-byte dropped parts has no effective needle;
    the spec does not say which candidates match, their `MatchKind`, base,
    `endCol`, or filename/path bonuses. If base is zero, the multiplicative
    `base * frecencyScore / 100` is zero for hot and cold files, omitting the
    upstream frecency-only empty-query rule. **Severity:** `breaks-contract`.

37. **`Matcher` has no thread-safety, cloning, or per-worker ownership contract
    despite the parallel host design.** **Document/section:** A sections 1 and
    4.3; C interactivity rationale. **Scenario:** sharing one matcher races on
    retained score and mask matrices, while its unique buffers are move-only;
    the API does not define how to provision one matcher per worker without
    per-query construction. **Severity:** `breaks-contract`.

38. **The partial-results protocol does not define how encounter-order pages
    become one globally ranked result set.** **Document/section:** A sections 5
    and 8. **Scenario:** the first 20 matches can all score poorly while the
    best match occurs at candidate 100,000. The spec does not require an
    accumulating sink, state whether earlier partials remain, define when
    `selectTopK` reruns, or explain how visible rows are displaced without
    duplication. **Severity:** `gap`.

39. **The matrix allocation strategy cannot simultaneously support changing
    needle lengths, avoid per-keystroke allocation, and retain a bounded
    footprint.** **Document/section:** A sections 4.3 and 10. **Scenario:**
    sizing rows to the active needle rebuilds storage as the user types;
    preallocating the claimed maximum consumes at least about 7.5 MiB for the
    score matrix alone, before masks and per-worker copies. Neither policy nor
    a hard memory budget is specified. **Severity:** `gap`.

40. **Allocation failure is absent from the supposedly exhaustive error and
    outcome model.** **Document/section:** context fact 2; A sections 1, 4.3,
    and 10. **Scenario:** matrix construction or `SmallBuffer` growth can fail,
    but no constructor returns `Expected` and no `MatchKind` names allocation
    failure; throwing contradicts `nothrow`, null threatens `@safe`, and process
    termination contradicts the explicit-outcome invariant. **Severity:**
    `gap`.

41. **The scoring constants conflict with the stated camel/snake and filename
    quality goals.** **Document/section:** A sections 4.2, 5, and 9.4.
    **Scenario:** `foo` against `xf foo` scores 40; for lowercase `fb`,
    `foobar` and `fooBar` both score about 29 because camel and case bonuses are
    disabled, while `foo_bar` scores about 32 and exact `fb` about 44. With
    other terms equal, query `fo` can give directory-prefix `fo/bar` base 36,
    while filename match `x/foo` gets base 28 plus only four filename points,
    totaling 32. **Severity:** `gap`.

42. **The grammar is incomplete or ambiguous for advertised edge forms.**
    **Document/section:** A section 3.1. **Scenario:** `*.{rs,md}` depends on
    whether “wildcard” includes `{`; `type:` promises an error absent from the
    dispatch table; malformed `[` and `{a,` become globs without validation;
    `!!foo` has no mapping into one negation bit; status case and non-ASCII
    values are unspecified; Windows backslashes are not path separators;
    escaped whitespace cannot form a literal-space token; and location overflow
    or otherwise-unreserved trailing colons have no rule. **Severity:** `gap`.

43. **`budget + 1` greedy cursors is not specified sufficiently to establish
    equivalence with the LCS oracle.** **Document/section:** A section 4.1.
    **Scenario:** for `abc` against `ac` at budget 1, a cursor initialized as
    “one leading byte skipped” fails while a cursor cloned from the zero-skip
    path after matching `a` succeeds; both fit the prose. Clone timing,
    dominance, same-hit advancement, deletion closure, and state merging are
    normative to exactness but absent. **Severity:** `gap`.

44. **The benchmarks omit the per-keystroke construction and mutation costs
    most likely to violate the frame budget.** **Document/section:** A section
    9; B M1-M3. **Scenario:** score rows reuse a matcher and parser throughput is
    isolated, so reconstructing or growing matrices, crossing Query SBO,
    cloning a survivor CoW buffer, or growing output on every keystroke can pass
    all stated score-only rows. The C comparator's construction and allocator
    costs are likewise outside the measured tier. **Severity:** `gap`.

45. **Committed retired-instruction snapshots under `-mcpu=native` are neither
    portable nor sufficient performance gates.** **Document/section:** A
    sections 9.1 and 9.3; B M0 and M3. **Scenario:** a compiler or CPU change
    creates a different native sequence without a source regression, while a
    layout change can reduce retired instructions yet double cache misses and
    wall time. No compiler pin, ISA partition, baseline invalidation,
    statistical threshold, or cache-counter gate is specified; “within noise”
    is unevaluable. **Severity:** `gap`.

46. **The M3 comparison against `telescope-fzf-native` is not an equal-work or
    objectively measurable quality gate.** **Document/section:** A section
    9.3; B M3. **Scenario:** the D path performs substitution and typo
    verification while the C reference is ASCII-only, implements different
    acceptance semantics, and may have different retained-state and allocation
    costs. The D benchmark can use `maxTypos = 0` or otherwise change
    selectivity to appear faster, and “equal-or-better ranking quality” has no
    metric when one engine omits a typo candidate. **Severity:** `gap`.

47. **The corpora and golden-order design leave important regressions
    undetected.** **Document/section:** A sections 9.2 and 9.4; B M3-M7.
    **Scenario:** the suites can pass while breaking paginated top-K,
    generation cancellation, exact score-breakdown terms, two-byte queries,
    partial UTF-8, path normalization, table-key lifetimes, or operational
    protocols because a fixed ordering does not necessarily assert set
    equality, exact scores, monotonic properties, or state transitions. The
    only real corpus is small, large data are distribution-synthetic, and the C
    gate is ASCII-only. **Severity:** `gap`.

48. **`FrecencyTable` bounds timestamps per file but not the number of files or
    stale entries.** **Document/section:** A section 6.1. **Scenario:** opening
    and then deleting a succession of generated paths grows both the in-memory
    table and persisted snapshot indefinitely, undermining `PKR5` startup
    safety. **Severity:** `gap`.

49. **M3 and M4 assign shared typo verification inconsistently, and position
    helper ownership contradicts the specification.** **Document/section:** A
    section 4.4; B M3-M4. **Scenario:** A marks section 4.4 as M4, while B
    requires score-tier verification in M3 and its exit gate; B M4 also ships
    position-merge helpers although A assigns range merging to the caller. A
    reviewer cannot identify the owning milestone or public API. **Severity:**
    `editorial`.

50. **`F0` and `P3` requirement ownership contradicts itself across the plan
    and picker milestones.** **Document/section:** B introduction and M6; C
    milestones. **Scenario:** B says F0 satisfies `PKR1`-`PKR3` and implements
    in-memory frecency/combo in M6, while C gives F0 only `PKR1` and assigns
    `PKR2`-`PKR6` to P3. This obscures acceptance, dependency order, and
    responsibility for the in-memory half. **Severity:** `gap`.

51. **Several normative deliverables lack an owning milestone or evaluable
    gate, while required documentation arrives too late.** **Document/section:**
    A sections 1, 4.3-4.4, 9.3, and 10; B milestones. **Scenario:** M4-M6 have
    no explicit exit gates; no milestone finishes the missing public
    signatures, runtime scoring validation, malformed-glob policy,
    long-fallback positions, per-entry complexity documentation, constraint
    evaluator, or stated out-of-process `fzf` baseline. The new library exists
    from M0 but its required Diataxis tree waits until M7, and M7's repo-green
    check cannot prove that nonexistent hue P0 consumes the API without
    patches. **Severity:** `gap`.

**Review questions with no findings:** none.
