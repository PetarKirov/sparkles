/** Transactional typed collection composition and retained source projections. */
module sparkles.wired.config.resolution;

import core.exception : OutOfMemoryError;
import std.traits : FieldNameTuple, Unqual;
import std.typecons : Nullable;
import sparkles.base.text.property_path : childPath, keyPath, elementPath;
import sparkles.wired.config.core : Atomic, Submodule, ListOf, AttrsOf, Lines,
    NullOr, ConfigFieldPolicy, CheckPolicy, callCheck, ValidationResult, Arena,
    SourceRecord, SourceLocation, DefinitionRef, ContributionRef, contributionRef,
    generatedDefinitionRef, ConfigUsage, ConfigLimits, ConfigError, ConfigErrorKind,
    OptionStatus, DefinitionDisposition, ValidationFailureView, catchConfigAllocation;
import sparkles.wired.config.payload : ConfigPresence, fullPresence,
    measureFullGraph, captureGraph, clearGraph, GraphKeyRecord;
import sparkles.wired.config.metadata : ConfigBranchMetadata;
import sparkles.wired.walk : WireWalk;
import sparkles.wired.json.codec : Json, aaKeyText;

package enum ResolutionLocatorKind : ubyte { member, index, key }
package struct ResolutionLocator
{
    const(ResolutionLocator)* parent;
    ResolutionLocatorKind kind;
    string member;
    size_t index;
    string key;
}
package struct ResolutionInput(V)
{
    const(V)* value;
    const(ConfigPresence!V)* presence;
    const(ConfigBranchMetadata!V)* metadata;
    DefinitionRef parent;
    const(SourceRecord)* source;
    immutable(ubyte)[] localId;
    uint priority;
    int order;
    Nullable!SourceLocation location;
    bool builtin;
    bool eligible = true;
    const(ResolutionLocator)* locator;
}
package struct ResolutionProjectionHeader
{
    ResolutionProjectionHeader* next;
    ResolutionProjectionHeader* nextAtNode;
    TypeInfo nativeType;
    ContributionRef ref_;
    DefinitionRef parent;
    const(SourceRecord)* source;
    const(ResolutionLocator)* locator;
    Nullable!SourceLocation location;
    immutable(ubyte)[] localId;
    uint priority;
    int order;
    bool eligible;
    bool selected;
    bool builtin;
    DefinitionDisposition disposition;
    string activePath;
    string declaredPattern;
}
package struct ResolutionProjection(V)
{
    ResolutionProjectionHeader header;
    const(V)* value;
    const(ConfigPresence!V)* presence;
    const(ConfigBranchMetadata!V)* metadata;
}
package struct ResolutionHeader
{
    ResolutionHeader* next;
    ResolutionHeader* sibling;
    ResolutionHeader* parent;
    ResolutionHeader* children;
    ResolutionHeader* lastChild;
    ResolutionHeader* nextFailure;
    string path;
    string declaredPattern;
    string owningOption;
    bool declaredOption;
    TypeInfo nativeType;
    OptionStatus status;
    uint priority;
    bool normalized;
    bool hasCandidate;
    ulong candidateBytes;
    ulong candidateNodes;
    ResolutionProjectionHeader* projections;
    ResolutionProjectionHeader* lastProjection;
    string diagnosticCode;
    string diagnosticDetail;
    const(ResolutionHeader)*[] failedChildren;
    const(ContributionRef)[] branchDefinitions;
    const(ContributionRef)[] branchContributors;
    const(DefinitionRef)[] optionDefinitions;
    const(DefinitionRef)[] optionContributors;
    const(char)[][] failedChildPaths;
    ValidationFailureView* diagnostic;
}
package struct ResolutionNode(V)
{
    ResolutionHeader header;
    const(V)* effective;
    // Completed rejected candidates remain retained, but are never effective.
    const(V)* candidate;
}
package struct ResolutionText
{
    ResolutionText* next;
    string text;
}
package struct ResolutionGeneratedHeader
{
    ResolutionGeneratedHeader* next;
    TypeInfo nativeType;
    DefinitionRef ref_;
    string pattern;
    string path;
    string localId = "initializer";
    const(SourceRecord)* source;
    uint priority;
    int order;
}
package struct ResolutionGenerated(V)
{
    ResolutionGeneratedHeader header;
    V value;
    ConfigPresence!V presence;
    ConfigBranchMetadata!V metadata;
}
package struct ResolutionContext(A)
{
    Arena!A arena;
    ulong owner;
    const(SourceRecord)* builtinSource;
    uint builtinPriority;
    int builtinOrder;
    ConfigUsage usage;
    ConfigLimits limits;
    ResolutionText* texts;
    ResolutionText* patterns;
    ResolutionHeader* records;
    ResolutionHeader* lastRecord;
    ResolutionProjectionHeader* projections;
    ResolutionProjectionHeader* lastProjection;
    ResolutionGeneratedHeader* generated;
    ResolutionGeneratedHeader* lastGenerated;
    ResolutionHeader* failures;
    ulong projectionCount;
    ulong generatedCount;
}

private ConfigError allocation(string path) @safe pure nothrow @nogc
    => ConfigError(ConfigErrorKind.allocationFailed, path);
private ConfigError charge(ref ulong used, ulong added, ulong limit,
    string name, string path) @safe pure nothrow @nogc
{
    if (added > ulong.max - used)
        return ConfigError(ConfigErrorKind.arithmeticOverflow, path, name, used, added);
    if (used + added > limit)
        return ConfigError(ConfigErrorKind.limitExceeded, path, name, used, added);
    used += added;
    return ConfigError.init;
}
private bool failed(ConfigError error) @safe pure nothrow @nogc
    => error.kind != ConfigErrorKind.none;

/** Register text which the collecting owner has already charged and owns. */
package ConfigError seedResolutionText(A)(ref ResolutionContext!A context, string text)
{
    for (auto item = context.texts; item !is null; item = item.next)
        if (item.text == text) return ConfigError.init;
    auto item = context.arena.allocate!ResolutionText();
    if (item is null) return allocation(text);
    item.text = text;
    item.next = context.texts;
    context.texts = item;
    return ConfigError.init;
}
private ConfigError intern(A)(ref ResolutionContext!A context, string text,
    string path, out string retained)
{
    for (auto item = context.texts; item !is null; item = item.next)
        if (item.text == text) { retained = item.text; return ConfigError.init; }
    auto error = charge(context.usage.payloadBytes, text.length,
        context.limits.maxPayloadBytes, "maxPayloadBytes", path);
    if (failed(error)) return error;
    auto item = context.arena.allocate!ResolutionText();
    if (item is null || !context.arena.text(text, item.text)) return allocation(path);
    item.next = context.texts;
    context.texts = item;
    retained = item.text;
    return ConfigError.init;
}
private int compareBytes(scope const(ubyte)[] a, scope const(ubyte)[] b)
    @safe pure nothrow @nogc
{
    foreach (i; 0 .. (a.length < b.length ? a.length : b.length))
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    return a.length == b.length ? 0 : a.length < b.length ? -1 : 1;
}
private int compareInput(V)(ref const ResolutionInput!V a, ref const ResolutionInput!V b)
{
    if (a.priority != b.priority) return a.priority < b.priority ? -1 : 1;
    if (a.order != b.order) return a.order < b.order ? -1 : 1;
    auto comparison = compareBytes(a.source.id, b.source.id);
    return comparison ? comparison : compareBytes(a.localId, b.localId);
}
private bool selected(V, P)(ref const ResolutionInput!V input, uint priority)
    => input.eligible && (is(P == Submodule) || input.priority == priority);
