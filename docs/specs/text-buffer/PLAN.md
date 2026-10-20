---
status: draft
owner: sparkles:text-buffer
reviewed: 2026-10-21
---

# `sparkles:text-buffer` — Delivery plan

This plan is the milestone tracker for the
[specification](./SPEC.md). The editing component that consumes it is
planned in [the editor specification](../ui/editor.md#milestones), and the
segmentation it relies on in
[the base text plan](../base/text/PLAN.md).

| Milestone | Scope                                                                                        | Status      | Requirements                        |
| --------- | -------------------------------------------------------------------------------------------- | ----------- | ----------------------------------- |
| TB0       | Package skeleton; node allocator and atomic counts; chunker; `Text` with summaries and lines | not started | TXB-TEXT1–7, TXB-POS2–3, TXB-OWN1–4 |
| TB1       | Bidirectional chunk iteration feeding the base steppers                                      | not started | TXB-POS1                            |
| TB2       | Change sets                                                                                  | not started | TXB-CHG1–7                          |
| TB3       | History tree                                                                                 | not started | TXB-HIS1–6                          |

**Stage 0.** Owner acceptance of this specification and the editor's is the
gate for TB0. TB0 to TB3 ship together as the first pull request of the
implementation stack, after the base steppers (`TXT-SEG7` to `TXT-SEG9`).

**Acceptance for every milestone.** `dub test :text-buffer` passes with
the generated tests of [testing](./testing.md) for the milestone's
requirements; the evidence table gains one row per requirement.

## Next executable action

Accept or revise the specification. Then create `libs/text-buffer` with
the `sparkles:test-runner` integration and begin TB0 with the reference
model and the chunker's boundary tests.
