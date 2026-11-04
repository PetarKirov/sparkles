# Provenance & Attestation (Theme)

A build system already knows the shape of what it did. Provenance is the separate
act of writing that shape down as a claim someone else can check: which bytes came
out, which inputs went in, which builder ran it, and who signs each answer. The
catalog's systems split cleanly: one engine emits attestations as a product feature
(BuildKit), one signs the objects it stores without describing the builds that made
them (Nix), and the rest emit nothing at all.

**Last reviewed:** November 3, 2026

| Field      | Value                                                                                                                    |
| ---------- | ------------------------------------------------------------------------------------------------------------------------ |
| Category   | Theme — cross-cutting; no single system                                                                                  |
| Question   | What does a build claim about its own execution, who signs it, and what can a consumer check?                            |
| Mechanisms | DSSE envelope, in-toto `Statement`, SLSA provenance predicate, in-toto layout, OCI artifact attachment, store signatures |
| Systems    | BuildKit, Bazel, Nix, REAPI backends, Buck2, Pants, Please, BitBake, and the rest of the catalog                         |
| Vocabulary | [concepts] — _task_, _trace_ and _shallow build_ are defined there; this page does not redefine them                     |

> [!NOTE]
> Scope is **build provenance**: claims produced by or about a build, plus the
> verification model that consumes them. Package-manager signing, SBOM formats and
> transparency logs appear only where a source in this corpus documents them.
> Statements that are analysis rather than quotation are marked **catalog
> inference**.

## Overview

### What it solves

Four questions get conflated and should not:

| Question                          | Answering artifact           | Who can answer it      |
| --------------------------------- | ---------------------------- | ---------------------- |
| Are these the bytes I expected?   | digest, store-object hash    | anyone with the digest |
| What process produced them?       | `.drv`, provenance predicate | the builder            |
| Who asserts that, and can I tell? | DSSE signature               | a key holder           |
| Was that assertion acceptable?    | layout / SLSA expectations   | the consumer's policy  |

A build system can produce the middle two answers for free, and usually does not.
ITE-6 gives the compact framing — an attestation is "authenticated metadata about
software artifacts and the processes that generate them" ([ite-6]) — but SLSA is
blunter about the last column: "provenance doesn't do anything unless somebody
inspects it" ([slsa-verify]).

### Design philosophy

Nix treats provenance as **traceability inside one trust domain**: the `deriver`
table records which derivation produced an output, and the `.drv` graph is the
explanation ([nix-thesis] §5). Its experimental build-trace design states the limit:

> "In general, there is no way to audit a build trace entry except for by performing
> the build again from scratch. … the decision of whether to trust a counterparty's
> build trace is a fundamentally subject [sic] policy choice."
>
> — Nix, [`build-trace.md`][nix-build-trace]

in-toto starts from the supply chain instead of the store, and says outright that it
does not protect against "a functionary … who unwittingly introduces a
vulnerability while following all steps of the supply chain as designed"
([in-toto-spec] §1.6).

Provenance is therefore not a correctness proof, not a reproducibility claim, and
not a vulnerability scan — it is a signed statement about _who ran what_, useful
exactly to the extent that the signer is trusted and the statement is complete.

## How it works — the layer stack

| Layer     | Job                                            | Concrete form                                     |
| --------- | ---------------------------------------------- | ------------------------------------------------- |
| Envelope  | authenticate bytes and their type              | DSSE `Envelope`, COSE, Sigstore bundle            |
| Statement | bind a claim to artifact digests               | `https://in-toto.io/Statement/v1`                 |
| Predicate | say what happened                              | `https://slsa.dev/provenance/v1`, link, SPDX, VSA |
| Chain     | say what was _supposed_ to happen, and by whom | in-toto layout, SLSA expectations                 |
| Transport | carry the envelope beside or inside the output | OCI artifact, `.intoto.jsonl`, `provenance.json`  |