private ResolutionInput!E derived(E, V)(ref const ResolutionInput!V parent,
    const(E)* value, const(ConfigPresence!E)* presence,
    const(ConfigBranchMetadata!E)* metadata, const(ResolutionLocator)* locator)
{
    ResolutionInput!E result;
    result.value = value;
    result.presence = presence;
    result.metadata = metadata;
    result.parent = parent.parent;
    result.source = parent.source;
    result.localId = parent.localId;
    result.priority = parent.priority;
    result.order = parent.order;
    result.location = parent.location;
    result.builtin = parent.builtin;
    result.eligible = parent.eligible;
    result.locator = locator;
    if (metadata !is null)
    {
        if (!metadata.priority.isNull) result.priority = metadata.priority.get;
        if (!metadata.order.isNull) result.order = metadata.order.get;
        if (!metadata.location.isNull) result.location = metadata.location;
    }
    return result;
}
private ConfigError locator(A)(ref ResolutionContext!A context,
    const(ResolutionLocator)* parent, ResolutionLocatorKind kind,
    string member, size_t index, string key, string path,
    out ResolutionLocator* result)
{
    result = context.arena.allocate!ResolutionLocator();
    if (result is null) return allocation(path);
    result.parent = parent;
    result.kind = kind;
    result.member = member;
    result.index = index;
    result.key = key;
    return ConfigError.init;
}
private V shallow(V)(ref const V value) => (() @trusted => *cast(V*) &value)();
private ResolutionNode!V* typedNode(V)(ResolutionHeader* header)
{
    assert(header.nativeType is typeid(V));
    return (() @trusted => cast(ResolutionNode!V*) header)();
}
private void attach(ResolutionHeader* parent, ResolutionHeader* child) @safe pure nothrow @nogc
{
    child.parent = parent;
    if (parent.lastChild is null) parent.children = child;
    else parent.lastChild.sibling = child;
    parent.lastChild = child;
    inheritOwner(child, parent.owningOption, parent.declaredPattern);
}
private void inheritOwner(ResolutionHeader* node, string owner, string pattern)
    @safe pure nothrow @nogc
{
    if (node.declaredOption) return;
    node.owningOption = owner;
    node.declaredPattern = pattern;
    for (auto projection = node.projections; projection !is null; projection = projection.nextAtNode)
        projection.declaredPattern = pattern;
    for (auto child = node.children; child !is null; child = child.sibling)
        inheritOwner(child, owner, pattern);
}
private ConfigError projection(V, A)(ref ResolutionContext!A context,
    ref const ResolutionInput!V input, string path, string pattern,
    bool active, bool chosen, ResolutionHeader* node,
    out ResolutionProjection!V* result)
{
    if (context.projectionCount == uint.max) return ConfigError(
        ConfigErrorKind.limitExceeded, path, "maxContributions", context.projectionCount, 1);
    if (chosen)
    {
        auto error = charge(context.usage.contributions, 1,
            context.limits.maxContributions, "maxContributions", path);
        if (failed(error)) return error;
    }
    result = context.arena.allocate!(ResolutionProjection!V)();
    if (result is null) return allocation(path);
    auto h = &result.header;
    h.nativeType = typeid(V);
    h.ref_ = contributionRef(context.owner, cast(uint) ++context.projectionCount);
    h.parent = input.parent;
    h.source = input.source;
    h.localId = input.localId;
    h.locator = input.locator;
    h.location = input.location;
    h.priority = input.priority;
    h.order = input.order;
    h.eligible = input.eligible;
    h.selected = chosen;
    h.builtin = input.builtin;
    h.activePath = active ? path : null;
    h.declaredPattern = projectionPattern(context, pattern);
    h.disposition = chosen ? DefinitionDisposition.contributing : DefinitionDisposition.overridden;
    result.value = input.value;
    result.presence = input.presence;
    result.metadata = input.metadata;
    if (context.lastProjection is null) context.projections = h;
    else context.lastProjection.next = h;
    context.lastProjection = h;
    if (node !is null)
    {
        if (node.lastProjection is null) node.projections = h;
        else node.lastProjection.nextAtNode = h;
        node.lastProjection = h;
    }
    return ConfigError.init;
}
private void disposition(ResolutionHeader* node, DefinitionDisposition value)
    @safe pure nothrow @nogc
{
    for (auto p = node.projections; p !is null; p = p.nextAtNode)
        if (p.selected) p.disposition = value;
}
private void semanticFailure(A)(ref ResolutionContext!A context, ResolutionHeader* node)
{
    // Insert by canonical unsigned byte order, independent of declaration order.
    auto cursor = &context.failures;
    while (*cursor !is null && (*cursor).path < node.path)
        cursor = &(*cursor).nextFailure;
    node.nextFailure = *cursor;
    *cursor = node;
}
private ConfigError retainDiagnostic(A)(ref ResolutionContext!A context,
    ResolutionHeader* node, ValidationResult validation)
{
    auto error = charge(context.usage.payloadBytes, validation.code.length,
        context.limits.maxPayloadBytes, "maxPayloadBytes", node.path);
    if (failed(error)) return error;
    error = charge(context.usage.payloadBytes, validation.detail.length,
        context.limits.maxPayloadBytes, "maxPayloadBytes", node.path);
    if (failed(error)) return error;
    if (!context.arena.text(validation.code, node.diagnosticCode)
        || !context.arena.text(validation.detail, node.diagnosticDetail)) return allocation(node.path);
    return ConfigError.init;
}
private ConfigError candidate(V, A)(ref ResolutionContext!A context,
    ResolutionNode!V* node, V* value, bool normalized)
{
    node.candidate = value;
    node.effective = value;
    node.header.hasCandidate = true;
    node.header.normalized = normalized;
    if (normalized && !node.header.candidateNodes && !measureFullGraph!V(*value,
        node.header.candidateBytes, node.header.candidateNodes))
        return ConfigError(ConfigErrorKind.arithmeticOverflow, node.header.path, "maxPayloadBytes");
    return ConfigError.init;
}
private ConfigError childFailures(A)(ref ResolutionContext!A context, ResolutionHeader* node)
{
    size_t count;
    for (auto child = node.children; child !is null; child = child.sibling)
        if (child.status != OptionStatus.resolved) ++count;
    if (!count) return ConfigError.init;
    auto values = context.arena.array!(const(ResolutionHeader)*)(count);
    if (values.ptr is null) return allocation(node.path);
    size_t i;
    for (auto child = node.children; child !is null; child = child.sibling)
        if (child.status != OptionStatus.resolved) values[i++] = child;
    node.failedChildren = values;
    node.status = OptionStatus.unresolvedChildren;
    return ConfigError.init;
}

