# Build Systems: Research Method and Limits

This survey compares mechanisms that decide when build work is necessary and
how its results can be reused. It combines a theoretical model, implementation
inspection and small behavioral experiments. Those forms of evidence answer
different questions: a model explains a property, source inspection locates a
mechanism, and an experiment observes one configuration.

The corpus is a purposive survey, not a statistically representative sample of
build tools. It includes the foundations of the scheduler × rebuilder model,
engines with contrasting dependency and caching mechanisms, and Nix projects
that expose graph construction as build work. The [index] records its membership;
[comparison] draws bounded findings from it. The [behavioral evidence][behavior]
records executable observations separately. Application analysis belongs in
[Sparkles][sparkles], whose baseline can live outside this standalone research
checkout.

**Last reviewed:** November 4, 2026 (method and synthesis scope)

## Selection and coverage

The corpus follows the subjects and six analysis dimensions in the [index].
It emphasizes scheduling, incremental verification, dependency discovery,
storage, isolation and distribution. Workspace ergonomics belong to the sibling
[monorepo survey][monorepo]. This is not a comprehensive product selection guide,
a market-adoption survey, or a comparative throughput benchmark.

Coverage is uneven. Source availability and pinned checkouts make some engine
mechanisms inspectable; a paper or a documented integration is the only evidence
for others. Boba is an integration row, GN and Meson generate descriptions, and
Earthly delegates execution to BuildKit. Those rows enrich the mechanism map but
do not supply independent confirmations of an inherited implementation. The Nix
front ends likewise share a store and executor rather than represent nine
independent evaluations of them.

The inventory does not establish that omitted systems lack a capability. A
selection bias toward source-available engines and dynamic Nix experiments
limits claims about the field as a whole. The milestones are examples supported
by the cited pages, not an exhaustive history or a priority claim.

## Evidence labels

| Kind                   | What it supports                                                                        | What it does not establish                                                                   |
| ---------------------- | --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| Source statement       | An upstream paper, specification or manual states a property                            | That the implementation satisfies the statement in every configuration                       |
| Source inspection      | A named code path at a pinned revision implements a mechanism                           | That the path is enabled by default, complete across platforms, or exercised in a deployment |
| Executable observation | A recorded tool/configuration produces the asserted actions and artifacts for a fixture | Behavior on other revisions, platforms, workloads or untested histories                      |
| Model deduction        | A result follows from the stated abstract task and equality assumptions                 | Identical behavior in a product whose mechanisms only approximate the model                  |
| Catalog inference      | A cross-source argument explains a pattern or motivates a hypothesis                    | Upstream endorsement or a universal recommendation                                           |

A direct source citation owns the statement being attributed. A synthesis claim
links to the relevant deep-dive section, where primary citations and qualifiers
remain visible. A quotation about graph values must not silently become a claim
about arbitrary external processes. A theorem statement is distinguished from a
machine-checked proof and from a proof of the shipped implementation; see
[formal verification][formal].

## Meaning of review and freshness

The inherited `reviewed` label records the catalog plan's source/citation review
and documentation-build gate. It does not mean that every behavior was reproduced,
that every platform was inspected, or that a second reviewer proved each claim.
The status tables are coverage inventories rather than confidence scores.

A page's review date identifies when its named scope was examined. It does not
advance the pinned upstream revision, establish a capability's release date, or
refresh every source transitively linked from that page. The synthesis revisions
dated November 4, 2026 audit reasoning and internal consistency against the
existing corpus. The experiment page reports its own tool versions; those may
differ from the deep-dives' pinned source revisions.

Confidence follows the claim's evidence rather than the number of `reviewed`
rows. An inspected mechanism with an agreeing adversarial fixture supports a
narrow behavioral claim more strongly than a product-wide slogan. Unexplained
disagreement between source and observation remains an open question.

## Absence, counterexamples and measurements

“Not found” means not identified in the cited source paths at the pinned
revision. It is not a claim that no plugin, external service, private deployment
or later version supplies the capability. In particular, an absent overhead
measurement is neither zero overhead nor evidence that the mechanism is unused.

Each synthesis finding names its assumptions and counterexamples. Classifications
identify the layer: graph evaluation, action execution, action caching, or graph
generation. Optional behavior such as tup's output comparison and platform-specific
sandbox paths remains qualified when summarized.

Published performance numbers retain their original workload, platform,
configuration and baseline. Numbers with different denominators are not ranked
as if they came from one experiment. New measurements record tool version,
command, edit history, expected executions, observed executions and final
artifacts. Correctness checks compare against an independently specified result;
an intentionally stale incremental result is reported as a demonstrated limit,
not counted as a correct output merely because it matches a prediction.

## Sources

- The [catalog inventory][index] and the source lists in its deep-dives define
  the inspected corpus.
- The excluded working plan, `docs/research/build-systems/PLAN.md` §4, records
  the original `reviewed` status definition.
- [Writing Research Docs][research-guide] distinguishes source grounding from
  executable evidence; [Writing Specification Prose][prose-guide] supplies the
  opening and terminology principles used here. This survey makes no normative
  implementation contract.

<!-- References -->

[index]: ./index.md
[comparison]: ./comparison.md
[behavior]: ./behavioral-evidence.md
[sparkles]: ./sparkles.md
[monorepo]: ../monorepo-tooling/index.md
[formal]: ./formal-verification.md
[research-guide]: ../../guidelines/research-docs.md
[prose-guide]: ../../guidelines/spec-prose.md