### 1. Envelope — DSSE signs a type and a body

DSSE signs a length-prefixed pair rather than canonicalised JSON:

```text
PAE(type, body) = "DSSEv1" + SP + LEN(type) + SP + type + SP + LEN(body) + SP + body
```

`payloadType` is signed with the payload; `KEYID` is a hint that "MUST NOT be used
for security decisions" ([dsse-protocol]).

> "Implementations MUST ensure that the same SERIALIZED_BODY that is verified is
> the same sent to the application layer. In particular, implementations MUST NOT
> re-parse the envelope after verification to pull out the payload."
>
> — DSSE [`protocol.md`][dsse-protocol]

### 2. Statement — ITE-6 splits claim from context

ITE-6 replaced the rigid link schema with four fields ([ite-6]), carried in a DSSE
envelope ([in-toto-envelope]): `_type`, `subject` (name plus digests),
`predicateType`, and an open `predicate`. The `subject` is the join key: "Subject
artifacts are matched purely by digest" ([in-toto-statement]).

### 3. Predicate — the same event, two vocabularies

The **link** predicate is old in-toto link metadata in statement clothing: `name`,
`command`, `materials`, `byproducts`, `environment`, with `products` moved into
`subject` ([in-toto-link]). Its spec calls it a "generic attestation type" for which a
"more specific predicate type such as Provenance" may be more appropriate.

**SLSA provenance** answers a platform-shaped question:

```text
predicate.buildDefinition: buildType, externalParameters,
                           internalParameters, resolvedDependencies
predicate.runDetails:      builder.id, metadata, byproducts
```

`externalParameters` is "untrusted; they MUST be included in the provenance and MUST
be verified downstream" ([slsa-provenance]). Version 1.0 also _removed_ the two
fields that answered the interesting question: `metadata.completeness` and
`metadata.reproducible` are "Now implicit from `builder.id`" ([slsa-provenance]).
**Catalog inference:** a builder-level identifier cannot express per-build nuance,
which is why BuildKit reintroduces both as extension fields ([buildkit-slsa-defs]).

### 4. Chain — the layout is where policy lives

A single attestation says one step happened; the in-toto **layout** says which steps
were required, who may perform them, and how many must agree:

> "**Supply chain layout**: a signed file that dictates the series of steps that
> need to be carried out in the SSC to create a final product. … the list of actors
> (or functionaries) in charge of carrying out every step."
>
> — in-toto specification, §1.7 [in-toto-spec]

SLSA replaces the layout with consumer-held expectations — builder identity, source
repository, `buildType`, `externalParameters`. **Catalog inference:** a layout is a
_second graph_, maintained beside the build DAG. The claim must travel with the
artifact: a `provenance.json` file for BuildKit's `local`/`tar` exporters, or an OCI
artifact whose `subject` points at the image manifest ([buildkit-att-storage]); a
`.intoto.jsonl` bundle elsewhere ([in-toto-bundle]).

### 5. Levels — what SLSA actually grades

SLSA v1.0 is **retired**; v1.2 keeps the build track and adds a Source track
([slsa-home], [slsa-levels]). L0 is the absence of SLSA:

| Level | Requirement                                        | What it stops                 |
| ----- | -------------------------------------------------- | ----------------------------- |
| L1    | provenance exists, from a consistent process       | mistakes; trivially forgeable |
| L2    | hosted platform generates **and signs** provenance | tampering _after_ the build   |
| L3    | hardened platform: isolation, key inaccessible     | tampering _during_ the build  |

Two limits are stated, not inferred: at L1 "provenance may be incomplete and/or
unsigned", and L3 "does **not** cover compromise of the build platform itself, such
as by a malicious insider" ([slsa-levels], [slsa-verify]).

## What the catalog's systems actually emit