/** Charge normalized graphs only at their maximal retained candidate roots. */
package ConfigError finishResolution(A)(ref ResolutionContext!A context, ResolutionHeader* root)
{
    if (root.hasCandidate && root.normalized)
    {
        auto error = charge(context.usage.payloadBytes, root.candidateBytes,
            context.limits.maxPayloadBytes, "maxPayloadBytes", root.path);
        if (failed(error)) return error;
        return charge(context.usage.valueNodes, root.candidateNodes,
            context.limits.maxValueNodes, "maxValueNodes", root.path);
    }
    for (auto child = root.children; child !is null; child = child.sibling)
    {
        auto error = finishResolution(context, child);
        if (failed(error)) return error;
    }
    return ConfigError.init;
}

/** Materialize read-only visitor projections once, inside the resolve transaction. */
package ConfigError finishInspection(A)(ref ResolutionContext!A context)
{
    for (auto h = context.records; h !is null; h = h.next)
    {
        size_t count, selectedCount;
        for (auto p = h.projections; p !is null; p = p.nextAtNode)
        {
            ++count;
            if (p.selected) ++selectedCount;
        }
        auto definitions = context.arena.array!ContributionRef(count);
        auto contributors = context.arena.array!ContributionRef(selectedCount);
        auto parents = context.arena.array!DefinitionRef(count);
        auto selectedParents = context.arena.array!DefinitionRef(selectedCount);
        auto failures = context.arena.array!(const(char)[])(h.failedChildren.length);
        if ((count && (definitions.ptr is null || parents.ptr is null))
            || (selectedCount && (contributors.ptr is null || selectedParents.ptr is null))
            || (h.failedChildren.length && failures.ptr is null)) return allocation(h.path);
        size_t i, chosen;
        for (auto p = h.projections; p !is null; p = p.nextAtNode)
        {
            definitions[i] = p.ref_;
            parents[i++] = p.parent;
            if (p.selected)
            {
                contributors[chosen] = p.ref_;
                selectedParents[chosen++] = p.parent;
            }
        }
        foreach (j, child; h.failedChildren) failures[j] = child.path;
        h.branchDefinitions = definitions;
        h.branchContributors = contributors;
        h.optionDefinitions = parents;
        h.optionContributors = selectedParents;
        h.failedChildPaths = failures;
        if (h.diagnosticCode.length)
        {
            h.diagnostic = context.arena.allocate!ValidationFailureView();
            if (h.diagnostic is null) return allocation(h.path);
            h.diagnostic.path = h.path;
            h.diagnostic.priority = h.priority;
            h.diagnostic.code = h.diagnosticCode;
            h.diagnostic.detail = h.diagnosticDetail;
            for (auto p = h.projections; p !is null; p = p.nextAtNode)
                if (p.selected)
                {
                    h.diagnostic.definition = p.parent;
                    h.diagnostic.source = p.source.ref_;
                    h.diagnostic.location = p.location;
                    break;
                }
        }
    }
    for (auto h = context.records; h !is null; h = h.next)
        if (h.parent is null)
        {
            auto error = finishSectionInspection(context, h);
            if (failed(error)) return error;
        }
    return ConfigError.init;
}

private ConfigError finishSectionInspection(A)(ref ResolutionContext!A context,
    ResolutionHeader* h)
{
    for (auto child = h.children; child !is null; child = child.sibling)
    {
        auto error = finishSectionInspection(context, child);
        if (failed(error)) return error;
    }
    if (h.projections !is null || h.children is null) return ConfigError.init;
    size_t count, selectedCount;
    for (auto child = h.children; child !is null; child = child.sibling)
    {
        if (size_t.max - count < child.branchDefinitions.length
            || size_t.max - selectedCount < child.branchContributors.length)
            return ConfigError(ConfigErrorKind.arithmeticOverflow, h.path);
        count += child.branchDefinitions.length;
        selectedCount += child.branchContributors.length;
    }
    auto error = charge(context.usage.contributions, selectedCount,
        context.limits.maxContributions, "maxContributions", h.path);
    if (failed(error)) return error;
    auto definitions = context.arena.array!ContributionRef(count);
    auto contributors = context.arena.array!ContributionRef(selectedCount);
    auto parents = context.arena.array!DefinitionRef(count);
    auto selectedParents = context.arena.array!DefinitionRef(selectedCount);
    if ((count && (definitions.ptr is null || parents.ptr is null))
        || (selectedCount && (contributors.ptr is null || selectedParents.ptr is null)))
        return allocation(h.path);
    size_t at, chosen;
    for (auto child = h.children; child !is null; child = child.sibling)
    {
        definitions[at .. at + child.branchDefinitions.length] = child.branchDefinitions[];
        parents[at .. at + child.optionDefinitions.length] = child.optionDefinitions[];
        at += child.branchDefinitions.length;
        contributors[chosen .. chosen + child.branchContributors.length] = child.branchContributors[];
        selectedParents[chosen .. chosen + child.optionContributors.length] = child.optionContributors[];
        chosen += child.branchContributors.length;
    }
    h.branchDefinitions = definitions;
    h.branchContributors = contributors;
    h.optionDefinitions = parents;
    h.optionContributors = selectedParents;
    if (h.diagnostic !is null && selectedCount)
        for (auto p = context.projections; p !is null; p = p.next)
            if (p.ref_ == contributors[0])
            {
                h.diagnostic.definition = p.parent;
                h.diagnostic.source = p.source.ref_;
                h.diagnostic.location = p.location;
                break;
            }
    return ConfigError.init;
}

/** Direct sections compose their already resolved child options, retaining C1 defaults. */
package ConfigError resolveSectionCandidate(V, alias Check = void, A)(
    ref ResolutionContext!A context, V* value,
    ResolutionHeader*[] children, string path, out ResolutionNode!V* result)
{
    auto error = charge(context.usage.resolvedRecords, 1,
        context.limits.maxResolvedRecords, "maxResolvedRecords", path);
    if (failed(error)) return error;
    result = context.arena.allocate!(ResolutionNode!V)();
    if (result is null) return allocation(path);
    auto h = &result.header;
    h.nativeType = typeid(V);
    h.priority = uint.max;
    error = intern(context, path, path, h.path);
    if (failed(error)) return error;
    h.owningOption = h.path;
    foreach (child; children)
    {
        child.parent = h;
        if (h.lastChild is null) h.children = child;
        else h.lastChild.sibling = child;
        h.lastChild = child;
        if (child.priority < h.priority) h.priority = child.priority;
    }
    // Put the enclosing record before its first child in declaration traversal.
    auto before = &context.records;
    while (*before !is null && (children.length == 0 || *before !is children[0]))
        before = &(*before).next;
    h.next = *before;
    *before = h;
    if (h.next is null) context.lastRecord = h;
    error = childFailures(context, h);
    if (failed(error) || h.status == OptionStatus.unresolvedChildren) return error;
    error = candidate(context, result, value, true);
    if (failed(error)) return error;
    static if (!is(Check == void))
    {
        auto validation = callCheck!(Check, V)(*value);
        if (!validation.accepted)
        {
            assert(validation.code.length, "ConfigCheck rejection requires a stable nonempty code");
            error = retainDiagnostic(context, h, validation);
            if (failed(error)) return error;
            h.status = OptionStatus.invalidMergedValue;
            result.effective = null;
            semanticFailure(context, h);
        }
    }
    return ConfigError.init;
}

