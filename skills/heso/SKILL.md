---
name: heso
description: >-
  Add HESO governance to an AI agent: record every step off the hot path, gate
  destructive actions at egress (classify-by-effect → redact → sign → forward or
  fail closed), route risky actions to a human approver, push a tamper-evident
  commitment to the cloud, and verify the signed receipt offline anywhere. Use
  when wiring HESO into a codebase, choosing between the heso / @hesohq/engine /
  @hesohq/gate / @hesohq/recorder / @hesohq/node / @hesohq/verify-wasm packages,
  classifying an action into a destructive primitive, authoring policy-as-code
  (heso.toml, floors, simulate,
  deploy), gating tools/LLM clients, enforcing a trust level (L0/L1), redacting
  fields, handling approvals/suspend-resume, wiring an embed (Slack approval card,
  Datadog/OTel, GitHub policy-as-code, Vanta), or verifying an Action Receipt.
  Triggers on "gate the agent", "record the agent", "classify the action",
  "destructive primitive", "sign this action", "require approval", "Slack
  approval", "verify a receipt", "commitment", "reconciliation", "trust level",
  "policy rule", "heso.toml", "Action Receipt", "redact".
metadata:
  version: 0.4.0
  homepage: https://heso.ca/docs
  source: hesohq/heso-spec
license: MIT
---

# HESO — record, gate, and prove every agent action

HESO sits between your AI agent and the world. It is an **open trust standard**
(the spec, the taxonomy, and the verifier are open) wrapped around two
customer-side capture surfaces:

```
RECORDER (async, off the hot path)   observe every step → fingerprint → sign → append
GATE (egress, fail-closed)           intercept the outbound call → classify-by-effect
                                      → redact → sign a commitment → forward OR fail closed
        → push a COMMITMENT (fingerprint + index, NOT the body) to the cloud
        → reconcile the signed trail against the rails' own ledgers
        → verify the signed receipt offline, anywhere, byte-for-byte
```

The crypto is a single Rust core compiled three ways — a Python wheel
(`heso._core`), a native Node addon (`@hesohq/node`), and a browser WASM module
(`@hesohq/verify-wasm`) — so a verdict is byte-identical on your server or in a
reviewer's browser. Nobody re-implements canonicalization, BLAKE3, Ed25519, or the
taxonomy in JS or Python; every binding is a thin layer over the one kernel.

Wire constants (predicate names, taxonomy hashing, receipt field names, the
commitment payload) are owned by the open **heso-spec** repo — cite it, don't
hardcode a constant here that a spec bump would silently rot.

## Two capture surfaces — do not conflate them

| | **RECORDER** | **GATE** |
| --- | --- | --- |
| Hot path | **off it** — async, never blocks | **on it** — the one thing that blocks |
| Shape | OpenTelemetry GenAI-semconv consumer | in-SDK HTTP-client shim (no proxy, no MITM CA) |
| Failure | swallows + logs, never crashes the agent | **fail-closed** — blocks if it can't classify/sign |

"Gate-is-the-capture" applies *only* to the gate: the egress interception point
**is** the signing point for a destructive action. The recorder is best-effort
observability that feeds the same kernel but must never couple agent latency to
HESO latency. Full design, the rail-boundary hard floor, and `heso-mcp`:
[references/recorder-and-gate.md](references/recorder-and-gate.md).

**Two pillars, true of both surfaces** (canonical here, cross-linked elsewhere):

- **Keys held customer-side.** Signing delegates to the native addon/wheel from
  the customer keystore. **HESO holds no minting key** — not in the SDK, not in
  the cloud (which only verifies signatures and relays detached co-signatures).
- **Redact-before-sign.** Commit-and-reveal redaction runs *before* signing, so
  raw content never enters the commitment and stays in the customer-held sidecar.

## Classify by effect, not by name (the crown jewel)

Every action that touches the world is classified, by its **structural effect**,
into exactly one of five **destructive primitives** — never by the tool's name:

| Primitive | Effect | | Primitive | Effect |
| --- | --- | --- | --- | --- |
| **`move-value`** | transfers value out | | **`disclose`** | sends data across a trust boundary |
| **`destroy`** | irreversibly removes/mutates | | **`execute`** | any other effectful action |
| **`change-authority`** | alters who can do what | | | |