| System             | Emits                                           | Signed by                    | Notes                                                |
| ------------------ | ----------------------------------------------- | ---------------------------- | ---------------------------------------------------- |
| BuildKit           | in-toto + SLSA v0.2/v1, SBOMs                   | nobody, by BuildKit          | opt-in `attest:provenance`; `mode` is `min` or `max` |
| Bazel              | nothing on the action path                      | —                            | BEP is telemetry; BCR _plans_ SLSA verification      |
| Nix                | `.drv` + `deriver`; narinfo signatures          | cache operator's Ed25519 key | signature covers the path, not its derivation        |
| Nix (experimental) | signed build-trace entries, signed realisations | builder key                  | behind `ca-derivations`                              |
| Buck2              | nothing                                         | —                            | `provenance` means config origin                     |
| REAPI backends     | `ExecutedActionMetadata` (worker, timestamps)   | —                            | plain protobuf, no signature field                   |
| BitBake            | nothing                                         | —                            | sstate hash explains _why_ it was trusted            |
| Pants, Please      | nothing                                         | —                            | no attestation code in their trees                   |
| sbt                | cache-origin telemetry                          | —                            | `ActionResult.origin` names the store                |
| Earthly            | nothing of its own                              | —                            | BuildKit frontend; no attestation in its tree        |
| build2, GN, Meson  | nothing                                         | —                            | no action keys to attest                             |
| Sparkles           | nothing                                         | —                            | `TaskId` text identity only                          |

### BuildKit: provenance as a product feature

BuildKit is the only engine here whose documentation is written around attestation
output. `attest:provenance` is a build option; the record includes "Build
dependencies with their immutable checksums" and per-step source and layer mappings
([buildkit-slsa]).

Completeness is a **dial**. `mode=min` omits build-argument values, secret identities
and rich layer metadata; `mode=max` includes them — "the values of various build
arguments and metadata about secrets" ([buildkit-slsa]). Hermeticity is a
**syntactic predicate**: `buildkit_hermetic` is true when a Dockerfile "does not use
`RUN` commands or disables network with `--network=none`" ([buildkit-slsa-defs]) — the
declared-not-observed hermeticity [buildkit] §5 describes. **Catalog inference:**
BuildKit _generates_ the claim; it does not vouch for it. Nothing in
`docs/attestations/` describes signing the envelope; the one signing hook in
`buildkitd.toml.md` is for cache payloads ([buildkit-toml]).

### Bazel, REAPI: telemetry that resembles provenance

Bazel emits no provenance for its actions; the Build Event Protocol is "an
observability stream, not a signed claim about who ran what" ([bazel] §5). Its one
SLSA mention is forward-looking and about _dependencies_: "The Bazel Central Registry
will also support verifying SLSA attestations" ([bazel-roadmap]). Remote execution
does record who ran an action — `ExecutedActionMetadata` starts with "the name of the
worker which ran the execution" ([reapi]) — but the message has no signature field.
**Catalog inference:** schedulers already hold the worker, the timestamps and the
action digest; no REAPI implementation here turns that into a signed claim.

### Nix: sign the object, not the build

Nix's shipped mechanism is a substitution-integrity signature. `nix store sign` signs
a fingerprint of exactly four things:

```text
1;<store path>;<nar hash>;<nar size>;<sorted references>
```

([`path-info.cc`][nix-fingerprint]). The `deriver` field is **not** in it, so a
signature proves "this path has these bytes and these references", not "this
derivation produced it". `nix store verify --sigs-needed n` requires threshold
agreement ([`verify.cc`][nix-verify]), and the same machinery signs CA-derivation
**realisations**, where the store refuses one that "lacks a signature by a trusted
key" ([`local-store.cc`][nix-local-store]). A richer design — a signed memo table mapping
resolved derivations to outputs — is documented and experimental ([nix-build-trace]).
**Catalog inference:** Nix can prove _what_ a store object is, but the shipped record
of _how it was made_ is an unsigned `.drv` link plus a `deriver` column.