/** Resolve one original schema site. Inputs and collecting-owner records are read-only. */
package ConfigError resolveNode(V, P, Root, size_t site, alias Check = void, A)(
    ref ResolutionContext!A context, ResolutionInput!V[] inputs, string path,
    string declaredPattern, bool declaredOption, out ResolutionNode!V* result)
{
    return catchConfigAllocation(
        () => resolveTyped!(V, P, Root, site, Check)(context, inputs, path,
            declaredPattern, declaredOption, result), allocation(path));
}
private ConfigError resolveTyped(V, P, Root, size_t site, alias Check, A)(
    ref ResolutionContext!A context, ResolutionInput!V[] inputs, string path,
    string pattern, bool declaredOption, out ResolutionNode!V* result)
{
    auto error = charge(context.usage.resolvedRecords, 1,
        context.limits.maxResolvedRecords, "maxResolvedRecords", path);
    if (failed(error)) return error;
    result = context.arena.allocate!(ResolutionNode!V)();
    if (result is null) return allocation(path);
    auto h = &result.header;
    h.nativeType = typeid(V);
    h.declaredOption = declaredOption;
    error = intern(context, path, path, h.path);
    if (failed(error)) return error;
    // Data branches use their owning declared pattern after attachment. The
    // intermediate wildcard route is transient, not a retained schema option.
    if (declaredOption)
    {
        error = intern(context, pattern, path, h.declaredPattern);
        if (failed(error)) return error;
    }
    else h.declaredPattern = pattern;
    h.owningOption = h.path;
    if (context.lastRecord is null) context.records = h;
    else context.lastRecord.next = h;
    context.lastRecord = h;
    auto ordered = context.arena.array!(ResolutionInput!V)(inputs.length);
    if (inputs.length && ordered.ptr is null) return allocation(path);
    ordered[] = inputs[];
    // Insertion sort has no transient allocation and preserves identical tuples.
    foreach (i; 1 .. ordered.length)
    {
        auto value = ordered[i];
        auto j = i;
        while (j && compareInput(value, ordered[j - 1]) < 0)
        { ordered[j] = ordered[j - 1]; --j; }
        ordered[j] = value;
    }
    h.priority = uint.max;
    size_t count;
    foreach (ref input; ordered) if (input.eligible && input.priority < h.priority)
        h.priority = input.priority;
    foreach (ref input; ordered)
    {
        bool chosen = selected!(V, P)(input, h.priority);
        if (chosen) ++count;
        ResolutionProjection!V* retained;
        error = projection(context, input, h.path, h.declaredPattern, true, chosen, h, retained);
        if (failed(error)) return error;
    }
    if (!count)
        return ConfigError(ConfigErrorKind.invalidMetadata, path);
    error = compose!(V, P, Root, site)(context, ordered, result);
    if (failed(error)) return error;
    if (h.hasCandidate && !h.candidateNodes && !measureFullGraph!V(*result.candidate,
        h.candidateBytes, h.candidateNodes))
        return ConfigError(ConfigErrorKind.arithmeticOverflow, path, "maxPayloadBytes");
    if (h.status == OptionStatus.conflict) semanticFailure(context, h);
    static if (!is(Check == void))
    {
        if (h.status == OptionStatus.resolved && result.effective !is null)
        {
            auto validation = callCheck!(Check, V)(*result.effective);
            if (!validation.accepted)
            {
                error = retainDiagnostic(context, h, validation);
                if (failed(error)) return error;
                static if (is(P == Atomic)) h.status = OptionStatus.invalidSelectedValue;
                else h.status = OptionStatus.invalidMergedValue;
                result.effective = null;
                disposition(h, DefinitionDisposition.invalid);
                semanticFailure(context, h);
            }
        }
    }
    return ConfigError.init;
}

private ConfigError generatedDefault(V, P, Root, size_t site, A)(
    ref ResolutionContext!A context, ref const V initializer,
    string pattern, string path, out ResolutionInput!V input)
{
    ulong bytes, nodes;
    if (!measureFullGraph!V(initializer, bytes, nodes))
        return ConfigError(ConfigErrorKind.arithmeticOverflow, path, "maxPayloadBytes");
    auto error = charge(context.usage.definitions, 1,
        context.limits.maxDefinitions, "maxDefinitions", path);
    if (failed(error)) return error;
    error = charge(context.usage.payloadBytes, bytes,
        context.limits.maxPayloadBytes, "maxPayloadBytes", path);
    if (failed(error)) return error;
    error = charge(context.usage.valueNodes, nodes,
        context.limits.maxValueNodes, "maxValueNodes", path);
    if (failed(error)) return error;
    auto record = context.arena.allocate!(ResolutionGenerated!V)();
    if (record is null) return allocation(path);
    auto presence = fullPresence!V(initializer);
    GraphKeyRecord* keys;
    if (!captureGraph!(V, P, Root, site)(context.arena, initializer, presence,
        record.value, record.presence, keys)) return allocation(path);
    for (auto key = keys; key !is null; key = key.next)
    {
        error = retainOwnedText(context, key.spelling, path);
        if (failed(error)) return error;
    }
    auto h = &record.header;
    h.nativeType = typeid(V);
    h.ref_ = generatedDefinitionRef(context.owner, cast(uint) ++context.generatedCount);
    h.pattern = projectionPattern(context, pattern);
    h.path = path;
    h.source = context.builtinSource;
    h.priority = context.builtinPriority;
    h.order = context.builtinOrder;
    if (context.lastGenerated is null) context.generated = h;
    else context.lastGenerated.next = h;
    context.lastGenerated = h;
    input.value = &record.value;
    input.presence = &record.presence;
    input.metadata = &record.metadata;
    input.parent = h.ref_;
    input.source = h.source;
    input.localId = cast(immutable(ubyte)[]) "initializer";
    input.priority = h.priority;
    input.order = h.order;
    input.builtin = true;
    input.eligible = true;
    return ConfigError.init;
}

