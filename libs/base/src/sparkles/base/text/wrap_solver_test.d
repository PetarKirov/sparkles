/** Observable owned wrapping regressions and a tiny independent exhaustive oracle. */
module sparkles.base.text.wrap_solver_test;

version (unittest)
{
    import sparkles.base.text.wrap;
    import sparkles.base.text.wrap_solver;
    import sparkles.base.text.utf : UtfToken;
    import sparkles.base.text.unicode_algorithm : UnicodeBoundary;
    import sparkles.base.text.line_break : LineBreakWorkspaceEntry;
    import sparkles.base.text.boundaries : WordBoundaryWorkspace;
    import std.bigint : BigInt;
    import core.lifetime : move;

    @system:

    private WrapLimits grants() @safe pure nothrow @nogc
        => WrapLimits(100_000, 100_000, 100_000, 100_000, 100_000, 100_000, 10_000_000, 100_000);
    private WrapSolverScratch solverScratch(size_t records = 128, size_t states = 4096)
    {
        WrapSolverScratch scratch;
        scratch.states = new WrapSearchState[](states);
        scratch.selected = new size_t[](records);
        scratch.ranked = new size_t[](states);
        scratch.ordering = new size_t[](states);
        scratch.temporary = new size_t[](states);
        scratch.ids = new ulong[](records);
        scratch.temporaryIds = new ulong[](records);
        scratch.candidatePrimitives = new WrapPrimitive[](records);
        scratch.candidateGlues = new MeasuredGlue[](records);
        scratch.glueWidths = new long[](records * 2);
        scratch.sourceTransforms = new SourceRecord[](records);
        scratch.projection = WrapProjectionScratch(new WrapLine[](records),
            new WrapFragment[](records * 8), new SourceRecord[](records), new CellStyleSnapshot[](records));
        return scratch;
    }
    private WrapPlanStorage planStorage(size_t records = 128)
        => WrapPlanStorage(new WrapLine[](records), new WrapFragment[](records * 8),
            new SourceRecord[](records), new CellStyleSnapshot[](records));
    private CellWrapScratch cellScratch(size_t records = 128, size_t states = 4096)
    {
        CellWrapScratch scratch;
        scratch.tokens = new UtfToken[](records);
        scratch.atoms = new CellAtom[](records);
        scratch.clusters = new CellCluster[](records);
        scratch.styles = new CellStyleSnapshot[](records);
        scratch.opportunities = new UnicodeBoundary[](records);
        scratch.words = new UnicodeBoundary[](records);
        scratch.lineWorkspace = new LineBreakWorkspaceEntry[](records);
        scratch.wordWorkspace = new WordBoundaryWorkspace[](records);
        scratch.primitives = new WrapPrimitive[](records);
        scratch.endpoints = new WrapEndpoint[](records);
        scratch.sourceRecords = new SourceRecord[](records);
        scratch.geometry = new WrapGeometry[](records);
        scratch.indentStyles = new CellStyleSnapshot[](records);
        scratch.indentStyleStarts = new size_t[](records);
        scratch.styleTransitions = new size_t[](records * 2);
        scratch.candidateFragments = new WrapFragment[](records * 8);
        scratch.realizedFragments = new WrapFragment[](records * 8);
        scratch.solver = solverScratch(records, states);
        return scratch;
    }
    private string render(scope const ref WrapPlan plan)
    {
        size_t extent;
        auto result = tryMaterializeWrap(plan, WrapEmissionOptions(sourceRevision: plan.source.revision,
            resourceRevision: plan.resourceRevision), null, extent);
        assert(result.succeeded || result.status == WrapStatus.needOutput);
        char[] bytes = new char[](result.required);
        result = tryMaterializeWrap(plan, WrapEmissionOptions(sourceRevision: plan.source.revision,
            resourceRevision: plan.resourceRevision), bytes, extent);
        assert(result.succeeded);
        return cast(string) bytes;
    }

    /// Parent smoke driver may invoke this under -unittest, exercising the real
    /// bounded planner, emitter and mapping surface rather than a mocked callback.
    void runOwnedWrappingSmoke()
    {
        const source = "e\x1b[31m\u0301x";
        WrapOptions options;
        options.width = CellWidth.bounded(1);
        options.finalStyle = FinalStylePolicy.restoreInitialState;
        auto scratch = cellScratch();
        auto storage = planStorage();
        WrapPlan plan;
        const result = tryWrapCells(SourceSnapshot(source, 7, 11), options, grants(), scratch, storage, plan);
        assert(result.succeeded && plan.lines.length == 2);
        assert(render(plan) == "e\x1b[31m\u0301\x1b[0m\n\x1b[31mx\x1b[0m");
        assert(plan.lines[0].contentAdvance == 1 && plan.lines[1].contentAdvance == 1);
        assert(plan.lines[0].sourceEnd == 8 && plan.lines[1].sourceStart == 8);
        assert(cellToSource(plan, 1, 0, WrapAffinity.after).sourceBoundary == 8);
        assert(sourceToLine(plan, 8, WrapAffinity.before).line == 0);
        assert(sourceToLine(plan, 8, WrapAffinity.after).line == 1);
        char[9] original;
        size_t extent = 99;
        assert(tryCopyOriginal(plan, original[], extent).succeeded && extent == 9 && original[] == source);
        char[22] shortOutput; shortOutput[] = '!';
        extent = 99;
        const shortResult = tryMaterializeWrap(plan, WrapEmissionOptions(sourceRevision: 11), shortOutput[], extent);
        assert(shortResult.status == WrapStatus.needOutput && shortResult.required == 23);
        assert(extent == 99 && shortOutput[] == "!!!!!!!!!!!!!!!!!!!!!!");
        char[25] exactOutput; exactOutput[] = '!';
        assert(tryMaterializeWrap(plan, WrapEmissionOptions(sourceRevision: 11), exactOutput[], extent).succeeded);
        assert(extent == 23 && exactOutput[23 .. $] == "!!");
        const stale = tryMaterializeWrap(plan, WrapEmissionOptions(sourceRevision: 12), shortOutput[], extent);
        assert(stale.status == WrapStatus.stalePlan && extent == 23 && shortOutput[] == "!!!!!!!!!!!!!!!!!!!!!!");
    }
    @("text.wrap.realCellDriverStyleClusterAndAtomicEmission") unittest { runOwnedWrappingSmoke(); }

    @("text.wrap.cellsMandatoryZeroProtectionTabsCollapseAndBalanced") unittest
    {
        assert(wrapText("", WrapOptions(width: CellWidth.bounded(0))) == "");
        assert(wrapText("a\n\n", WrapOptions(width: CellWidth.bounded(8))) == "a\n\n");
        auto plan = cellWrapPlan("世\n", WrapOptions(width: CellWidth.bounded(0)));
        assert(plan.lines.length == 2 && plan.lines[0].overfull && plan.lines[0].contentAdvance == 2);
        assert(plan.lines[1].contentAdvance == 0 && render(plan) == "世\n");
        plan = cellWrapPlan("a\u00A0b", WrapOptions(width: CellWidth.bounded(1)));
        assert(plan.lines.length == 1 && plan.lines[0].overfull && !plan.lines[0].emergency);
        WrapOptions options = WrapOptions(width: CellWidth.bounded(8), tabs: TabPolicy.expand);
        options.tabStops.interval = CellExtent(4);
        plan = cellWrapPlan("a\tb", options);
        assert(render(plan) == "a   b" && plan.lines[0].contentAdvance == 5);
        options.startColumn = CellExtent(1);
        plan = cellWrapPlan("a\tb", options);
        assert(render(plan) == "a  b" && plan.lines[0].contentAdvance == 4 && plan.lines[0].endColumn == 5);
        options = WrapOptions(width: CellWidth.bounded(6), whitespace: WhitespaceMode.collapse);
        assert(wrapText("aaa bb cc ddddd", options) == "aaa bb\ncc\nddddd");
        options.solver = WrapSolver.balanced;
        plan = cellWrapPlan("aaa bb cc ddddd", options);
        assert(render(plan) == "aaa\nbb cc\nddddd" && plan.objective.costLow == 10 && plan.objective.costHigh == 0);
        plan = cellWrapPlan("a  b", options);
        assert(render(plan) == "a b");
        char[4] original;
        size_t extent;
        assert(tryCopyOriginal(plan, original[], extent).succeeded && original[] == "a  b");
        assert(cellToSource(plan, 0, 2, WrapAffinity.before).sourceBoundary == 3);
    }

    @("text.wrap.trimmedLeadingWhitespaceDoesNotBlockOverfullUnits")
    @system unittest
    {
        import std.string : replace;
        import std.array : split;
        import sparkles.base.text.grapheme : byGraphemeCluster;

        string content(string text)
            => text.replace(" ", "").replace("\t", "").replace("\n", "");

        foreach (source; ["  abc def", "\t  e\u0301👩‍💻 Z"])
            foreach (whitespace; [WhitespaceMode.collapse, WhitespaceMode.trimAroundBreak])
                foreach (solver; [WrapSolver.greedy, WrapSolver.balanced])
                    foreach (width; [0UL, 1UL])
                    {
                        const plan = cellWrapPlan(source, WrapOptions(
                            width: CellWidth.bounded(width), whitespace: whitespace, solver: solver));
                        const output = render(plan);
                        assert(content(output) == content(source));
                        foreach (i, line; output.split("\n"))
                        {
                            assert(plan.lines[i].overfull == (plan.lines[i].contentAdvance > cast(long) width));
                            if (plan.lines[i].overfull)
                            {
                                size_t clusters;
                                foreach (unit; line.byGraphemeCluster)
                                    if (!unit.isEscape) ++clusters;
                                assert(clusters == 1, "emergency overflow must retain exactly one whole grapheme");
                            }
                        }
                        auto original = new char[](source.length);
                        size_t extent;
                        assert(tryCopyOriginal(plan, original, extent).succeeded);
                        assert(extent == source.length && original == source);
                    }
    }

    @("text.wrap.singleBalancedParagraphHasBoundedFutureStates")
    unittest
    {
        import std.array : join;
        string[] words;
        foreach (_; 0 .. 20) words ~= "aaa";
        const source = words.join(" ");
        auto scratch = cellScratch(128, 4096);
        WrapPlan plan;
        const result = tryWrapCells(SourceSnapshot(source),
            WrapOptions(width: CellWidth.bounded(15), solver: WrapSolver.balanced,
                whitespace: WhitespaceMode.trimAroundBreak),
            grants(), scratch, planStorage(), plan);
        assert(result.succeeded && plan.proof == WrapProof.completeExact);
        assert(plan.lines.length == 5 && plan.objective.costLow == 0);
        assert(render(plan) == "aaa aaa aaa aaa\naaa aaa aaa aaa\naaa aaa aaa aaa\naaa aaa aaa aaa\naaa aaa aaa aaa");
    }

    @("text.wrap.failedPlanningPreservesPublishedStorageAndSentinels") unittest
    {
        WrapOptions options = WrapOptions(width: CellWidth.bounded(2));
        auto scratch = cellScratch();
        auto storage = planStorage();
        WrapPlan published;
        assert(tryWrapCells(SourceSnapshot("ab", 3, 4), options, grants(), scratch, storage, published).succeeded);
        const beforeLines = published.lines.dup;
        const beforeFragments = published.fragments.dup;
        const beforeRecords = published.sourceRecords.dup;
        const beforeStyles = published.styles.dup;
        auto replacement = planStorage();
        replacement.lines[] = WrapLine(sourceStart: 999);
        replacement.fragments[] = WrapFragment(anchor: 999);
        replacement.sourceRecords[] = SourceRecord(999, 999);
        replacement.styles[] = CellStyleSnapshot(id: 999);
        auto limited = grants(); limited.transitions = 0;
        const failed = tryWrapCells(SourceSnapshot("abcd", 3, 5), options, limited, scratch, replacement, published);
        assert(failed.status == WrapStatus.budgetExhausted && failed.kind == WrapBudgetKind.transitions);
        assert(published.source.revision == 4 && published.lines == beforeLines && published.fragments == beforeFragments
            && published.sourceRecords == beforeRecords && published.styles == beforeStyles);
        foreach (line; replacement.lines) assert(line.sourceStart == 999);
        foreach (fragment; replacement.fragments) assert(fragment.anchor == 999);
        foreach (record; replacement.sourceRecords) assert(record.start == 999);
        foreach (style; replacement.styles) assert(style.id == 999);
        // Scratch which aliases old publication must be rejected before scanning.
        auto aliased = scratch;
        aliased.solver.projection.lines = storage.lines;
        assert(tryWrapCells(SourceSnapshot("zz"), options, grants(), aliased, replacement, published).status == WrapStatus.invalidInput);
        assert(published.lines == beforeLines && storage.lines[0].sourceStart == beforeLines[0].sourceStart);
        options.overflow = CellOverflowPolicy.reject;
        const overflow = tryWrapCells(SourceSnapshot("abcd"), options, grants(), scratch, replacement, published);
        assert(overflow.status == WrapStatus.unbreakableOverflow && overflow.sourceStart == 0 && overflow.sourceEnd == 4);
        const formatting = tryWrapCells(SourceSnapshot("a\x1b[2J"), options, grants(), scratch, replacement, published);
        assert(formatting.status == WrapStatus.nonTextTerminalOperation && formatting.sourceStart == 1 && formatting.sourceEnd == 5);
        assert(published.source.revision == 4 && published.lines == beforeLines);
    }

    private MeasurableInput rigidInput(string source, const(long)[] advances,
        ref WrapPrimitive[] primitives, ref WrapEndpoint[] endpoints, ref SourceRecord[] records)
    {
        primitives = new WrapPrimitive[](advances.length);
        endpoints = new WrapEndpoint[](advances.length);
        records = new SourceRecord[](advances.length);
        foreach (i, advance; advances)
        {
            primitives[i] = WrapPrimitive(kind: advance < 0 ? PrimitiveKind.kern : PrimitiveKind.box,
                id: i + 100, advance: advance, fragment: WrapFragment(kind: FragmentKind.bytes,
                    bytes: source[i .. i + 1], sourceStart: i, sourceEnd: i + 1, provenance: ProvenanceKind.original));
            endpoints[i] = WrapEndpoint(end: i + 1, contentEnd: i + 1, sourceEnd: i + 1,
                alternativeId: i + 200, tag: i + 1 == advances.length ? OpportunityTag.forced : OpportunityTag.optional,
                terminal: i + 1 == advances.length, paragraphEnd: i + 1 == advances.length);
            records[i] = SourceRecord(i, i + 1, ProvenanceKind.original, i);
        }
        return MeasurableInput(SourceSnapshot(source), primitives, endpoints, records, WrapDimension.cells);
    }

    // Independent exhaustive reference: bit masks enumerate the entire tiny
    // candidate DAG. BigInt, direct sums, and complete sequence comparison are
    // intentionally independent of production cost/search/realization helpers.
    private struct OraclePath { BigInt cost; size_t[] ends; bool exists; }
    private OraclePath exhaustiveBalanced(const(long)[] advances, const(long)[] capacities,
        size_t minLines, size_t maxLines)
    {
        OraclePath best;
        const n = advances.length;
        foreach (mask; 0U .. (1U << (n - 1)))
        {
            size_t[] ends;
            foreach (i; 1 .. n) if (mask & (1U << (i - 1))) ends ~= i;
            ends ~= n;
            if (ends.length < minLines || ends.length > maxLines) continue;
            BigInt cost;
            bool legal = true;
            size_t start;
            foreach (line, end; ends)
            {
                long width;
                foreach (advance; advances[start .. end]) width += advance;
                const capacity = capacities[line < capacities.length ? line : capacities.length - 1];
                if (width < 0 || width > capacity) { legal = false; break; }
                if (end != n)
                {
                    BigInt slack = BigInt(capacity - width);
                    cost += slack * slack;
                }
                start = end;
            }
            if (!legal) continue;
            bool later;
            foreach (i; 0 .. (ends.length < best.ends.length ? ends.length : best.ends.length))
                if (ends[i] != best.ends[i]) { later = ends[i] > best.ends[i]; break; }
            if (!best.exists || cost < best.cost || (cost == best.cost
                && (ends.length < best.ends.length || (ends.length == best.ends.length && later))))
            {
                auto candidate = OraclePath(move(cost), ends, true);
                move(candidate, best);
            }
        }
        return best;
    }
    @("text.wrap.fixedObjectsBalancedIndependentExhaustiveVariableGeometryAndNegativeKern") unittest
    {
        foreach (n; 1 .. 7)
            foreach (seed; 0 .. 48)
            {
                auto advances = new long[](n);
                char[] source = new char[](n); source[] = 'x';
                foreach (i; 0 .. n) advances[i] = (seed + i * 7) % 7 == 0 ? -2 : 1 + (seed + i * 3) % 4;
                long[2] capacities = [4 + seed % 3, 7 - seed % 2];
                WrapPrimitive[] primitives; WrapEndpoint[] endpoints; SourceRecord[] records;
                auto input = rigidInput(cast(string) source, advances, primitives, endpoints, records);
                WrapGeometry[2] geometry = [WrapGeometry(capacity: capacities[0]), WrapGeometry(capacity: capacities[1])];
                WrapSolverOptions options = WrapSolverOptions(solver: WrapSolver.balanced);
                auto expected = exhaustiveBalanced(advances, capacities[], 1, size_t.max);
                WrapPlan plan;
                const result = trySolveWrap(input, WrapGeometrySequence(geometry[], true), WrapProvider.init,
                    options, grants(), solverScratch(), planStorage(), plan);
                if (!expected.exists) { assert(result.status == WrapStatus.noFeasiblePlan); continue; }
                assert(result.succeeded && plan.proof == WrapProof.completeExact);
                assert(BigInt(plan.objective.costLow) == expected.cost && plan.objective.costHigh == 0);
                assert(plan.lines.length == expected.ends.length);
                foreach (i, line; plan.lines) assert(line.sourceEnd == expected.ends[i]);
            }
    }

    @("text.wrap.knuthPlassExactRatioDemeritAndBatchedGlueBounds") unittest
    {
        WrapPrimitive[3] primitives;
        primitives[0] = WrapPrimitive(kind: PrimitiveKind.box, id: 1, advance: 7,
            fragment: WrapFragment(bytes: "x", sourceStart: 0, sourceEnd: 1));
        primitives[1] = WrapPrimitive(kind: PrimitiveKind.glue, id: 2, advance: 1, stretch: 4,
            fragment: WrapFragment(kind: FragmentKind.glue, repeat: 1, sourceStart: 1, sourceEnd: 2));
        primitives[2] = WrapPrimitive(kind: PrimitiveKind.box, id: 3, advance: 1,
            fragment: WrapFragment(bytes: "x", sourceStart: 2, sourceEnd: 3));
        WrapEndpoint[2] endpoints = [WrapEndpoint(end: 2, contentEnd: 2, sourceEnd: 2, alternativeId: 10, penalty: 3),
            WrapEndpoint(end: 3, contentEnd: 3, sourceEnd: 3, alternativeId: 20,
                tag: OpportunityTag.forced, terminal: true, paragraphEnd: true)];
        SourceRecord[3] records = [SourceRecord(0, 1), SourceRecord(1, 2), SourceRecord(2, 3)];
        auto input = MeasurableInput(SourceSnapshot("x x"), primitives[], endpoints[], records[]);
        WrapGeometry[1] geometry = [WrapGeometry(capacity: 10)];
        WrapSolverOptions options = WrapSolverOptions(solver: WrapSolver.knuthPlass,
            stretchTolerance: WrapRatio(1, 1), linePenalty: 10, minimumLines: 2, maximumLines: 2);
        WrapPlan plan;
        auto result = trySolveWrap(input, WrapGeometrySequence(geometry[], true), WrapProvider.init,
            options, grants(), solverScratch(), planStorage(), plan);
        assert(result.succeeded && plan.objective.costLow == 638 && !plan.objective.negativeCost);
        assert(plan.lines[0].adjustment.numerator == 1 && plan.lines[0].adjustment.denominator == 2
            && plan.lines[0].fitness == WrapFitness.decent && plan.lines[0].contentAdvance == 10);
        assert(plan.fragments[1].advance == 3 && plan.fragments[1].repeat == 3);
        MeasuredGlue[1] bounded = [MeasuredGlue(1, 4, 0, 1, 2, 0)];
        long[2] widths;
        assert(realizeWrapGlue(bounded[], 1, 4, WrapRatio(3, 4), WrapRatio(1, 1), widths[]).status == WrapStatus.noFeasiblePlan);
        enum long M = 1_000_000_000;
        MeasuredGlue[2] glues = [MeasuredGlue(1, M, 0, 1, 1, 0), MeasuredGlue(1, 1, 0, 1, M + 1, 1)];
        long[4] realized;
        assert(realizeWrapGlue(glues[], 2, M + 2, WrapRatio(M, M + 1), WrapRatio(M, 1), realized[]).succeeded);
        assert(realized[0 .. 2] == [1L, M + 1]);
    }

    @("text.wrap.rankedAlternativesDistinctEqualBoundaryIdsConstraintsAndAtomicList") unittest
    {
        long[3] advances = [1, 1, 1];
        WrapPrimitive[] primitives; WrapEndpoint[] endpoints; SourceRecord[] records;
        auto input = rigidInput("abc", advances[], primitives, endpoints, records);
        auto extra = endpoints[0]; extra.alternativeId = 999;
        endpoints = [endpoints[0], extra, endpoints[1], endpoints[2]];
        input.endpoints = endpoints;
        WrapGeometry[1] g0 = [WrapGeometry(capacity: 2, id: 10)];
        WrapGeometry[1] g1 = [WrapGeometry(capacity: 2, id: 20)];
        WrapGeometrySequence[2] geometries = [WrapGeometrySequence(g0[], true, 10), WrapGeometrySequence(g1[], true, 20)];
        WrapSolverOptions options = WrapSolverOptions(solver: WrapSolver.balanced, minimumLines: 2, maximumLines: 2);
        auto scratch = solverScratch();
        WrapPlan[] prepared = new WrapPlan[](16);
        WrapAlternativeStorage storage = WrapAlternativeStorage(new WrapPlan[](16), planStorage());
        WrapAlternativePlans plans;
        auto result = trySolveWrapAlternatives(input, geometries[], WrapProvider.init, options, grants(),
            2, false, scratch, prepared, storage, plans);
        assert(result.succeeded && plans.moreAlternatives && !plans.exhaustive && plans.plans.length == 2);
        assert(plans.plans[0].lines[0].sourceEnd == 2 && plans.plans[0].geometryAlternative == 0);
        assert(plans.plans[1].lines[0].sourceEnd == 2 && plans.plans[1].geometryAlternative == 1);
        auto nextStorage = WrapAlternativeStorage(new WrapPlan[](16), planStorage());
        result = trySolveWrapAlternatives(input, geometries[], WrapProvider.init, options, grants(),
            16, true, scratch, prepared, nextStorage, plans);
        assert(result.succeeded && plans.exhaustive && !plans.moreAlternatives && plans.plans.length == 6);
        assert(plans.plans[2].lines[0].alternativeId == 200 && plans.plans[4].lines[0].alternativeId == 999);
        const oldPlans = plans.plans;
        auto thirdStorage = WrapAlternativeStorage(new WrapPlan[](1), planStorage());
        thirdStorage.plans[0].policyIdentity = 999;
        result = trySolveWrapAlternatives(input, geometries[], WrapProvider.init, options, grants(),
            1, true, scratch, prepared, thirdStorage, plans);
        assert(result.status == WrapStatus.needResults && plans.plans.ptr == oldPlans.ptr && thirdStorage.plans[0].policyIdentity == 999);
        options.minimumLines = options.maximumLines = 4;
        result = trySolveWrapAlternatives(input, geometries[], WrapProvider.init, options, grants(),
            1, false, scratch, prepared, thirdStorage, plans);
        assert(result.succeeded && plans.exhaustive && !plans.plans.length);
    }

    void runOwnedWrappingRealizationSmoke()
    {
        WrapOptions options = WrapOptions(width: CellWidth.bounded(2));
        foreach (source; ["\u2764\u00AD\uFE0F", "\U0001F1E6\u00AD\U0001F1E7"])
        {
            const plan = cellWrapPlan(source, options);
            assert(plan.lines.length == 1 && plan.lines[0].visibleAdvance == 2);
            assert(render(plan) == (source == "\u2764\u00AD\uFE0F" ? "\u2764\uFE0F" : "\U0001F1E6\U0001F1E7"));
        }
        options.firstIndent = "\u2764";
        const joinedIndent = cellWrapPlan("\uFE0F", options);
        assert(joinedIndent.lines.length == 1 && joinedIndent.lines[0].visibleAdvance == 2);
        assert(render(joinedIndent) == "\u2764\uFE0F");
        options.firstIndent = null;
        CellFit fit;
        auto r = tryFitCellsWithReplacement(SourceSnapshot("\u2764"), CellExtent(1), "\uFE0F",
            options, grants(), cellScratch(), false, fit);
        assert(r.succeeded && fit.end == 0 && fit.advance.value == 0);
        r = tryFitCellsWithReplacement(SourceSnapshot("\U0001F1E6"), CellExtent(2), "\U0001F1E7",
            options, grants(), cellScratch(), false, fit);
        assert(r.succeeded && fit.end == 4 && fit.advance.value == 2);
        options.width = CellWidth.unbounded;
        options.tabs = TabPolicy.expand;
        options.whitespace = WhitespaceMode.preserve;
        const tabs = cellWrapPlan("a\tb", options);
        const visible = projectWrapCells(tabs, CellExtent(4)).visible;
        assert(render(visible) == "a   " && visible.lines[0].visibleAdvance == 4);
        assert(visible.sourceRecords[1].kind == ProvenanceKind.replacement
            && visible.sourceRecords[2].kind == ProvenanceKind.omission);
        const formatted = cellWrapPlan("\x1b[31me\u0301", options);
        const mapped = cellToSource(formatted, 1, 0, WrapAffinity.after);
        assert(mapped.status == WrapStatus.outOfRange);
        const lineEnd = cellToSource(formatted, 0, 1, WrapAffinity.after);
        assert(lineEnd.status == WrapStatus.ok && lineEnd.sourceBoundary == formatted.source.bytes.length);
        auto aliasScratch = cellScratch();
        fit = CellFit(text: cast(const(char)[]) aliasScratch.candidateFragments);
        r = tryFitPrefixCells(SourceSnapshot("x"), CellExtent(1), options, grants(), aliasScratch, fit);
        assert(r.status == WrapStatus.invalidInput);
        char[] longCluster;
        longCluster ~= 'e';
        foreach (i; 0 .. 1000) longCluster ~= "\u0301";
        longCluster ~= 'x';
        options.width = CellWidth.bounded(1);
        const longPlan = cellWrapPlan(longCluster, options);
        assert(longPlan.lines.length == 2 && longPlan.lines[0].sourceEnd == 2001);
        assert(render(longPlan) == cast(string) longCluster[0 .. 2001] ~ "\nx");
    }
    @("text.wrap.emittedWholeStreamDiscretionaryIndentReplacementClipAndAlias") unittest
        { runOwnedWrappingRealizationSmoke(); }

    @("text.wrap.knuthPlassShrinkBeforeOverflowAndEmptyPhysicalParagraph") unittest
    {
        WrapPrimitive[3] primitives = [
            WrapPrimitive(kind: PrimitiveKind.box, id: 1, advance: 10,
                fragment: WrapFragment(bytes: "x", sourceStart: 0, sourceEnd: 1)),
            WrapPrimitive(kind: PrimitiveKind.glue, id: 2, advance: 2, shrink: 2, minimum: 0, maximum: 2,
                fragment: WrapFragment(kind: FragmentKind.glue, repeat: 2, sourceStart: 1, sourceEnd: 2)),
            WrapPrimitive(kind: PrimitiveKind.box, id: 3, advance: 1,
                fragment: WrapFragment(bytes: "x", sourceStart: 2, sourceEnd: 3))];
        WrapEndpoint[2] endpoints = [
            WrapEndpoint(end: 2, contentEnd: 2, sourceEnd: 2, alternativeId: 1),
            WrapEndpoint(end: 3, contentEnd: 3, sourceEnd: 3, alternativeId: 2,
                tag: OpportunityTag.forced, terminal: true, paragraphEnd: true)];
        SourceRecord[3] records = [SourceRecord(0, 1), SourceRecord(1, 2), SourceRecord(2, 3)];
        MeasurableInput input = MeasurableInput(SourceSnapshot("x x"), primitives[], endpoints[], records[]);
        WrapGeometry[1] geometry = [WrapGeometry(capacity: 10)];
        WrapSolverOptions options = WrapSolverOptions(solver: WrapSolver.knuthPlass, minimumLines: 2, maximumLines: 2);
        WrapPlan plan;
        auto r = trySolveWrap(input, WrapGeometrySequence(geometry[], true), WrapProvider.init,
            options, grants(), solverScratch(), planStorage(), plan);
        assert(r.succeeded && plan.lines[0].contentAdvance == 10 && !plan.lines[0].overfull);
        assert(plan.lines[0].adjustment.numerator == 1 && plan.lines[0].adjustment.denominator == 1
            && plan.lines[0].adjustment.negative);
        MeasurableInput empty;
        empty.dimension = WrapDimension.physical;
        options = WrapSolverOptions.init;
        WrapPlan emptyPlan;
        r = trySolveWrap(empty, WrapGeometrySequence(geometry[], true), WrapProvider.init,
            options, grants(), solverScratch(), planStorage(), emptyPlan);
        assert(r.succeeded && emptyPlan.dimension == WrapDimension.physical
            && emptyPlan.lines.length == 1 && emptyPlan.lines[0].contentAdvance == 0);
        assert(emptyPlan.source.bytes.length == 0 && render(emptyPlan) == "");
    }

    @("text.wrap.indentTabsUseGeometryColumnAndStops")
    @system unittest
    {
        const wrapped = cellWrapPlan("abc", WrapOptions(width: CellWidth.bounded(10),
            firstIndent: "\t", indent: "\t"));
        assert(wrapped.lines.length == 2);
        assert(wrapped.lines[0].endColumn == 10 && wrapped.lines[1].endColumn == 9);
        assert(render(wrapped) == "\tab\n\tc");

        CellExtent[2] stops = [CellExtent(5), CellExtent(11)];
        WrapOptions options = WrapOptions(width: CellWidth.unbounded,
            startColumn: CellExtent(3), firstIndent: "a\tb",
            tabStops: CellTabStops(explicitStops: stops[], periodicTail: false));
        const positioned = cellWrapPlan("x", options);
        assert(positioned.lines[0].startColumn == 3 && positioned.lines[0].endColumn == 7);
        assert(render(positioned) == "a\tbx");

        options.firstIndent = "\t\t\t";
        WrapPlan failed;
        const result = tryWrapCells(SourceSnapshot("x"), options, grants(),
            cellScratch(), planStorage(), failed);
        assert(result.status == WrapStatus.noNextTabStop);
    }

    @("text.wrap.indentSnapshotsAndCopyThroughInheritedNativeStyle") unittest
    {
        WrapOptions options = WrapOptions(width: CellWidth.unbounded, firstIndent: "\x1b[31m>",
            initialStyle: CellStyleSnapshot(attributes: 1), indentStyle: CellStyleSnapshot(attributes: 2));
        const separate = cellWrapPlan("x", options);
        bool indentSeen, sourceSeen;
        foreach (ref const fragment; separate.fragments)
        {
            if (fragment.formatting || fragment.kind != FragmentKind.bytes) continue;
            assert(fragment.styleBefore < separate.styles.length && fragment.styleAfter < separate.styles.length);
            const style = separate.styles[fragment.styleBefore];
            if (fragment.bytes == ">")
            { assert(style.attributes == 2 && style.foreground == "31"); indentSeen = true; }
            if (fragment.bytes == "x")
            { assert(style.attributes == 1 && !style.foreground.length); sourceSeen = true; }
        }
        assert(indentSeen && sourceSeen);
        options.continuity = StyleContinuity.copyThrough;
        const combined = cellWrapPlan("x", options);
        sourceSeen = false;
        foreach (ref const fragment; combined.fragments)
            if (!fragment.formatting && fragment.kind == FragmentKind.bytes && fragment.bytes == "x")
            {
                assert(fragment.styleBefore < combined.styles.length);
                const style = combined.styles[fragment.styleBefore];
                assert(style.attributes == 1 && style.foreground == "31"); sourceSeen = true;
            }
        assert(sourceSeen);
    }

    @("text.wrap.fixedOverfullMustConsumeNearestPolicyUnit") unittest
    {
        long[2] advances = [6, 6];
        WrapPrimitive[] primitives; WrapEndpoint[] endpoints; SourceRecord[] records;
        auto input = rigidInput("ab", advances[], primitives, endpoints, records);
        foreach (ref endpoint; endpoints) endpoint.allowOverfull = true;
        WrapGeometry[1] geometry = [WrapGeometry(capacity: 5)];
        foreach (solver; [WrapSolver.greedy, WrapSolver.balanced, WrapSolver.knuthPlass])
        {
            WrapPlan plan;
            const r = trySolveWrap(input, WrapGeometrySequence(geometry[], true), WrapProvider.init,
                WrapSolverOptions(solver: solver), grants(), solverScratch(), planStorage(), plan);
            assert(r.succeeded && plan.lines.length == 2 && plan.objective.overfullLines == 2);
            assert(plan.lines[0].sourceEnd == 1 && plan.lines[1].sourceEnd == 2);
        }
    }

    @("text.wrap.explicitTrimPreservesInternalSpacesAndSourceLedger") unittest
    {
        WrapOptions options = WrapOptions(width: CellWidth.bounded(4), whitespace: WhitespaceMode.trimAroundBreak);
        const plan = cellWrapPlan("aaaa bbbb cccc", options);
        assert(plan.lines.length == 3 && render(plan) == "aaaa\nbbbb\ncccc");
        assert(plan.sourceRecords[4].kind == ProvenanceKind.omission && plan.sourceRecords[9].kind == ProvenanceKind.omission);
        char[14] original;
        size_t written;
        assert(tryCopyOriginal(plan, original[], written).succeeded && original[0 .. written] == "aaaa bbbb cccc");
        options.width = CellWidth.bounded(30);
        const widePlan = cellWrapPlan("Name    Role", options);
        assert(render(widePlan) == "Name    Role");
    }
    @("text.wrap.nativeStyleAndTabMappingAffinities") unittest
    {
        WrapOptions options = WrapOptions(width: CellWidth.unbounded, tabs: TabPolicy.expand);
        const styled = cellWrapPlan("\x1b[31m\u8868\x1b[0m", options);
        assert(cellToSource(styled, 0, 1, WrapAffinity.before).sourceBoundary == 5);
        assert(cellToSource(styled, 0, 1, WrapAffinity.after).sourceBoundary == 8);
        const tabs = cellWrapPlan("x \tb", options);
        assert(cellToSource(tabs, 0, 3, WrapAffinity.before).sourceBoundary == 2);
        assert(cellToSource(tabs, 0, 3, WrapAffinity.after).sourceBoundary == 3);
    }
    @("text.wrap.emissionChunksUseOwnedBreakSegmentsWithoutReselection") unittest
    {
        import std.array : array;
        auto chunks = byWrappedChunk!false("alpha beta\nbody", WrapOptions(width: CellWidth.unbounded)).array;
        assert(chunks == ["alpha ", "beta", "\n", "body"]);
    }
    /// The real styler, wrapped line snapshots, and re-parsed emitted output must
    /// agree on underline shape rather than reducing every shape to "enabled".
    void runOwnedUnderlineWrappingSmoke()
    {
        import std.array : appender;
        import std.range.primitives : put;
        import sparkles.base.term_style : TermStyle, UnderlineStyle, writeStyle;
        import sparkles.base.term_color : ColorDepth;
        foreach (shape; [UnderlineStyle.none, UnderlineStyle.single, UnderlineStyle.double_,
            UnderlineStyle.curly, UnderlineStyle.dotted, UnderlineStyle.dashed])
        {
            auto styled = appender!string;
            writeStyle(styled, TermStyle(underline: shape), ColorDepth.trueColor);
            put(styled, "abcd");
            const source = styled[];
            foreach (continuity; [StyleContinuity.suspendResume, StyleContinuity.copyThrough])
            {
                const plan = cellWrapPlan(source, WrapOptions(width: CellWidth.bounded(2), continuity: continuity));
                assert(plan.lines.length == 2);
                foreach (ref const fragment; plan.fragments)
                    if (!fragment.formatting && fragment.provenance == ProvenanceKind.original && fragment.bytes.length)
                        assert(plan.styles[fragment.styleBefore].underline == cast(CellUnderlineStyle) shape);
                // Re-parse the actual rendered suspend/resume stream, not just
                // its retained metadata. Every body scalar must retain the shape.
                const reparsed = cellWrapPlan(render(plan));
                foreach (ref const fragment; reparsed.fragments)
                    if (!fragment.formatting && fragment.bytes.length && fragment.provenance == ProvenanceKind.original)
                        assert(reparsed.styles[fragment.styleBefore].underline == cast(CellUnderlineStyle) shape);
                char[] copied = new char[](source.length);
                size_t written;
                assert(tryCopyOriginal(plan, copied, written).succeeded && copied[0 .. written] == source);
            }
        }
        const transitions = cellWrapPlan("\x1b[21ma\x1b[24mb\x1b[4:3mc\x1b[0md\x1b[4:0me");
        foreach (ref const fragment; transitions.fragments)
            if (!fragment.formatting && fragment.bytes.length)
            {
                const expected = fragment.bytes == "a" ? CellUnderlineStyle.doubleLine
                    : fragment.bytes == "c" ? CellUnderlineStyle.curly : CellUnderlineStyle.none;
                assert(transitions.styles[fragment.styleBefore].underline == expected);
            }
    }
    @("text.wrap.ownedStylerUnderlineVariantsSurviveLineContinuity") unittest
        { runOwnedUnderlineWrappingSmoke(); }

    /// Primary-font selection keeps supported attributes; reset plus primary
    /// font clears them. Both states survive actual wrapped emission.
    @("text.wrap.primaryFontSelectionSurvivesLineContinuity")
    @system unittest
    {
        const source = "\x1b[1;31ma\x1b[10mbc\x1b[0;10md";
        foreach (continuity; [StyleContinuity.suspendResume, StyleContinuity.copyThrough])
        {
            const plan = cellWrapPlan(source, WrapOptions(width: CellWidth.bounded(1), continuity: continuity));
            assert(plan.lines.length == 4);
            const reparsed = cellWrapPlan(render(plan));
            string observed;
            foreach (ref const fragment; reparsed.fragments)
            {
                if (fragment.formatting || fragment.kind != FragmentKind.bytes || !fragment.bytes.length) continue;
                const style = reparsed.styles[fragment.styleBefore];
                if (fragment.bytes == "a" || fragment.bytes == "b" || fragment.bytes == "c")
                    assert(style.attributes == 1 && style.foreground == "31");
                else if (fragment.bytes == "d")
                    assert(style.attributes == 0 && !style.foreground.length);
                if (fragment.bytes == "a" || fragment.bytes == "b" || fragment.bytes == "c" || fragment.bytes == "d")
                    observed ~= fragment.bytes;
            }
            assert(observed == "abcd");
            char[source.length] original;
            size_t written;
            assert(tryCopyOriginal(plan, original[], written).succeeded);
            assert(original[0 .. written] == source);
        }
    }

    /// Accepting the primary font does not claim alternate-font restoration.
    @("text.wrap.alternateFontSelectionRemainsUnsupported")
    @system unittest
    {
        auto scratch = cellScratch();
        auto storage = planStorage();
        WrapPlan plan;
        const result = tryWrapCells(SourceSnapshot("a\x1b[11mb"), WrapOptions.init,
            grants(), scratch, storage, plan);
        assert(result.status == WrapStatus.unsupportedCapability && result.phase == WrapPhase.scan);
        assert(result.sourceStart == 1 && result.sourceEnd == 6);
    }

    @("text.wrap.greedyDoesNotPruneArbitraryTargetMeasurement") unittest
    {
        WrapOptions options = WrapOptions(width: CellWidth.bounded(2));
        options.selectionMeasure = (scope const(WrapFragment)[] fragments,
            scope const(CellStyleSnapshot)[] styles, ref long extent) @safe nothrow @nogc
        {
            size_t bytes;
            foreach (ref const fragment; fragments)
                if (!fragment.formatting) bytes += fragment.bytes.length;
            // A complete target ligature fits after intermediate prefixes did
            // not. Target measurements need not be monotone or additive.
            extent = bytes == 5 ? 1 : cast(long) bytes;
            return WrapResult.init;
        };
        const plan = cellWrapPlan("a b c", options);
        assert(plan.lines.length == 1 && render(plan) == "a b c");
        assert(plan.lines[0].visibleAdvance == 5); // still terminal-cell units
    }

    @("text.wrap.greedyLongUnitFitsWithinCallerWorkBudget") unittest
    {
        import std.array : replicate;
        const source = replicate("x", 2048);
        auto limits = grants();
        limits.providerWork = 500_000;
        auto scratch = cellScratch(source.length + 2, source.length + 2);
        auto storage = planStorage(source.length + 2);
        WrapPlan plan;
        const result = tryWrapCells(SourceSnapshot(source), WrapOptions(width: CellWidth.bounded(80)),
            limits, scratch, storage, plan);
        assert(result.succeeded);
        foreach (ref const line; plan.lines) assert(line.visibleAdvance <= 80 && !line.overfull);
        char[] original = new char[](source.length);
        size_t written;
        assert(tryCopyOriginal(plan, original, written).succeeded && original[0 .. written] == source);
    }
}
version (OwnedWrapSmoke)
{
    void main()
    {
        import std.stdio : writeln;
        runOwnedWrappingSmoke();
        runOwnedWrappingRealizationSmoke();
        runOwnedUnderlineWrappingSmoke();
        writeln("owned wrap bounded plan/emission/source-map smoke passed");
    }
}