Upstream's build-trace design draws a distinction provenance systems often
blur: **coherence is not truth**. A base build trace whose keys are resolved
derivations is trivially coherent because entries are independent claims;
whether an entry faithfully records a build is a separate policy question,
and in general it can only be audited by rebuilding. Derived traces
(unresolved-derivation keys) are different: they are caches over a fixed base
trace and become incoherent if entries derived under two different base
mappings are combined without their underlying entries
([nix-build-trace]). Signing trace entries therefore provides accountability
for _who claims a mapping_, not evidence that the mapping is reproducible.
A verifier that wants truth rather than mere non-contradiction still needs a
rebuild or a trusted builder boundary.

## Correctness risks

- **A signature authenticates the claim, not its truth.** BuildKit records VCS
  metadata the client supplies: "contrary to the `…configSource` field, BuildKit
  doesn't verify the `vcs` values, and as such they can't be trusted"
  ([buildkit-slsa-defs]). Nix says the same about whole build traces
  ([nix-build-trace]).
- **Completeness is best effort, and the dial can hide the interesting part.**
  `mode=min` drops arguments and secret identities ([buildkit-slsa]), and
  `buildkit_completeness` is self-declared ([buildkit-slsa-defs]).
- **The signed predicate and the signed object can diverge.** Nix's fingerprint
  excludes `deriver` ([nix-fingerprint]); in-toto "does not record or verify any
  accompanying artifact metadata such as file permissions and timestamps"
  ([in-toto-spec]). **Catalog inference:** neither says "this object came from that
  derivation, which ran on that worker" in one signed sentence.
- **A bundle is not authenticated as a whole.** "An attacker might be able to delete
  valid attestations, replay obsolete attestations, and/or inject invalid or
  irrelevant attestations in a Bundle without being detected" ([in-toto-bundle]).
- **Subject matching is digest-only** ([in-toto-statement]) and **policy is per
  package** while provenance is per artifact: "Expectations are tied to a _package
  name_, whereas provenance is tied to an _artifact_" ([slsa-verify]).
- **Signing is a key-custody problem before it is a performance problem.** L3
  requires that "secret material used to sign the provenance" be inaccessible to
  user-defined build steps ([slsa-levels]); **no source opened publishes a
  signing-latency or attestation-overhead measurement**, so this page makes no
  performance claim ([sandboxing-overheads] covers the isolation cost).
- **Provenance is one more graph to keep consistent.** If action keys are shallow (a
  hash passthrough — [concepts] §8.4), a record derived from them inherits the
  shallowness. **Catalog inference:** record terminal inputs in
  `resolvedDependencies`, not the cache keys standing in for them.

## Strengths

- **The layer split is the achievement.** DSSE, `Statement` and predicate are
  independently replaceable, so one SLSA predicate can be emitted by BuildKit,
  stored by a registry, and re-checked by a consumer's verifier.
- **The cheapest useful thing is a link predicate.** `command` + `materials` +
  `subject` is what a build engine already holds; emitting it is bookkeeping.

## Weaknesses

- **The expensive thing is trust.** Keys, hosted platforms, tenant isolation and
  expectation maps all live outside the build graph ([ite-6], [slsa-threats]).
- **The most complete record is still not checked.** Nix calls its derivation graph
  traceability ([nix-thesis] §5); BuildKit records "what was requested, not that the
  result is reproducible" ([buildkit]).

## Key design decisions and trade-offs

| Decision                                  | Rationale                                                    | Trade-off                                                       |
| ----------------------------------------- | ------------------------------------------------------------ | --------------------------------------------------------------- |
| Sign a DSSE PAE, not canonicalised JSON   | No canonicalisation library to get wrong                     | Payload type must be carried and signed; KEYID is a hint only   |
| Split `Statement` from predicate (ITE-6)  | Any claim type, one framing; SLSA and SPDX share an envelope | Consumers must parse `predicateType`; parsing is attack surface |
| Grade builders, not builds                | A level is a platform property, checkable once               | Per-build nuance becomes vendor extension fields                |
| Attach attestations to the artifact (OCI) | They travel with what they describe                          | Needs registry support; the envelope is not in the digest       |