private template NestedPolicy(P)
{
    static if (is(P == NullOr!Q, Q) || is(P == ListOf!Q, Q) || is(P == AttrsOf!Q, Q))
        alias NestedPolicy = Q;
    else alias NestedPolicy = Atomic;
}
private template FieldPolicy(V, P, string name)
{
    static if (is(P == Submodule)) alias FieldPolicy = ConfigFieldPolicy!(V, name);
    else alias FieldPolicy = Atomic;
}

/** Keep excluded occurrences without inventing an effective collection position. */
private ConfigError projectOnly(V, P, Root, size_t site, A)(
    ref ResolutionContext!A context, ResolutionInput!V input, string pattern)
{
    input.eligible = false;
    ResolutionProjection!V* retained;
    auto error = projection(context, input, null, pattern, false, false, null, retained);
    if (failed(error)) return error;
    return projectOriginalChildren!(V, P, Root, site)(context, input, pattern);
}
private ConfigError projectOriginalChildren(V, P, Root, size_t site, A)(
    ref ResolutionContext!A context, ResolutionInput!V input, string pattern)
{
    alias walk = WireWalk!(Json, Root);
    static if (is(V == Nullable!N, N))
    {
        if (!input.value.isNull)
        {
            auto child = derived!N(input, &input.value.get(), &input.presence.child,
                input.metadata is null ? null : &input.metadata.child, input.locator);
            return projectOnly!(N, NestedPolicy!P, Root, walk.child!(site, 0))(
                context, child, pattern);
        }
    }
    else static if (!is(V == string) && (is(V == E[], E) || is(V == E[n], E, size_t n)))
    {
        foreach (i, ref item; *input.value)
        {
            ResolutionLocator* route;
            auto error = locator(context, input.locator, ResolutionLocatorKind.index,
                null, i, null, pattern, route);
            if (failed(error)) return error;
            auto child = derived!(Unqual!E)(input, &item, &input.presence.elements[i],
                input.metadata is null || !input.metadata.shaped
                    ? null : &input.metadata.elements[i], route);
            error = projectOnly!(Unqual!E, NestedPolicy!P, Root, walk.child!(site, 0))(
                context, child, pattern ~ "[<index>]");
            if (failed(error)) return error;
        }
    }
    else static if (is(V == E[K], E, K))
    {
        foreach (key, ref item; *input.value)
        {
            string spelling;
            auto error = intern(context,
                aaKeyText!(Unqual!K, Root, walk.child!(site, 0))(key), pattern, spelling);
            if (failed(error)) return error;
            ResolutionLocator* route;
            error = locator(context, input.locator, ResolutionLocatorKind.key,
                null, 0, spelling, pattern, route);
            if (failed(error)) return error;
            auto child = derived!(Unqual!E)(input, key in *input.value, key in input.presence.entries,
                input.metadata is null || !input.metadata.shaped
                    ? null : key in input.metadata.entries, route);
            error = projectOnly!(Unqual!E, NestedPolicy!P, Root, walk.child!(site, 1))(
                context, child, pattern ~ "[<key>]");
            if (failed(error)) return error;
        }
    }
    else static if (is(V == struct))
    {
        static foreach (ordinal, name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            if (__traits(getMember, input.presence.members, name).supplied)
            {
                ResolutionLocator* route;
                auto error = locator(context, input.locator, ResolutionLocatorKind.member,
                    name, 0, null, pattern, route);
                if (failed(error)) return error;
                auto child = derived!E(input, &__traits(getMember, *input.value, name),
                    &__traits(getMember, input.presence.members, name),
                    input.metadata is null ? null : &__traits(getMember, input.metadata.members, name),
                    route);
                error = projectOnly!(E, FieldPolicy!(V, P, name), Root, walk.child!(site, ordinal))(
                    context, child, childPath(pattern, name));
                if (failed(error)) return error;
            }
        }}
    }
    return ConfigError.init;
}