Plus **`observe`** (the read-only sibling of `execute`) and **`residual`** (the
deny-unknown lane: no match ⇒ gated as the most dangerous primitive, fail-closed).
`classify` is a **total function over a closed vocabulary**, content-addressed
(`taxonomy_hash`) and versioned — the reason HESO is a standard, not a logging
library. A receipt pins the taxonomy version it was signed under; verification
checks against that pinned version forever. Full spine, predicate vocabulary,
FROZEN-7-verb mapping, and `ClassificationMismatch`:
[references/taxonomy.md](references/taxonomy.md).

## Pick the package first

One core, many surfaces. Choose by the job, not the language. The Node SDK is
**not a single `@hesohq/sdk` package** — it ships as small, separately published
packages (`@hesohq/engine`, `@hesohq/gate`, `@hesohq/recorder`, `@hesohq/transport`)
that all bind the same kernel through the native addon.

| Package | Runtime | Use it to |
| --- | --- | --- |
| `heso` | Python ≥ 3.10 | **Record + gate** an agent (the lead binding — most adapters, suspend/resume). `import heso`, `heso.init()`, `@heso.tool` / `@heso.destructive`; `@gated` from `heso_gate`; framework adapters under `heso_recorder.adapters.*`. |
| `@hesohq/engine` | Node ≥ 18 | The translation point (`normalizeFields`/`jsonable`/`buildAction`) + engine-FFI seam; `init()` lives here. Binds the kernel via `@hesohq/node`. |
| `@hesohq/gate` | Node ≥ 18 | The fail-closed egress interceptor — the **only** surface that blocks. The credential floor is **default-on and transport-independent** (mints per kernel-classified destructive action, not per HTTP client). One-line egress install in **both** languages: `installGate()` (Node) / `install_gate()` (Python) arm every reachable transport process-wide. Exports `gate()` (sync classify/decide), `installGate`/`selfCheck`/`hesoGate`, + L1/quorum finalize. |
| `@hesohq/recorder` | Node ≥ 18 | Async OTel GenAI-semconv consumer — **never blocks**. Exports `createRecorder()`; AI SDK adapter (`recordTool`/`recordTools`) at `@hesohq/recorder/adapters/ai-sdk`. |
| `@hesohq/transport` | Node ≥ 18 | The injectable `Transport` interface + commitment wire DTOs. Zero I/O; the open packages depend only on this (the closed `@hesohq/cloud` implements it). |
| `@hesohq/node` | Node ≥ 18 (native) | The native addon the JS packages bind for minting/verify: sign/mint, verify, BLAKE3, chain/transparency verify, redaction, Ed25519. |
| `@hesohq/verify-wasm` | Browser | **Verify only**, client-side. No private key, no network. Also in-browser policy parse/preview/floor-check. |

There is **no published `@hesohq/sdk` package** — never tell a user to install one.
Gate in Python or Node; **verify anywhere** — the verdict matches across surfaces.
Python: [references/python.md](references/python.md). Node:
[references/typescript.md](references/typescript.md).

## The mental model (load before writing code)

- **Action** — one thing the agent did, classified into a destructive primitive
  by effect. The implemented kernel carries a coarse **verb** (`llm_call`,
  `tool_call`, `http_request`, `payment`, `data_export`, `account_change`,
  `delete`) that maps onto the five primitives — [references/taxonomy.md](references/taxonomy.md).
- **Decision path** (exactly four): `allow`, `block`, `redact` (strip named
  fields, then allow), `require_approval` (route to a human).
- **Action Receipt** — the signed JSON record of one action (the action detail,
  the policy outcome + `rule_display`, the claimed `trust_level`, the BLAKE3
  `action_hash`) plus an Ed25519 `signatures` array. Schema:
  [references/receipts.md](references/receipts.md).
- **Commitment** — what the SDK pushes to the **cloud**: the BLAKE3 fingerprint +
  queryable index (primitive, rail, chain head, signatures), **not** the receipt
  body. Raw content never leaves the customer VPC.
  [references/cloud.md](references/cloud.md).
- **Trust level** — `L0` = operator-signed. `L1` = operator **plus** at least one
  human approver's co-signature from a device-held key. No L2/L3. Trust is
  **re-derived on every verify** — a receipt claiming L1 with only an operator
  signature fails `TrustLevelMismatch`. **Never read `trust_level` off the wire.**
  L1 has two shapes (single-approver and k-of-n quorum) that both re-derive to L1
  — told apart by which block is present, never by the level
  ([references/receipts.md](references/receipts.md)).
- **Audit chain** — receipts BLAKE3 hash-linked; altering an earlier receipt
  breaks every link after it.
