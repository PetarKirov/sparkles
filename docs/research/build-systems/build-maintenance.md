# Build Technology and Build Maintenance (Empirical Study)

The catalog's one page about the _human_ cost of a build specification rather than
the engine's cost of computing it: 177,039 repositories mined to ask whether the
technology a build is written in predicts how much of it must be rewritten. Engines
elsewhere in this tree are compared on minimality, cutoff and cache hits; this study
compares specifications on churn, source coupling, and who has to write them.

**Last reviewed:** November 2, 2026

> [!NOTE]
> Every citation below is to the **author preprint** on disk, not the published
> article: `$REPOS/papers/build-systems/mcintosh-2015-large-scale-empirical-study-build-technology-build-maintenance-emse-preprint.pdf`
> (SHA256 `421a947fe7d5333710b8f1fe44aa0a4c053dc01c110773688241717743f87291`,
> 48 pp., produced 2014-07-31). The published version — _Empirical Software
> Engineering_ 20(6):1587–1633, [DOI `10.1007/s10664-014-9324-x`][doi] — is
> subscription access. Section, table and figure numbers are the preprint's;
> **page numbers are deliberately not quoted**, since pagination may differ.

| Field        | Value                                                                                                                                                         |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Authors      | Shane McIntosh, Meiyappan Nagappan, Ahmed E. Hassan (SAIL, Queen's University); Bram Adams (MCIS, Polytechnique Montréal); Audris Mockus (Tennessee / Avaya)  |
| Venue        | _Empirical Software Engineering_ 20(6):1587–1633, 2015 (online 2014) — [DOI][doi]                                                                             |
| Version read | Author preprint, 48 pp.; title page: "Author pre-print copy. The final publication is available at Springer via: http://dx.doi.org/10.1007/s10664-014-9324-x" |
| License      | Not stated on the preprint; the published article is not open access (papers `MANIFEST.md`: Unpaywall `is_oa:false`)                                          |
| Dataset      | 177,039 repositories — 4 forges, 3 ecosystems, 4 large-scale projects — from Mockus's 843,976-repository corpus                                               |
| Artifact     | An extended [GitHub Linguist][linguist] classifier for build/source file names, released at the authors' replication site (§4.2.1, fn. 8); not opened here    |
| Category     | Empirical — the maintenance-cost side of build technology, not an engine design                                                                               |

## Overview

### What it solves

Build-maintenance research rested on one to ten projects, mostly `make`, Ant and
Maven, so technology could not be separated from project culture or size: "In such a
small sample, confounding factors like build technology choice can only be modestly
controlled" (§1). Technology becomes the independent variable, and one dependent
quantity is measured throughout: "build maintenance, i.e., the amount of activity
required to keep the build system in sync with the source code" (§1). Activity is
committed lines and commits touching build files — an _observational_ proxy with no
measurement of build duration, correctness or developer time. Nothing here says how
fast an engine builds, only how much its specification gets edited.

### Design philosophy

> "Build systems specify how source code is translated into deliverables. They
> require continual maintenance as the system they build evolves."
>
> — Abstract

Three commitments follow. **Stratify, then corroborate**: the sample is cut into
forges (unrelated teams), ecosystems (shared process, loose coupling) and
large-scale projects (tightly coupled subsystems); a finding counts only where it
repeats. **Rank, do not threshold**: comparisons are Tukey HSD ranks over transformed
distributions, because absolute values are not comparable across hosts. **Say
"associated"**: no causal claim appears, and §6.3 refuses to net extra maintenance
against the features a modern technology buys.

## Method, as documented

### Corpus, strata, filtering

The corpus holds "843,976 distinct repositories" and "over 1.3 terabytes of textual
data" (§4.1.1), stratified into four **forges** ("a service provider that hosts
repositories for development teams"), three **ecosystems** ("a collection of software
that is developed using the same process") and four **large-scale projects** ("records
changes to each subsystem using separate repositories"): GitHub, Gitorious,
repo.or.cz, RubyForge; Apache, Debian, GNU; Android, GNOME, KDE, PostgreSQL. GitHub
dominates because changes must land under one revision id, which "artificially reduces
the size of some ecosystems that support several VCS tools (e.g., Debian)" (§4.1.1).

| Filter | Rule                                         | Survivors | Build systems detected |
| ------ | -------------------------------------------- | --------- | ---------------------- |
| `F1`   | at least 15 source files                     | 506,413   | 57%                    |
| `F2`   | at least 20 commits                          | 306,798   | 193,283 (63%)          |
| `F3`   | under 20% of files unknown to the classifier | 261,367   | —                      |

Of those 261,367, "a total of 170,497 repositories (65%)" contain a detectable build
system — 169,033 GitHub, 645 Gitorious, 602 repo.or.cz, 217 RubyForge (§4.2.2).
Adding the 6,542 ecosystem and project repositories, untouched by the filters (hence
Table 1's identical `# Repositories` and `# After filtering` rows), gives the
abstract's 177,039. Another "35% of the surviving forge repositories did not have a
detectable build system", mostly web applications; overall, filtering "eliminated 80%
of the projects".

### The ten technologies, and how each is recognised

Assignment is name-based and conservative, via an extended GitHub Linguist: a
repository _uses_ a technology if any file matches, and may match several, so
percentages never sum to 100%.

| Paradigm (Smith 2011) | Technology | Recognised by                                                                        |
| --------------------- | ---------- | ------------------------------------------------------------------------------------ |
| Low-level             | `make`     | `(GNU)?[Mm]akefile`, `*.mk`, `*.mak`, `*.make`                                       |
| Low-level             | Ant        | `build.xml`, `build.properties`                                                      |
| Low-level             | Jam        | `[Jj]amfile`, `*.jam`                                                                |
| Low-level             | Rake       | `[Rr]akefile`, `*.rake`                                                              |
| Low-level             | SCons      | `SConstruct`, `SConscript`, `*.scons`                                                |
| Abstraction-based     | Autotools  | `[Cc]onfigure.(ac\|in)`, `ac(local\|site).m4`, `[Mm]akefile.(am\|in)`, `config.h.in` |
| Abstraction-based     | CMake      | `CMakeLists.txt`, `*.cmake`                                                          |
| Framework-driven      | Maven      | `pom.xml`, `maven([123])?.xml`                                                       |
| Dependency management | Ivy        | `ivy.xml`                                                                            |
| Dependency management | Bundler    | `[Gg]emfile`, `[Gg]emfile.lock`                                                      |

The paradigms are the paper's taxonomy (§2), inherited from Smith and defined in §1;
Appendix A prints a minimal working specification for all ten (Figures 17–19). In
[concepts]'s vocabulary the first two paradigms are mostly topological × dirty-bit
machinery, while Maven is a _task-description generator_ whose output the study
measures but whose engine it never inspects.

### Measures and statistics

Table 3 defines **build commit proportion** (share of commits touching a build
specification), **build commit size** (median build lines per build commit) and
**build churn volume** (total build lines changed); size and churn are not
normalised, "in order to simplify interpretation of the results" (§6). Table 4 adds
two logical couplings from Gall et al.:

```text
LC(source ⇒ build) = Support(source ∩ build) / Support(source)
```

`Support(X)` counts commits satisfying `X` (§6, Equation 1); coupling is computed per
technology per repository, so `LC(source ⇒ Ant)` and `LC(source ⇒ Maven)` coexist. A
technology is _active_ from the first to the last month containing a commit that
touches a file of its type, so a migration leaves both active across the switch.
Tukey HSD at `α = 0.01` ranks the forge comparisons after `ln(x + 1)` on sizes and
churn and `arcsin(√x)` on proportions; Mann-Whitney U and Wilcoxon signed rank cover
ecosystems and paired pre/post migration; Poisson regression
`#Projects ~ forge + language + technology + language:technology` describes language
co-occurrence (§5, Figure 5). A language counts above 10% of source files (5% and 15%
"yielded similar results", fn. 9); Appendix B adds a twelve-month rank analysis.

## Findings, as reported

Figures 7–11 and 13–14 are boxplots and beanplots with no printed numbers, so read
them as rank orders; medians below appear only where the prose states them.

### RQ1 — which technologies are broadly adopted

`make` is still the largest single technology: 62,107 GitHub repositories, 37% of
GitHub's 169,033 with a detected build system. Language-specific tools are large
anyway — Rake 75,718 (45% of GitHub), Bundler 37,394 (22%), Autotools 34,318 (20%),
Ant 27,014 (16%), Maven 17,958 (11%), CMake 7,920 (5%), Ivy 2,341 (1%) (Table 1).
Strata diverge: RubyForge is 97% Rake and 100% Ruby, Apache is 63% Ant against 75%
Maven, Debian 58% Autotools and 50% `make`, Android 95% `make`, GNOME 86% Autotools,
KDE 82% CMake (Table 1), even as ecosystems converge — "the Android, GNOME, and KDE
projects adopt[ing] a single technology in more than 82% of project repositories"
(§5). Historically, `make` and Autotools "began to lose market share in 2005, due to an
explosion of Rake-driven Ruby projects", and CMake "began to gather momentum" in 2010
(Observation 1). `make` does not vanish inside converged strata: it survives as the
_construction_ half of an Autotools build, which becomes a measurement problem in RQ3.

### RQ2 — is technology choice associated with project characteristics

Two associations: **size** and **language**. Observation 2: the least-adopted
technologies sit in the largest repositories — "Tukey HSD test results indeed rank Jam
as the largest sample, followed by SCons, and then CMake" — while Maven, Make and Ant
"rank near the bottom due to the mass of small repositories that adopt them", and Rake
and Bundler are bottommost, attributed to "the terse nature of the Ruby language"
(§5). Observation 3 is stronger, printed at `p < 10^-100` for every edge of Figure 5:
"Ant, Maven, and Ivy are quite popular for Java projects, while Rake and Bundler are
almost unanimous choices for Ruby projects. C, C++, and Objective-C projects favour
make, Autotools, and CMake" (§5). §5.1 supplies the mechanism: `make`'s model is
_congruent_ with C-family compilation, whereas "there is a mismatch between the
dependency model of make and the Java compiler" — Ant and Maven "defer `.class`
dependency checks to the Java compiler", which `make`'s mtime comparison cannot
express. Apache OpenOffice's evaluation adds that `make` "supports pattern-based
dependency expressions, while CMake does not".

### RQ3 — is technology choice associated with build change activity

Observation 4: "Maven requires the most build maintenance activity" — highest median
commit proportion, holding "the top Tukey HSD rank" across all twelve analysed months
(§6). Churn ranks the same at the top: "the Maven rates are indeed the highest,
followed by CMake, and then SCons" — CMake being abstraction-based, so the ordering is
not the paradigm ladder. Change _size_ is flatter: "Jam, Ant, and CMake stand out as
requiring larger changes", with Maven and SCons more often in the monthly top three.
Two confounders are corrected rather than footnoted: Autotools' low proportion is
partly split builds — "of the 34,963 forge projects that use Autotools, 7,438 (21%)
only implement the configuration step using Autotools while using make to implement
the construction step", and dropping those lifts Autotools "to similar proportions as
the CMake one" — and Ivy's low rank is pairing, since "when these technologies are
grouped together, the distribution grows to proportions similar to Maven". In the
ecosystems, Maven exceeds Ant on proportion and churn in Apache while committing
smaller changes; in GNU/Debian, Autotools needs more frequent changes than `make` but
`make` churns more lines.

### RQ4 — is technology choice associated with overhead on source development

Observation 5: Maven changes "tend to be tightly coupled to source code changes" —
Tukey rank one, "followed by Rake, and then make", alone in the top rank all twelve
months. Dispersion follows coupling: "The median Maven build author ratio is 65%,
indicating that in half of the studied Maven repositories, at least 65% of the source
code authors also make build changes" (§6) — the opposite of what
convention-over-configuration should buy: "This is surprising because one would expect
that Maven's framework-driven behaviour would reduce the source-build coupling".
Observation 6: "Irrespective of technology, source-coupled build changes tend to
induce more build churn than non-coupled ones do", and Maven and CMake have the largest
source-coupled changes, "indistinguishable from each other". Observation 7, feasible
only on the four large projects: coupling falls with age — GNOME's build author ratio
peaked at 74% of developers and has fallen "to 39%", while PostgreSQL's "peak[ed] in
late 1998 when every active developer submitted a build change" and has since
"dropped as low as 10%" (§6.1). Android is the stated exception: coupling rises, but
from below 0.05, read as convergence to the `make` norm.

§6.2 re-cuts by language. **Java**: Maven changes more often than Ant and Ivy combined
(Mann-Whitney U), "suggesting that Ant with Ivy may be a more cost-effective
alternative than Maven for Java projects that express external dependencies (from the
point of view of build maintenance)" (§6.2.1). **Java and Ruby**: Ivy and Bundler have
"similar commit proportion as (if not higher than) the specifications that define
build behaviour", so "a large amount of build maintenance activity is generated by
external rather than internal dependency management specifications" (Observation 8).
**C family**: CMake has the highest commit proportion but "the lowest median coupling
rate for C and Objective C" (§6.2.2).

§6.3 states the ceiling on all of it:

> "However, the build system is a means to improve overall maintenance team
> productivity. In other words, the increases in build maintenance that we observe in
> Maven may actually be a net benefit to the development team if Maven offers
> additional features that accelerate the development process."
>
> — §6.3

### RQ5 — does migration reduce build maintenance

Migrations are detected automatically — a CMake or Maven specification appearing "at
least one period after another technology" — yielding "89 ecosystem project migrations
(≈ 2%) and 7,225 forge project migrations (≈ 4%)" (§7). Observation 9 is "Build
technology migration often pays off", and the payoff is specifically _authorial_:
churn and coupling are "almost identical" across Ant → Maven, with the author-ratio
drop significant while the other two tests are inconclusive; make or Autotools →
CMake leaves churn rarely impacted but lowers coupling and author ratio, both
significant in Debian and GNU.

KDE supplies the mechanism. The CMake build exists experimentally from late 2004
while Autotools stays official; the switchover is "the steep slope upwards in CMake
and downwards in Autotools in early 2006"; coupling peaks at 0.15 in 2007, dips to
0.05 in 2011, rises again as KDE prepared 4.8, and closes 2012 at 0.06 — "The CMake
migration has reduced the source-build coupling from a roughly stable 0.1 to 0.05"
(§7.1). The build author ratio moves from roughly 50% under Autotools to "as low as
24%" under CMake. The authors call it "unclear whether the decrease … [is] the result
of the migration, perhaps due to the awareness of build maintenance issues raised
during migration, or simply due to the trends that we observed as a project ages
(Observation 7)" — which is why the case study exists.

## Threats to validity, as the authors state them

**Construct (§8.1).** Two assumptions: that related changes land in one commit —
"although our prior work has shown that this may not always be the case" — and that
generated low-level specifications are not committed, so a repository holding a
`Makefile` beside a `CMakeLists.txt` "prepared the changes by hand". Such noise "would
expect inflated results from the low-level technologies, while we observe that
framework-based and abstraction-based technologies tend to induce more build
maintenance activity".

**Internal (§8.2).** Three threats, the second being the one to carry forward:

> "For example, while more numerous, Maven changes may be trivial to implement when
> compared to make changes. Moreover, the reliability of the build system may also
> impact not only the build maintenance effort, but also the overall development as
> well. For example, make-based build systems may be more prone to dependency errors,
> whereas modern tools automate much of the internal dependency management."
>
> — §8.2

The others: the behaviour may be "a property of the development cultures of the
studied hosts", or coincidence, mitigated only by consistency across 177,039
repositories; and counting changes does not measure their difficulty. **Reliability
(§8.3)**: classification is name-based, so the extended Linguist "may miss files that
are build or source related that do not conform to filename conventions", and no manual
validation sample is reported. **External (§8.4)**: open source only, four forges and
three ecosystems, and — of "hundreds of build technologies" — "our findings are
entirely bound to the studied technologies", with corpus coverage as the only
generalisation argument.

## What it implies for build-technology choice

- **Price the specification, not only the build.** A technology halving build latency
  while tripling specification edits is a different trade from the one engine
  benchmarks report; this paper measures only the second axis.
- **Convention-over-configuration relocates cost.** Maven's short, inferring
  specification still produces the highest churn, the tightest source coupling and the
  widest author dispersion: fewer hand-written lines does not mean fewer edits, only
  that edits move into the convention's escape hatches.
- **External dependencies are a first-class maintenance surface.** For Java and Ruby,
  `ivy.xml` and `Gemfile` change at least as often as the rules describing build
  behaviour; dependency management is part of a build language's cost.
- **Migration buys specialisation more reliably than churn reduction.** The one
  consistently significant post-migration effect is the falling build author ratio —
  build work concentrating in fewer hands. That is real ("may help reduce the impact of
  build maintenance that other software developers must pay", §7.1) but a _staffing_
  effect: it defers cost rather than deleting it.
- **Language affinity narrows the choice.** Figure 5's clustering means most projects
  pick from a language's default set, so cross-paradigm comparison is partly
  cross-language comparison.
- **Expect improvement with age regardless.** Coupling falls as projects mature, so a
  post-migration measurement without a longitudinal control overstates the effect.

## Analysis spine

The spine is written for engine deep-dives; this is an empirical study of
specifications, so most dimensions are _not measured_ — and which ones is a finding.

### 1. Task model & scheduling

Not measured: no engine is run, so topological/restarting/suspending ([concepts] §2)
is invisible; §2's taxonomy (tuples, generated tuples, layout conventions) is the
nearest analogue.

### 2. Rebuilding & correctness

Not measured, though `make`'s mtime comparison is congruent with C compilation and
mismatched with `javac`'s own dependency handling (§5.1). No data on how often a build
is wrong.

### 3. Dependency discovery

Only the _declared_ kind exists — `ivy.xml`, `Gemfile`, `pom.xml` dependency blocks,
Autotools and CMake project files — and the contribution is quantitative: they absorb
much maintenance (Observation 8). Traced discovery is outside the frame.

### 4. Store & caching

Only as a dependency-manager feature (§2.4): a local cache of APIs, "quarantined from
the running system", filled from upstream. No CAS, action cache or hit rate.

### 5. Hermeticity & provenance

Absent. Platform variability appears only as the motive for abstraction-based
technologies: "Platform-specific nuances forced maintainers … to repeat several
'boilerplate' low-level build expressions" (§2.2).

### 6. Distribution

Absent as a mechanism: CI and CD motivate the study in §1, and CI providers appear
once as consumers of the adoption data (§10).

### 7. Sparkles relevance

`sparkles.build_primitives.task` is a validated static DAG — `TaskNode`, `TaskEdge`
with an `EdgeCondition`, `OutputPolicy` — run in one pass, with no cost model of the
_authoring_ side. A specification's edit surface is a design output: a `dub.sdl`
schema deriving tasks from convention will be edited less than one demanding explicit
per-target declarations — the mechanism behind the paradigm differences measured here.
Dependency declarations deserve equal design attention, since in Ruby and Java they
carry as much churn; for a future `dub` engine, fold resolution inputs and lockfiles
into the build graph's key. And build _speed_ and build _churn_ are different
variables: a claim that a new engine lowers maintenance cost needs this measurement.

## Strengths and weaknesses

- **Scale plus stratification.** 177,039 repositories, each headline finding required
  to repeat across forges, ecosystems and projects; Table 1 is a reusable adoption
  census.
- **Confounders handled in the open.** The Autotools split-build artefact, the
  Ivy-with-Ant pairing and the age-versus-migration ambiguity are quantified and
  corrected rather than footnoted.
- **Falsifiable, cheap measures.** Logical coupling and author ratio are computable
  from any VCS history, so the study repeats on another corpus — why its method
  outlived its technology list.
- **A proxy, not a cost.** Lines and commits are not effort, difficulty or risk; the
  authors say so, and Maven's extra churn may be cheap edits whose features pay for
  themselves (§6.3, §8.2).
- **Frozen taxonomy.** Ten technologies, name-based detection, corpus ending around
  2012: Bazel, Buck, Ninja-at-scale and Nix are absent, so the paper says nothing
  about the engine designs this catalog surveys. Open source only, four hosts (§8.4).

## Key design decisions and trade-offs

| Decision                                                 | Rationale                                                                     | Trade-off                                                                    |
| -------------------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| Technology as the independent variable, 177,039 repos    | Small samples cannot separate technology from project culture or size         | Observational: associations, never causes; §8.2's confounders stay open      |
| Stratify by forge, ecosystem, large-scale project        | A finding repeating under three coupling regimes is unlikely to be host noise | Four hosts, open source only; large-project findings rest on four projects   |
| Rank distributions (Tukey, Mann-Whitney, Wilcoxon)       | Absolute metric values are not comparable across hosts and sizes              | Ranks hide effect sizes; medians appear as prose, not tables                 |
| Commits touching a build file as the unit                | Computable at corpus scale from history alone                                 | Counts edits, not difficulty; commit atomicity assumed (§8.1)                |
| Name-based classification (extended Linguist)            | Only method fast enough for ~843,976 repositories                             | Misses unconventional names; no validation sample reported (§8.3)            |
| Separate external-dependency technologies (Ivy, Bundler) | Asks whether dependency declarations carry their own maintenance              | Pairing with Ant/Rake distorts single-technology ranks until grouped (§6)    |
| Migration = later-appearing CMake/Maven spec             | Scales to 7,314 detected migrations instead of a handful of case studies      | Cannot distinguish migration from coexistence; paired tests use time windows |

## Sources

- McIntosh, Nagappan, Adams, Mockus & Hassan, _A Large-Scale Empirical Study of the
  Relationship between Build Technology and Build Maintenance_, EMSE 20(6):1587–1633
  (2015) — [DOI][doi]. Read in full from the author preprint
  `$REPOS/papers/build-systems/mcintosh-2015-large-scale-empirical-study-build-technology-build-maintenance-emse-preprint.pdf`
  (48 pp.) via `pdftotext -layout`; section, table and figure numbers are the
  preprint's, and no page numbers are cited because pagination may differ.
- Smith, _Software Build Systems: Principles and Experience_ (Addison-Wesley, 2011) —
  source of the four-paradigm taxonomy (§1, §2); **not opened**. Gall, Hajek &
  Jazayeri, _Detection of logical coupling based on product release history_, ICSM
  1998 — source of Equation 1; **not opened**. Mockus, _Amassing and indexing a large
  sample of version control systems_, MSR 2009 — the corpus; **not opened**.
- [`github/linguist`][linguist] — the classifier the authors extended; referenced, not
  cloned, and no blob URL is pinned.
- Sibling pages: [concepts] (scheduler/rebuilder vocabulary borrowed without
  redefinition), [a-la-carte] (the theory these ten technologies instantiate), [pie]
  (an engine evaluated on runtime, the axis this paper lacks), [index].

<!-- References -->

[doi]: https://doi.org/10.1007/s10664-014-9324-x
[linguist]: https://github.com/github/linguist
[concepts]: ./concepts.md
[a-la-carte]: ./a-la-carte.md
[pie]: ./pie.md
[index]: ./index.md
