# `sparkles:age` — Delivery Plan

_Audience: contributors implementing the port. This document is
execution-only — milestones, the dynamic-workflow orchestration that
builds them, verification, and deferrals. For the desired-state
specification read [SPEC.md](./SPEC.md); the normative wire format is
[age-encryption.org/v1](https://c2sp.org/age)._

The work ports the Rust [`rage`](https://github.com/str4d/rage)
implementation (`age-core` + `age`) to D, split into three sub-packages
built bottom-up: `sparkles:crypto` (primitives behind a backend
abstraction; libsodium via ImportC), `sparkles:age` (wire format +
protocol + recipients), and the `age`/`age-keygen` CLI. The milestones
below build that surface; each is realised as a single dynamic-`Workflow`
invocation, run in sequence so the result of one informs the next.

## 1. Architecture

```
libs/crypto  (sparkles:crypto)  — secret-memory foundation + backend-abstracted primitives
   ▼
libs/age     (sparkles:age)     — age wire format + protocol + recipients/identities
   ▼
apps/age     (sparkles:age-cli) — `age` + `age-keygen` binaries
```

Decisions (locked with the maintainer): crypto via a **backend
abstraction** whose first backend binds **libsodium via ImportC** (pure-D
backend later); generic primitives in **`libs/crypto`**; recipients =
**X25519 + scrypt + ssh-ed25519** shipped, **ssh-rsa deferred** (needs a
second backend, §6); **library + CLI**; and — critically — the
**secret-memory abstraction is built first**
(the D analogues of RustCrypto `zeroize` + iqlusion `secrecy`), as the
bedrock under all key material.

## 2. Milestone overview

Status legend: ✅ done · ⏸ deferred.

| #       | Deliverable                                                                                                                                                                                                    | Depends on | Status      |
| ------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------- | ----------- |
| **M0**  | Docs ([SPEC](./SPEC.md)+PLAN) + scaffolding: both `dub.sdl`, `sodium_c.c`, nix libsodium delta, root subPackages — green skeleton, libsodium link confirmed                                                    | —          | ✅          |
| **M1**  | **Secret-memory foundation (first):** `zeroize`, `secret`, `ct`, crypto concept/size vocabulary — pure-D, no libsodium ([SPEC §3](./SPEC.md#3-secret-memory-foundation), [§4](./SPEC.md#4-the-crypto-backend)) | M0         | ✅          |
| **M2**  | `crypto` encodings: base64, bech32, hex ([SPEC §5](./SPEC.md#5-encodings))                                                                                                                                     | M1         | ✅          |
| **M3**  | `crypto` primitives: SHA, HMAC, HKDF, ChaCha20-Poly1305, X25519, CSPRNG ([SPEC §6](./SPEC.md#6-primitives))                                                                                                    | M1, M2     | ✅          |
| **M4**  | `crypto` scrypt ([SPEC §6](./SPEC.md#6-primitives))                                                                                                                                                            | M3         | ✅          |
| **M5**  | `age` format + STREAM + armor ([SPEC §7](./SPEC.md#7-the-age-wire-format))                                                                                                                                     | M3         | ✅          |
| **M6**  | `age` X25519 + scrypt recipients + protocol + simple + keygen ([SPEC §8](./SPEC.md#8-recipient-and-identity-concepts)–[§10](./SPEC.md#10-protocol))                                                            | M4, M5     | ✅          |
| **M7**  | `age` testkit conformance — all 114 vectors ([SPEC §12](./SPEC.md#12-conformance-and-test-vectors))                                                                                                            | M5, M6     | ✅          |
| **M8**  | `age` ssh-ed25519 + OpenSSH/authorized_keys parsing + identity files ([SPEC §9.3](./SPEC.md#93-ssh-ed25519))                                                                                                   | M6         | ✅          |
| **M9**  | `age` ssh-rsa + encrypted OpenSSH keys — needs a 2nd backend ([SPEC §9.4](./SPEC.md#94-ssh-rsa-deferred--not-implemented-in-this-build))                                                                       | M8         | ⏸ deferred |
| **M10** | CLI `age` + `age-keygen` + error matrix + golden fixtures ([SPEC §13](./SPEC.md#13-command-line-tools))                                                                                                        | M7, M8     | ✅          |
| **M11** | Docs + README polish; runnable examples verified by `ci --verify`                                                                                                                                              | M0–M10     | ✅          |

M0 scaffolds. M1 is the foundation (pure-D, no backend). M2–M4 are crypto.
M5–M7 are the core age protocol and conformance gate. M8 ships ssh-ed25519.
M10 is the CLI; M11 is docs polish. **M9 (ssh-rsa) is deferred** — see §3 and
§6 — because libsodium provides no RSA-OAEP / bcrypt-pbkdf / AES; closing it
needs a second crypto backend (OpenSSL). Everything else shipped: `sparkles:crypto`
(122 tests, RFC/BIP KAT-verified), `sparkles:age` (278 tests including all 114
official testkit vectors, interop with rage 0.11.1 both directions), and the
`age`/`age-keygen` CLI.

## 3. Per-milestone detail

Each milestone's outcome is the relevant SPEC sections compiling, passing
their tests, and documented per [AGENTS.md](../../guidelines/AGENTS.md). Detail
below is execution-focused; follow the linked SPEC sections for behaviour.

### M0 — Scaffold + docs

- `docs/specs/age/{SPEC,PLAN}.md` (this and the spec).
- `libs/crypto/dub.sdl` (name `crypto`, `-P-I$SODIUM_INCLUDE`, `libs
"sodium"`, `systemDependencies "libsodium"`, dep `sparkles:core-cli`
  `path="../.."` inside the config blocks — mirror `libs/versions/dub.sdl`).
- `libs/crypto/src/sparkles/crypto/sodium_c.c` = `#include <sodium.h>`;
  `package.d` imports it and exposes a trivial `sodium_init() >= 0` check.
- `libs/age/dub.sdl` (dep `sparkles:crypto`) + empty `package.d`.
- Root `dub.sdl`: add `subPackage "libs/crypto"`, `"libs/age"`,
  `"apps/age"`.
- `nix/shells/default.nix`: add `pkgs.pkg-config`, `pkgs.libsodium`,
  `pkgs.libsodium.dev`; export `SODIUM_INCLUDE` in the `shellHook`.

**Key files:** the two docs, `libs/crypto/{dub.sdl, src/sparkles/crypto/{sodium_c.c, package.d}}`, `libs/age/{dub.sdl, src/sparkles/age/package.d}`, root `dub.sdl`, `nix/shells/default.nix`.

### M1 — Secret-memory foundation

The bedrock, built first and pure-D (no libsodium link exercised). Modeled
on RustCrypto `zeroize` + iqlusion `secrecy` per
[SPEC §3](./SPEC.md#3-secret-memory-foundation).

- `zeroize.d` — `zeroizeMemory` (volatile + barrier), `isZeroizable!T`,
  `Zeroizing!T`.
- `secret.d` — `SecretBuffer`/`SecretArray`/`SecretString`,
  `exposeSecret(Mut)`, `isSecret!T`, redacted `toString`, `initWithMut`.
- `ct.d` — `ctEquals`, `ctIsZero`.
- `concepts.d` + `backend/traits.d` — compile-time sizes,
  `Key!T`/`Nonce!T`/`Tag!T`, `isCryptoBackend`/`has*`,
  `isDigest`/`isMac`/`isAead` ([SPEC §4](./SPEC.md#4-the-crypto-backend)).

**Key files:** `libs/crypto/src/sparkles/crypto/{zeroize,secret,ct,concepts}.d`, `backend/traits.d`.

### M2 — Encodings

`encoding/{base64,bech32,hex}.d` per [SPEC §5](./SPEC.md#5-encodings),
with the three additive `ParseErrorCode` members in
`core_cli.text.errors` (`checksumMismatch`, `nonCanonicalEncoding`,
`invalidPadding`). Strict canonical decode is security-critical.

### M3 — Primitives

`backend/sodium.d` (`SodiumBackend` + `sodium_init` via
`crt_constructor`), `hash.d`, `hmac.d`, `hkdf.d`, `aead.d` (+
`StreamNonce`), `x25519.d`, `ed25519.d`, `random.d` per
[SPEC §6](./SPEC.md#6-primitives). Key outputs are `SecretArray`/
`Zeroizing`. `static assert(isCryptoBackend!SodiumBackend)`.

### M4 — scrypt

`scrypt.d` over `crypto_pwhash_scryptsalsa208sha256_ll` (r=8, p=1, 32-byte
output, `in (logN < 64)`).

### M5 — age format + STREAM + armor

`format/stanza.d`, `format/header.d` (raw `encodedBytes` for MAC,
slice-advance parser, scrypt-singleton, legacy-body tolerance), `mac.d`,
`stream.d` (`StreamWriter`/`StreamReader`, mandatory `finish()`),
`armor.d` per [SPEC §7](./SPEC.md#7-the-age-wire-format). The
highest-risk modules; pinned by the testkit vectors at M7.

### M6 — X25519 + scrypt recipients + protocol

`recipient.d`/`identity.d` (concepts + `Any*` sum types),
`recipients/x25519.d`, `recipients/scrypt.d`, `keys.d`, `protocol.d`
(`Encryptor`/`Decryptor`), `simple.d`, `keygen.d` per
[SPEC §8](./SPEC.md#8-recipient-and-identity-concepts)–[§10](./SPEC.md#10-protocol).

### M7 — Testkit conformance

Vendor the 114 vectors into `libs/age/tests/testkit/`; `testkit_vectors.d`
(the 114 vector names) + `testkit_runner.d` (a string-import `static foreach`
runner) per [SPEC §12](./SPEC.md#12-conformance-and-test-vectors). Gate: all
114 pass.

### M8 — ssh-ed25519

`recipients/ssh_ed25519.d`, `recipients/ssh_keys.d` (authorized_keys +
OpenSSH private-key parsing), `identity_file.d` per
[SPEC §9.3](./SPEC.md#93-ssh-ed25519). No testkit vectors exist for SSH →
hand-authored round-trips + interop against `rage`/`age`.

### M9 — ssh-rsa (DEFERRED)

Per [SPEC §9.4](./SPEC.md#94-ssh-rsa-deferred--not-implemented-in-this-build),
**M9 is deferred and not shipped.** RSA-OAEP (ssh-rsa stanzas) plus
bcrypt-pbkdf + AES-CTR/CBC (encrypted OpenSSH keys) are absent from libsodium
and need a second crypto backend (e.g. OpenSSL deimos). The decision, flagged
as possible from M0, was confirmed here: rather than pull in a whole second
backend for one legacy recipient type, this build ships without
`recipients/ssh_rsa.d`. ssh-rsa keys and encrypted OpenSSH keys are **cleanly
rejected** (a structured error, never a silent mis-handling) by `ssh_keys`/
`identity_file`, so the gap is explicit. The recipient/identity concepts (§8)
already absorb a future addition behind the backend abstraction without an API
change.

### M10 — CLI

`apps/age` (dub name `age-cli`) with `age` + `age-keygen` binaries:
`AgeOptions` + validation matrix, I/O layer (file/stdin/stdout/`-`, atomic
file, mode 0600, TTY guard), passphrase TTY entry, keygen generate +
convert, golden fixture tests ported from `rage/tests/cmd/`. Adds nix
derivations + the root `subPackage`. See
[SPEC §13](./SPEC.md#13-command-line-tools).

### M11 — Docs + README

Finalize SPEC/PLAN to the shipped state; add a `sparkles:age` README
section with runnable examples verified by `nix run .#ci -- --verify`;
DDoc on public symbols.

## 4. Execution via dynamic workflows

Each milestone is **one `Workflow` invocation**, run in sequence.
Conventions mirror [`docs/specs/versions/PLAN.md` §3](../versions/PLAN.md):

- **Parallel fan-out over disjoint files** (one module per agent) — no
  worktree isolation needed.
- **Single serial build-and-fix loop** after each fan-out, running
  `nix develop -c dub test :crypto` / `:age` — the only compile authority.
- **Schema-validated agent output** so the orchestrator branches on data.
- **Adversarial verification on crypto correctness** (M3 primitives, M4
  scrypt, M6 recipients, M8/M9 SSH): an independent skeptic tries to
  _refute_ the implementation against authoritative test vectors.
- **Completeness critic** on M5 (format) and M10 (CLI).

**WF-M1 is special:** pure-D (no libsodium), so its build-fix loop runs
before the backend link is exercised; its gates are wipe-on-drop, `toString`
redaction, and concept conformance.

## 5. Verification

| M   | Gate                                                                                                                                                                                     |
| --- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| M0  | `nix develop -c dub build :crypto && dub build :age` exit 0; `sodium_init() >= 0` unittest confirms libsodium links                                                                      |
| M1  | `dub test :crypto` green; wipe-on-drop verified, secret `toString` redacted, `static assert(isSecret!FileKey)` + concept asserts compile (pure-D)                                        |
| M2  | `dub test :crypto` green; RFC 4648 + BIP173 vectors incl. canonical-reject pass                                                                                                          |
| M3  | `dub test :crypto` green; RFC 7539/5869/7748 + age X25519 intermediates pass; `isCryptoBackend!SodiumBackend`; skeptic finds no refutation                                               |
| M4  | `dub test :crypto` green; RFC 7914 scrypt vectors pass                                                                                                                                   |
| M5  | `dub test :age` green against the format/stream/armor testkit slice                                                                                                                      |
| M6  | `dub test :age` green; X25519 + scrypt round-trips + `simple` API pass                                                                                                                   |
| M7  | `dub test :age -- -i testkit` green — **all 114 vectors pass**                                                                                                                           |
| M8  | ssh-ed25519 round-trips pass; interop: our-encrypt→`rage`-decrypt and `rage`-encrypt→our-decrypt succeed                                                                                 |
| M9  | ⏸ **Deferred** — documented in [SPEC §9.4](./SPEC.md#94-ssh-rsa-deferred--not-implemented-in-this-build); ssh-rsa / encrypted-OpenSSH keys are cleanly rejected rather than mis-handled |
| M10 | `dub test :age-cli` (fixture runner) green; `--help` golden outputs match; rage error matrix reproduced                                                                                  |
| M11 | `nix run .#ci -- --verify --files README.md` passes; no stale references                                                                                                                 |

End-to-end check after M6/M10: `age-keygen -o key.txt`, then
`echo hi | age -r <pub> -a | age -d -i key.txt` returns `hi`; cross-check a
file encrypted by our `age` decrypts with the reference `rage` and vice
versa.

## 6. Out-of-scope deferrals

- **PQ & tagged types** (`mlkem768x25519`, `p256tag`, `mlkem768p256tag`)
  and the **plugin IPC protocol** — no D ML-KEM/P-256/HPKE; no local
  testkit vectors.
- **ssh-rsa / encrypted OpenSSH keys** — need a second backend
  (OpenSSL deimos); the backend abstraction absorbs this. Confirmed at M9.
- **Async + seekable streaming** — designed-for, deferred (sync in-memory
  first).
- **Pure-D crypto backend** — the abstraction supports it; libsodium ships
  first.
- **pinentry / plugin `-j`** — stubbed with a "not supported" message.

---

→ [SPEC.md](./SPEC.md) — desired-state specification
→ [age-encryption.org/v1](https://c2sp.org/age) — normative wire format