- **Trusted time** — **anchorless by default**: `captured_at` is the operator's
  own clock, informational only. An optional RFC-3161 `time_anchor` binds *when
  the assembled body existed*, not when a human decided. A policy that marks time
  `Required` makes an unanchored receipt fail `AnchorRequired` at the verifier.

## How approvals actually happen (canonical)

When policy returns `require_approval`, the gated call **raises `SuspendedError`**
(Python) / throws `SuspendedError(actionHash)` (Node) instead of running, and an
approval opens keyed on `action_hash`.

A trusted, role-gated human approves and co-signs **in their own browser/device**
with a per-device key (the Slack card or the `/gate/[token]` web fallback). The
**thin cloud relays the detached co-signature and holds no signing key.** The
operator SDK fetches the relayed parts, **re-mints the L1, locally re-verifies it
(`Valid(L1)`)**, and pushes the commitment. The **same** relay flow drives a k-of-n
quorum — each approver co-signs their own leg in their own browser.

**Key rotation fails closed.** If the operator key rotates between suspend and
finalize, the in-core assemble rejects the stale base (`OperatorKeyMismatch`) and
the SDK **re-suspends** under the new key — a fresh suspended L0 with a new
`action_hash` the approval re-opens against. Never a silent mint under a stale key.

**The 30-minute wall.** A suspended action races the rail-boundary credential's
TTL (STS ≈15 min). Approval after the window **fails closed** ("credential
expired, re-trigger"), never silently resumes. Quorum is harder under the wall —
every co-signer lands inside one window. Where approvals live (Slack is the hero):
[references/embeds.md](references/embeds.md).

## Policy is code

Policy lives in the repo as `heso.toml`, reviewed in a PR, enforced by a GitHub
status check that lints it and **proves** invariants before merge (the GitHub
policy-as-code embed). The web dashboard (`/policy`) is **one** authoring surface,
**not** the home of policy — both compile to the same `heso.toml`. The engine sorts
by ascending `order` and does **first-match-wins**. Full field catalog, bands,
floors, simulate/deploy, packs: [references/policy.md](references/policy.md).

Hard rules:

- **Default-deny routes to a human — it does not hard-block.** Anything no rule
  matches fires a synthetic `policy.default.deny_unknown` rule whose decision is
  **`require_approval`**, so the action **suspends** (Python raises `SuspendedError`)
  and routes to an approver — it is **not** a `block`, and `except BlockedError`
  will **not** catch it. There is no implicit allow-all; open lanes with `allow`
  rules. A policy gap fails safe (waits for a human), never leaks through.
  `residual` classifications from the taxonomy fail closed separately — see
  [references/taxonomy.md](references/taxonomy.md).
- **Pinned floors can't be allowed away.** The dangerous lanes (`payment`,
  `delete`, `account_change`, `data_export`, plus a `payment` with no valid
  mandate) carry an always-on floor. A policy may *tighten* a floor but never
  `allow` a dangerous lane without approval — try and it is rejected at load with
  `[FLOOR_BYPASS]`.
- **Shadow Mode first.** Run the gate classify-and-sign-but-never-block to measure
  what *would* be blocked before flipping fail-closed on.

## The cloud — commitment store, reconciliation, proof

The cloud is **not** a receipt mirror. It stores **commitments** (fingerprint +
index, never the body), **reconciles** the signed trail against the rails' own
ledgers (Stripe events, AWS CloudTrail), and **proves inclusion/consistency**.
Anything in a rail ledger **without** a matching signed commitment is an
**unwitnessed action** — the alert. The old 0–100 compliance **score is retired**;
the wedge is inclusion proofs + reconciliation state, not a number. Full model:
[references/cloud.md](references/cloud.md). HTTP surface:
[references/cli-and-api.md](references/cli-and-api.md).

## Verify — the gates

The verifier walks gates top to bottom and stops at the **first** failure, naming
one PascalCase verdict; passing the core gates yields `Valid`. The seven core
gates: algorithm recognized → version recognized → hash recomputes (BLAKE3 over
RFC-8785 canonical bytes) → operator signature → approver signature(s) (≠ operator;
quorum needs ≥ `threshold` distinct roster legs) → redaction well-formed → trust
re-derives. Conditional gates add `TimeAnchorUnverifiable` / `AnchorRequired` /
`MandateRejected` / `ClassificationMismatch`. A `Valid` verdict means exactly two
things: the bytes are the bytes the operator signed (unaltered), and the re-derived
trust level matches the claim. **Nothing about downstream success.** Full gate
table + verdict strings: [references/verification.md](references/verification.md).