private ConfigError compose(V, P, Root, size_t site, A)(
    ref ResolutionContext!A context, ResolutionInput!V[] inputs, ResolutionNode!V* node)
{
    alias walk = WireWalk!(Json, Root);
    auto h = &node.header;
    size_t count;
    ResolutionInput!V first;
    foreach (ref input; inputs) if (selected!(V, P)(input, h.priority))
    {
        if (!count) first = input;
        ++count;
    }
    static if (is(P == Atomic))
    {
        if (count > 1)
        {
            h.status = OptionStatus.conflict;
            disposition(h, DefinitionDisposition.conflicting);
            foreach (input; inputs)
            {
                input.eligible = false;
                auto error = projectOriginalChildren!(V, P, Root, site)(
                    context, input, h.declaredPattern);
                if (failed(error)) return error;
            }
            return ConfigError.init;
        }
        node.effective = node.candidate = first.value;
        h.hasCandidate = true;
        foreach (input; inputs) if (!selected!(V, P)(input, h.priority))
        {
            input.eligible = false;
            auto error = projectOriginalChildren!(V, P, Root, site)(
                context, input, h.declaredPattern);
            if (failed(error)) return error;
        }
        return inspectAtomic!(V, Root, site)(context, first, h);
    }
    else static if (is(P == Lines))
    {
        disposition(h, DefinitionDisposition.contributing);
        if (count == 1)
        {
            node.effective = node.candidate = first.value;
            h.hasCandidate = true;
            return ConfigError.init;
        }
        ulong bytes = count - 1;
        foreach (ref input; inputs) if (selected!(V, P)(input, h.priority))
        {
            if (input.value.length > ulong.max - bytes)
                return ConfigError(ConfigErrorKind.arithmeticOverflow, h.path, "maxPayloadBytes");
            bytes += input.value.length;
        }
        if (bytes > size_t.max) return allocation(h.path);
        // Check analytically known candidate storage before any retained allocation.
        auto error = preflightCandidate(context, bytes, 1, h.path);
        if (failed(error)) return error;
        h.candidateBytes = bytes;
        h.candidateNodes = 1;
        auto storage = context.arena.nonNullArray!char(cast(size_t) bytes);
        if (storage.ptr is null) return allocation(h.path);
        size_t offset, index;
        foreach (ref input; inputs) if (selected!(V, P)(input, h.priority))
        {
            if (index++) storage[offset++] = '\n';
            storage[offset .. offset + input.value.length] = (*input.value)[];
            offset += input.value.length;
        }
        auto value = context.arena.allocate!V();
        if (value is null) return allocation(h.path);
        // Fresh arena storage is no longer mutated after publication.
        *value = (() @trusted { return cast(string) storage; })();
        return candidate(context, node, value, true);
    }
    else static if (is(P == NullOr!Q, Q))
    {
        disposition(h, DefinitionDisposition.contributing);
        bool anyNull;
        foreach (ref input; inputs) if (selected!(V, P)(input, h.priority))
            anyNull = anyNull || input.value.isNull;
        if (anyNull)
        {
            if (count > 1)
            {
                h.status = OptionStatus.conflict;
                disposition(h, DefinitionDisposition.conflicting);
            }
            else
            {
                node.effective = node.candidate = first.value;
                h.hasCandidate = true;
            }
            foreach (input; inputs)
            {
                input.eligible = false;
                auto error = projectOriginalChildren!(V, P, Root, site)(
                    context, input, h.declaredPattern);
                if (failed(error)) return error;
            }
            return ConfigError.init;
        }
        static if (is(V == Nullable!N, N))
        {
            size_t nonNull;
            foreach (ref input; inputs) if (!input.value.isNull) ++nonNull;
            auto children = context.arena.array!(ResolutionInput!N)(nonNull);
            if (nonNull && children.ptr is null) return allocation(h.path);
            size_t index;
            foreach (input; inputs) if (!input.value.isNull)
            {
                input.eligible = selected!(V, P)(input, h.priority);
                children[index++] = derived!N(input, &input.value.get(), &input.presence.child,
                    input.metadata is null ? null : &input.metadata.child, input.locator);
            }
            // The nullable layer is one resolved record, not another address hop.
            auto inner = context.arena.allocate!(ResolutionNode!N)();
            if (inner is null) return allocation(h.path);
            inner.header = *h;
            auto error = compose!(N, Q, Root, walk.child!(site, 0))(context, children, inner);
            if (failed(error)) return error;
            h.children = inner.header.children;
            h.lastChild = inner.header.lastChild;
            h.failedChildren = inner.header.failedChildren;
            h.status = inner.header.status;
            for (auto child = h.children; child !is null; child = child.sibling) child.parent = h;
            if (inner.effective is null) return ConfigError.init;
            if (count == 1 && !inner.header.normalized)
            {
                node.effective = node.candidate = first.value;
                h.hasCandidate = true;
                return ConfigError.init;
            }
            ulong bytes, nodes;
            if (!measureFullGraph!N(*inner.effective, bytes, nodes)
                || !addLogical(bytes, 1) || !addLogical(nodes, 1))
                return ConfigError(ConfigErrorKind.arithmeticOverflow, h.path, "maxPayloadBytes");
            error = preflightCandidate(context, bytes, nodes, h.path);
            if (failed(error)) return error;
            h.candidateBytes = bytes;
            h.candidateNodes = nodes;
            auto value = context.arena.allocate!V();
            if (value is null) return allocation(h.path);
            *value = shallow!N(*inner.effective);
            return candidate(context, node, value, true);
        }
    }
    else static if (is(P == ListOf!Q, Q))
    {
        static if (is(V == E[], E))
        {
            disposition(h, DefinitionDisposition.contributing);
            size_t length;
            foreach (ref input; inputs) if (selected!(V, P)(input, h.priority))
            {
                if (input.value.length > size_t.max - length)
                    return ConfigError(ConfigErrorKind.arithmeticOverflow, h.path, "maxValueNodes");
                length += input.value.length;
            }
            bool normalized = count > 1;
            size_t offset;
            foreach (input; inputs)
            {
                if (!selected!(V, P)(input, h.priority))
                {
                    input.eligible = false;
                    auto error = projectOriginalChildren!(V, P, Root, site)(
                        context, input, h.declaredPattern);
                    if (failed(error)) return error;
                    continue;
                }
                foreach (i, ref item; *input.value)
                {
                    string path;
                    auto error = intern(context, elementPath(h.path, offset), h.path, path);
                    if (failed(error)) return error;
                    ResolutionLocator* route;
                    error = locator(context, input.locator, ResolutionLocatorKind.index,
                        null, i, null, path, route);
                    if (failed(error)) return error;
                    auto childInput = derived!(Unqual!E)(input, &item, &input.presence.elements[i],
                        input.metadata is null || !input.metadata.shaped
                            ? null : &input.metadata.elements[i], route);
                    ResolutionInput!(Unqual!E)[1] one = [childInput];
                    ResolutionNode!(Unqual!E)* child;
                    error = resolveNode!(Unqual!E, Q, Root, walk.child!(site, 0))(
                        context, one[], path, h.declaredPattern ~ "[<index>]", false, child);
                    if (failed(error)) return error;
                    attach(h, &child.header);
                    normalized = normalized || child.header.normalized;
                    ++offset;
                }
            }
            auto error = childFailures(context, h);
            if (failed(error) || h.status == OptionStatus.unresolvedChildren) return error;
            if (!normalized)
            {
                node.effective = node.candidate = first.value;
                h.hasCandidate = true;
                return ConfigError.init;
            }
            ulong bytes = 1, nodes = 1;
            for (auto childHeader = h.children; childHeader !is null; childHeader = childHeader.sibling)
            {
                if (!addLogical(bytes, childHeader.candidateBytes)
                    || !addLogical(nodes, childHeader.candidateNodes))
                    return ConfigError(ConfigErrorKind.arithmeticOverflow, h.path, "maxPayloadBytes");
            }
            error = preflightCandidate(context, bytes, nodes, h.path);
            if (failed(error)) return error;
            h.candidateBytes = bytes;
            h.candidateNodes = nodes;
            auto value = context.arena.allocate!V();
            if (value is null) return allocation(h.path);
            *value = context.arena.nonNullArray!(Unqual!E)(length);
            if ((*value).ptr is null) return allocation(h.path);
            offset = 0;
            for (auto childHeader = h.children; childHeader !is null; childHeader = childHeader.sibling)
                (*value)[offset++] = shallow!(Unqual!E)(*typedNode!(Unqual!E)(childHeader).effective);
            return candidate(context, node, value, true);
        }
    }
    else static if (is(P == AttrsOf!Q, Q))
    {
        static if (is(V == E[K], E, K))
            return composeMap!(V, Q, Root, site)(context, inputs, node);
    }
    else static if (is(P == Submodule))
    {
        disposition(h, DefinitionDisposition.contributing);
        bool selectedBuiltin;
        foreach (ref input; inputs) if (input.eligible && input.builtin) selectedBuiltin = true;
        bool normalized = count > 1;
        static foreach (ordinal, name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            alias Q = ConfigFieldPolicy!(V, name);
            size_t supplied;
            foreach (ref input; inputs)
                if (__traits(getMember, input.presence.members, name).supplied) ++supplied;
            bool fallback = !selectedBuiltin;
            if (fallback) ++supplied;
            auto children = context.arena.array!(ResolutionInput!E)(supplied);
            if (supplied && children.ptr is null) return allocation(h.path);
            string path, pattern;
            auto error = intern(context, childPath(h.path, name), h.path, path);
            if (failed(error)) return error;
            static if (is(Q == Submodule))
                pattern = childPath(h.declaredPattern, name);
            else
            {
                error = intern(context, childPath(h.declaredPattern, name), h.path, pattern);
                if (failed(error)) return error;
            }
            size_t index;
            foreach (input; inputs)
            {
                if (!__traits(getMember, input.presence.members, name).supplied)
                {
                    if (input.eligible) normalized = true;
                    continue;
                }
                ResolutionLocator* route;
                error = locator(context, input.locator, ResolutionLocatorKind.member,
                    name, 0, null, path, route);
                if (failed(error)) return error;
                children[index++] = derived!E(input, &__traits(getMember, *input.value, name),
                    &__traits(getMember, input.presence.members, name),
                    input.metadata is null ? null : &__traits(getMember, input.metadata.members, name),
                    route);
            }
            if (fallback)
            {
                V initializer;
                error = generatedDefault!(E, Q, Root, walk.child!(site, ordinal))(
                    context, __traits(getMember, initializer, name), pattern, path, children[index++]);
                if (failed(error)) return error;
            }
            ResolutionNode!E* child;
            error = resolveNode!(E, Q, Root, walk.child!(site, ordinal), CheckPolicy!(V, name))(
                context, children, path, pattern, !is(Q == Submodule), child);
            if (failed(error)) return error;
            attach(h, &child.header);
            normalized = normalized || child.header.normalized
                || child.effective !is &__traits(getMember, *first.value, name);
        }}
        auto error = childFailures(context, h);
        if (failed(error) || h.status == OptionStatus.unresolvedChildren) return error;
        if (!normalized)
        {
            node.effective = node.candidate = first.value;
            h.hasCandidate = true;
            return ConfigError.init;
        }
        ulong bytes, nodes = 1;
        for (auto childHeader = h.children; childHeader !is null; childHeader = childHeader.sibling)
        {
            if (!addLogical(bytes, childHeader.candidateBytes)
                || !addLogical(nodes, childHeader.candidateNodes))
                return ConfigError(ConfigErrorKind.arithmeticOverflow, h.path, "maxPayloadBytes");
        }
        error = preflightCandidate(context, bytes, nodes, h.path);
        if (failed(error)) return error;
        h.candidateBytes = bytes;
        h.candidateNodes = nodes;
        auto value = context.arena.allocate!V();
        if (value is null) return allocation(h.path);
        clearGraph!V(*value);
        auto childHeader = h.children;
        static foreach (name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            __traits(getMember, *value, name) = shallow!E(*typedNode!E(childHeader).effective);
            childHeader = childHeader.sibling;
        }}
        return candidate(context, node, value, true);
    }
    else static assert(false, "Unsupported configuration composition policy " ~ P.stringof);
}