## Sparkles relevance

`sparkles.build_primitives.task` is a static task DAG with a stable text identity and
no store. `TaskId` "never contains a memory address, random number, temporary path,
or discovery index"
(`libs/build-primitives/src/sparkles/build_primitives/task/model.d`),
and `toHash` hashes that text rather than any input — the starting point
[reproducibility] describes from the caching side.

What exists is raw material for a **link-shaped** attestation, and almost nothing for
a SLSA-shaped one:

- `TaskNode` carries `id`, `kind`, `action`, `resources` and policies; `TaskEdge`
  carries `prerequisite`, `dependent`, `condition` and `reason`
  (`libs/build-primitives/src/sparkles/build_primitives/task/model.d`).
  Edges are ordering constraints with a _reason_, not data flow — `byproducts`, not
  `resolvedDependencies`.
- `ProcessAction` holds `argv`, an `envDelta` whose entries can be marked `redacted`,
  a `cwd`, a timeout and a `SandboxPolicy`
  (`libs/build-primitives/src/sparkles/build_primitives/task/action.d`).
  `argv` is `predicate.command`; `envDelta` is `internalParameters`; `redacted` is
  already the `mode=min` policy — a secret never written to a log must not reach an
  attestation.
- `TaskEvent` / `TaskOutput` / `TaskFinished` are a live telemetry stream: BEP-shaped,
  useful to a reporter, meaningless as a claim until something signs them and names
  the executor as `builder.id`.

Three mechanics port now, in increasing cost:

1. **Emit a link predicate per task, not SLSA provenance.** `name` = `TaskId`,
   `command` = `ProcessAction.argv`, `materials` = the declared inputs, `subject` =
   the outputs, `byproducts` = the events — a serializer over existing data.
2. **Put the envelope beside the artifact, never inside the key.**
   [content-addressing] states the rule for digests — "record context beside the
   digest, never inside it" — and provenance is context.
3. **Refuse to claim a level.** Sparkles' tasks see the ambient environment, the
   `dub` cache and the Nix store; until that perimeter is stated, "SLSA L2" is
   marketing. The honest order is an unsigned `Statement`, then a subject-digest
   check, then a key, then isolation — SLSA's own order.

## Sources

In-corpus pages synthesized: [concepts] (§7 lists provenance as out of the paper's
scope; §8.4 shallow-build hash passthrough), [buildkit] (§5, the provenance
trade-off), [bazel] (§5), [nix-thesis] (§5), [nix-dynamic-derivations] (§5),
[bitbake] (§5), [reproducibility], [content-addressing], [sandboxing-overheads];
absence checked, no claim drawn, in Buck2, Pants, Please, Earthly, Moon, build2, GN,
Meson and sbt. Primary sources, opened at pinned revisions:

- in-toto attestation framework `fd2609c16bcb0ac53443e2b4612977f997e8f9a5`:
  [`statement.md`][in-toto-statement], [`envelope.md`][in-toto-envelope],
  [`bundle.md`][in-toto-bundle], [`link.md`][in-toto-link]; ITE
  `a6bf0abbc99608ff5920446bf1141417b49a6d30`: [`ITE/6/README.adoc`][ite-6];
  specification `6459afd8e94a332e423ba05c2862b534acbe741d`:
  [`in-toto-spec.md`][in-toto-spec]; DSSE
  `b531b787bb3e5f0c3e1c19cee84da1c5d569b061`: [`protocol.md`][dsse-protocol].
- BuildKit `c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5`:
  [`slsa-provenance.md`][buildkit-slsa], [`slsa-definitions.md`][buildkit-slsa-defs],
  [`attestation-storage.md`][buildkit-att-storage], [`buildkitd.toml.md`][buildkit-toml].