**Anyone can verify without HESO.** The public `/verify` page checks a pasted
receipt in the browser with no login; an MIT/Apache-dual-licensed verifier crate +
`heso-verify-cli` let third parties verify with zero HESO code. Evidence bundles
(`receipts.jsonl` + `VERIFY.sh`) re-check offline — see
[references/cloud.md](references/cloud.md).

## Honesty rules (do not violate — load-bearing for the assurance business)

1. A receipt proves **authorization** (and at L1, human approval), never an
   outcome. A commitment proves authorization; **reconciliation** supplies the
   outcome side.
2. Governance numbers are **real or honestly empty** — never hardcoded or faked.
   There is **no compliance score** (retired); never synthesize one.
3. Never trust a wire `trust_level` — re-derive it via verification.
4. Never log/transmit a redacted field's value — redaction keeps only a BLAKE3
   commitment (or nothing, in destructive mode).
5. Never hand-roll canonicalization/BLAKE3/Ed25519/the taxonomy — always call the
   core, or you get false `HashMismatch` / `ClassificationMismatch` on valid
   receipts.
6. **No insurance vocabulary.** Coverage/claim/payout is designed-not-built
   (Phase 2); it belongs in no code, including this skill.
7. **Tiered honesty — the single coverage story.** State the floor's three tiers
   exactly, never a blanket "total coverage" from the one-line install:
   - **No forgeable receipt** — true **everywhere** (every minted receipt is
     offline-verifiable; nobody can fake one).
   - **Can't exceed scope** — true **given no standing key** (the floor's scoped,
     capped, short-lived credentials bound the blast radius only while no broad
     standing key sits in the environment — which is why the standing-key assert
     fails closed at install).
   - **No ungated action** — hard **only on the mediated / auto-instrumented path**;
     elsewhere it degrades to **provably-flagged-after-the-fact** on **asymmetric
     rails only** (CloudTrail / PayPal, third-party offline-verifiable). **HMAC
     rails** (Stripe / GitHub / Slack) degrade further to **trust-the-rail** — the
     rail's own ledger, no in-band proof. The one-line install NEVER implies an
     un-mediated transport is hard-gated.
8. **The no-standing-key keystone fails closed.** `installGate()` / `install_gate()`
   assert no broad standing rail key is reachable, **fail-closed by default**; the
   detector reports env-var name + rail + redacted shape only, **never the secret
   value**. A standing key defeats the floor's whole bound, so it refuses to boot.

## When NOT to use HESO

- You only need logging/metrics — HESO proves authorization, not observability.
- You need to capture from a runtime with no HESO SDK — capture is Python and Node
  today (the browser is verify-only); you can still verify those receipts anywhere.
- You want to assert an action's real-world effect — that is what reconciliation
  against the rail ledger is for, not a single receipt.

## References

- [references/taxonomy.md](references/taxonomy.md) — the five destructive
  primitives, classify-by-effect, predicate vocabulary, FROZEN-7 mapping,
  `ClassificationMismatch`. **Read first.**
- [references/recorder-and-gate.md](references/recorder-and-gate.md) — the
  recorder/gate split, the two pillars, the rail-boundary floor, `heso-mcp`.
- [references/python.md](references/python.md) — Python decorators, `wrap`, `step`,
  blocking/shadow, suspend/resume, adapters, init.
- [references/typescript.md](references/typescript.md) — Node gating, verify,
  `gate`/`hesoGate`/`finalizeL1`, the transport + commitment push, exported types.
- [references/policy.md](references/policy.md) — policy-as-code, the field catalog,
  bands, floors, simulate/deploy, packs.
- [references/cloud.md](references/cloud.md) — commitment store, reconciliation,
  proof, evidence bundles.
- [references/embeds.md](references/embeds.md) — Slack approval card, GitHub
  policy-as-code, Datadog/OTel, Vanta.
- [references/receipts.md](references/receipts.md) — the Action Receipt schema,
  quorum semantics, a worked L1 example.
- [references/verification.md](references/verification.md) — the verify gates, the
  verdict tags, canonicalization, where it runs.
- [references/cli-and-api.md](references/cli-and-api.md) — the `heso` CLI + the
  cloud HTTP API (`/v1/commitments`).
- Live docs: https://heso.ca/docs