private struct ResolutionMapKey(K)
{
    K key;
    string spelling;
}
private ConfigError composeMap(V, Q, Root, size_t site, A)(
    ref ResolutionContext!A context, ResolutionInput!V[] inputs,
    ResolutionNode!V* node)
{
    static if (is(V == E[K], E, K))
    {
        alias walk = WireWalk!(Json, Root);
        auto h = &node.header;
        size_t capacity, selectedCount;
        foreach (ref input; inputs)
        {
            if (input.value.length > size_t.max - capacity)
                return ConfigError(ConfigErrorKind.arithmeticOverflow, h.path, "maxValueNodes");
            capacity += input.value.length;
            if (input.eligible && input.priority == h.priority) ++selectedCount;
        }
        auto keys = context.arena.array!(ResolutionMapKey!(Unqual!K))(capacity);
        if (capacity && keys.ptr is null) return allocation(h.path);
        size_t count;
        foreach (ref input; inputs) if (input.eligible && input.priority == h.priority)
            foreach (key, ref item; *input.value)
            {
                bool found;
                foreach (ref known; keys[0 .. count]) if (known.key == key) { found = true; break; }
                if (found) continue;
                keys[count].key = shallow!(Unqual!K)(key);
                auto error = intern(context,
                    aaKeyText!(Unqual!K, Root, walk.child!(site, 0))(key), h.path, keys[count].spelling);
                if (failed(error)) return error;
                ++count;
            }
        foreach (i; 1 .. count)
        {
            auto key = keys[i];
            auto j = i;
            while (j && key.spelling < keys[j - 1].spelling)
            { keys[j] = keys[j - 1]; --j; }
            keys[j] = key;
        }
        bool normalized = selectedCount > 1;
        foreach (ref key; keys[0 .. count])
        {
            auto children = context.arena.array!(ResolutionInput!(Unqual!E))(inputs.length);
            if (inputs.length && children.ptr is null) return allocation(h.path);
            size_t childCount;
            string path;
            auto error = intern(context, keyPath(h.path, key.spelling), h.path, path);
            if (failed(error)) return error;
            foreach (input; inputs)
            {
                auto item = key.key in *input.value;
                if (item is null) continue;
                input.eligible = input.eligible && input.priority == h.priority;
                ResolutionLocator* route;
                error = locator(context, input.locator, ResolutionLocatorKind.key,
                    null, 0, key.spelling, path, route);
                if (failed(error)) return error;
                children[childCount++] = derived!(Unqual!E)(input, item,
                    key.key in input.presence.entries,
                    input.metadata is null || !input.metadata.shaped
                        ? null : key.key in input.metadata.entries, route);
            }
            ResolutionNode!(Unqual!E)* child;
            error = resolveNode!(Unqual!E, Q, Root, walk.child!(site, 1))(
                context, children[0 .. childCount], path, h.declaredPattern ~ "[<key>]", false, child);
            if (failed(error)) return error;
            attach(h, &child.header);
            normalized = normalized || child.header.normalized;
        }
        // Losing-only keys have original projections, but no active address.
        foreach (input; inputs) if (!input.eligible || input.priority != h.priority)
            foreach (key, ref item; *input.value)
            {
                bool found;
                foreach (ref known; keys[0 .. count]) if (known.key == key) { found = true; break; }
                if (found) continue;
                string spelling;
                auto error = intern(context,
                    aaKeyText!(Unqual!K, Root, walk.child!(site, 0))(key), h.path, spelling);
                if (failed(error)) return error;
                ResolutionLocator* route;
                error = locator(context, input.locator, ResolutionLocatorKind.key,
                    null, 0, spelling, h.path, route);
                if (failed(error)) return error;
                input.eligible = false;
                auto child = derived!(Unqual!E)(input, key in *input.value, key in input.presence.entries,
                    input.metadata is null || !input.metadata.shaped
                        ? null : key in input.metadata.entries, route);
                error = projectOnly!(Unqual!E, Q, Root, walk.child!(site, 1))(
                    context, child, h.declaredPattern ~ "[<key>]");
                if (failed(error)) return error;
            }
        auto error = childFailures(context, h);
        if (failed(error) || h.status == OptionStatus.unresolvedChildren) return error;
        if (!normalized)
        {
            foreach (ref input; inputs) if (input.eligible && input.priority == h.priority)
            {
                node.effective = node.candidate = input.value;
                h.hasCandidate = true;
                return ConfigError.init;
            }
        }
        ulong bytes = 1, nodes = 1;
        auto measuredChild = h.children;
        foreach (ref key; keys[0 .. count])
        {
            static if (is(K == string)) ulong keyBytes = key.key.length;
            else ulong keyBytes = K.sizeof;
            if (!addLogical(bytes, keyBytes) || !addLogical(bytes, measuredChild.candidateBytes)
                || !addLogical(nodes, 1) || !addLogical(nodes, measuredChild.candidateNodes))
                return ConfigError(ConfigErrorKind.arithmeticOverflow, h.path, "maxPayloadBytes");
            measuredChild = measuredChild.sibling;
        }
        error = preflightCandidate(context, bytes, nodes, h.path);
        if (failed(error)) return error;
        h.candidateBytes = bytes;
        h.candidateNodes = nodes;
        // This descriptor roots the actual native AA through the allocator seam.
        auto value = context.arena.allocate!V();
        if (value is null) return allocation(h.path);
        clearGraph!V(*value);
        auto childHeader = h.children;
        foreach (ref key; keys[0 .. count])
        {
            (*value)[key.key] = shallow!(Unqual!E)(*typedNode!(Unqual!E)(childHeader).effective);
            childHeader = childHeader.sibling;
        }
        if (!count)
        {
            Unqual!E empty;
            clearGraph!(Unqual!E)(empty);
            (*value)[K.init] = empty;
            (*value).remove(K.init);
        }
        return candidate(context, node, value, true);
    }
}