- Nix `1ed54a0fd62da96d4f5e9c806555861e46f65341`: [`build-trace.md`][nix-build-trace],
  [`path-info.cc`][nix-fingerprint], [`local-store.cc`][nix-local-store],
  [`verify.cc`][nix-verify].
- Bazel `2105aec32b598dcc8e09905e7cf18ccfa4b0358e`: [`roadmap.mdx`][bazel-roadmap];
  REAPI `c2c07e3d718d3d490a4958344d9c3e47de0bfaf3`:
  [`remote_execution.proto`][reapi].

**Unverified:** no source opened publishes a signing-latency or attestation-size
measurement, or traces a shipped in-toto layout; the layout material above is the
specification's model, not an observed deployment.

<!-- References -->

[concepts]: ./concepts.md
[buildkit]: ./buildkit.md
[bazel]: ./bazel.md
[nix-thesis]: ./nix-thesis.md
[nix-dynamic-derivations]: ./nix-dynamic-derivations.md
[bitbake]: ./bitbake.md
[reproducibility]: ./reproducibility.md
[sandboxing-overheads]: ./sandboxing-overheads.md
[content-addressing]: ../content-addressing/concepts.md
[ite-6]: https://github.com/in-toto/ITE/blob/a6bf0abbc99608ff5920446bf1141417b49a6d30/ITE/6/README.adoc
[in-toto-spec]: https://github.com/in-toto/docs/blob/6459afd8e94a332e423ba05c2862b534acbe741d/in-toto-spec.md
[in-toto-statement]: https://github.com/in-toto/attestation/blob/fd2609c16bcb0ac53443e2b4612977f997e8f9a5/spec/v1/statement.md
[in-toto-envelope]: https://github.com/in-toto/attestation/blob/fd2609c16bcb0ac53443e2b4612977f997e8f9a5/spec/v1/envelope.md
[in-toto-bundle]: https://github.com/in-toto/attestation/blob/fd2609c16bcb0ac53443e2b4612977f997e8f9a5/spec/v1/bundle.md
[in-toto-link]: https://github.com/in-toto/attestation/blob/fd2609c16bcb0ac53443e2b4612977f997e8f9a5/spec/predicates/link.md
[dsse-protocol]: https://github.com/secure-systems-lab/dsse/blob/b531b787bb3e5f0c3e1c19cee84da1c5d569b061/protocol.md
[slsa-home]: https://slsa.dev/spec/v1.2/
[slsa-levels]: https://slsa.dev/spec/v1.2/build-track-basics
[slsa-verify]: https://slsa.dev/spec/v1.2/verifying-artifacts
[slsa-provenance]: https://slsa.dev/spec/v1.0/provenance
[buildkit-slsa]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/attestations/slsa-provenance.md
[buildkit-slsa-defs]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/attestations/slsa-definitions.md
[buildkit-att-storage]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/attestations/attestation-storage.md
[buildkit-toml]: https://github.com/moby/buildkit/blob/c1cfdbd30b79b4a4908cdccc3c0f9849c30e34e5/docs/buildkitd.toml.md
[nix-build-trace]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/doc/manual/source/store/build-trace.md
[nix-fingerprint]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/path-info.cc
[nix-local-store]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/libstore/local-store.cc
[nix-verify]: https://github.com/NixOS/nix/blob/1ed54a0fd62da96d4f5e9c806555861e46f65341/src/nix/verify.cc
[bazel-roadmap]: https://github.com/bazelbuild/bazel/blob/2105aec32b598dcc8e09905e7cf18ccfa4b0358e/docs/versions/9.3.0/about/roadmap.mdx
[reapi]: https://github.com/bazelbuild/remote-apis/blob/c2c07e3d718d3d490a4958344d9c3e47de0bfaf3/build/bazel/remote/execution/v2/remote_execution.proto