/** Structural atomic inspection never interprets nested option/check attributes. */
private ConfigError inspectAtomic(V, Root, size_t site, A)(
    ref ResolutionContext!A context, ResolutionInput!V input, ResolutionHeader* h)
{
    alias walk = WireWalk!(Json, Root);
    static if (is(V == Nullable!N, N))
    {
        if (input.value.isNull) return ConfigError.init;
        auto child = derived!N(input, &input.value.get(), &input.presence.child,
            input.metadata is null ? null : &input.metadata.child, input.locator);
        return inspectAtomic!(N, Root, walk.child!(site, 0))(context, child, h);
    }
    else static if (!is(V == string) && (is(V == E[], E) || is(V == E[n], E, size_t n)))
    {
        foreach (i, ref item; *input.value)
        {
            string path;
            auto error = intern(context, elementPath(h.path, i), h.path, path);
            if (failed(error)) return error;
            ResolutionLocator* route;
            error = locator(context, input.locator, ResolutionLocatorKind.index,
                null, i, null, path, route);
            if (failed(error)) return error;
            auto childInput = derived!(Unqual!E)(input, &item, &input.presence.elements[i],
                input.metadata is null || !input.metadata.shaped
                    ? null : &input.metadata.elements[i], route);
            ResolutionInput!(Unqual!E)[1] one = [childInput];
            ResolutionNode!(Unqual!E)* child;
            error = resolveNode!(Unqual!E, Atomic, Root, walk.child!(site, 0))(
                context, one[], path, h.declaredPattern ~ "[<index>]", false, child);
            if (failed(error)) return error;
            attach(h, &child.header);
        }
    }
    else static if (is(V == E[K], E, K))
    {
        ResolutionInput!V[1] one = [input];
        auto inspected = context.arena.allocate!(ResolutionNode!V)();
        if (inspected is null) return allocation(h.path);
        inspected.header = *h;
        auto error = composeMap!(V, Atomic, Root, site)(context, one[], inspected);
        if (failed(error)) return error;
        h.children = inspected.header.children;
        h.lastChild = inspected.header.lastChild;
        for (auto child = h.children; child !is null; child = child.sibling) child.parent = h;
    }
    else static if (is(V == struct))
    {
        static foreach (ordinal, name; FieldNameTuple!V)
        {{
            alias E = Unqual!(typeof(__traits(getMember, V.init, name)));
            string path;
            auto error = intern(context, childPath(h.path, name), h.path, path);
            if (failed(error)) return error;
            ResolutionLocator* route;
            error = locator(context, input.locator, ResolutionLocatorKind.member,
                name, 0, null, path, route);
            if (failed(error)) return error;
            auto childInput = derived!E(input, &__traits(getMember, *input.value, name),
                &__traits(getMember, input.presence.members, name),
                input.metadata is null ? null : &__traits(getMember, input.metadata.members, name), route);
            ResolutionInput!E[1] one = [childInput];
            ResolutionNode!E* child;
            error = resolveNode!(E, Atomic, Root, walk.child!(site, ordinal))(
                context, one[], path, childPath(h.declaredPattern, name), false, child);
            if (failed(error)) return error;
            attach(h, &child.header);
        }}
    }
    return ConfigError.init;
}

private bool addLogical(ref ulong total, ulong value) @safe pure nothrow @nogc
{
    if (value > ulong.max - total) return false;
    total += value;
    return true;
}
private ConfigError preflightCandidate(A)(ref ResolutionContext!A context,
    ulong bytes, ulong nodes, string path)
{
    auto usedBytes = context.usage.payloadBytes;
    auto error = charge(usedBytes, bytes, context.limits.maxPayloadBytes, "maxPayloadBytes", path);
    if (failed(error)) return error;
    auto usedNodes = context.usage.valueNodes;
    return charge(usedNodes, nodes, context.limits.maxValueNodes, "maxValueNodes", path);
}

/** Encode only the original relative route; never substitute effective indices. */
package string originalLocatorText(scope const(ResolutionLocator)* route) @safe
{
    if (route is null) return null;
    auto parent = originalLocatorText(route.parent);
    final switch (route.kind)
    {
        case ResolutionLocatorKind.member: return childPath(parent, route.member);
        case ResolutionLocatorKind.index: return elementPath(parent, route.index);
        case ResolutionLocatorKind.key: return keyPath(parent, route.key);
    }
}

private ConfigError retainOwnedText(A)(ref ResolutionContext!A context, string text, string path)
{
    for (auto item = context.texts; item !is null; item = item.next)
        if (item.text == text) return ConfigError.init;
    auto error = charge(context.usage.payloadBytes, text.length,
        context.limits.maxPayloadBytes, "maxPayloadBytes", path);
    if (failed(error)) return error;
    return seedResolutionText(context, text);
}

private string projectionPattern(A)(ref ResolutionContext!A context, string route)
{
    string result;
    for (auto item = context.patterns; item !is null; item = item.next)
    {
        auto pattern = item.text;
        if (pattern == route) return pattern;
        if (pattern.length <= result.length || pattern.length >= route.length) continue;
        if (route[0 .. pattern.length] == pattern
            && (route[pattern.length] == '[' || route[pattern.length] == '.'))
            result = pattern;
    }
    return result;
}

/** Register the declared role independently from shared canonical text bytes. */
package ConfigError seedResolutionPattern(A)(ref ResolutionContext!A context, string pattern)
{
    auto error = seedResolutionText(context, pattern);
    if (failed(error)) return error;
    for (auto item = context.patterns; item !is null; item = item.next)
        if (item.text == pattern) return ConfigError.init;
    auto item = context.arena.allocate!ResolutionText();
    if (item is null) return allocation(pattern);
    item.text = pattern;
    item.next = context.patterns;
    context.patterns = item;
    return ConfigError.init;
}
