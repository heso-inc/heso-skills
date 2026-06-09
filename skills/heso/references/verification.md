# Offline verification

Verification is what makes a receipt evidence. The same Rust core that signs a
receipt verifies it, and it runs **locally** — in Node, in a browser, in Python —
with no network call and no trust in HESO. Everything needed to check a receipt
lives inside the receipt: the canonical content, the public keys, the signatures,
and the claimed trust level. You should never have to trust HESO to believe a
receipt.

```ts
// Node
import { verify } from "@hesohq/core"
const r = verify(receiptBytes)        // { verdict, trustLevel }

// Browser — await init() once first
import init, { verifyActionReceipt } from "@hesohq/verify-wasm"
await init()
const v = verifyActionReceipt(bytes)  // { verdict, trust_level }
```

```python
from heso._core import verify_action_receipt
result = verify_action_receipt(receipt_json)   # { "kind", "detail", "trust_level" }
result["kind"]   # "Valid" | "HashMismatch" | ...
```

## The gates (in order)

The verifier walks these top to bottom and stops at the **first** failure,
reporting one verdict. It does not collect every problem — it names the earliest
defect, so two verifiers given the same receipt agree on the same single answer.
The seven core gates run on every receipt; gates 8–11 run only when the signed
field that triggers them is set (gate 9 fires when `anchor_policy = Required` and no
anchor is present). Passing yields `Valid`.

| # | Gate | Checks | Fail verdict |
| --- | --- | --- | --- |
| 1 | Algorithm recognized | `alg == "heso-action/v2+ed25519"` | `WrongAlgorithm` |
| 2 | Version recognized | `action_version == "heso-action/2.0"` | `Unsupported` |
| 3 | Hash recomputes | BLAKE3 of canonical bytes == embedded `action_hash` | `HashMismatch` |
| 4 | Operator signature verifies | Ed25519 under `key_id:"operator"` vs operator key | `InvalidSignature` / `Malformed` |
| 5 | Approver signature(s) verify | Single-approver: Ed25519 vs approver key, AND approver ≠ operator. Quorum (`multi_approval`): every leg verifies under the co-sign domain against a **distinct roster key** | `InvalidSignature` / `SelfApproval` / `Malformed` |
| 6 | Redaction markers well-formed | Markers structurally valid for their mode | `MalformedRedaction` |
| 7 | Trust re-derives | Level derived from passing signatures == claimed `trust_level`. Quorum re-derives to **L1** only when **≥ `threshold`** distinct legs verify | `TrustLevelMismatch` / `ThresholdNotMet` |
| 8 | Trusted-time anchor (if present) | RFC-3161 anchor verifies vs a pinned TSA root | `TimeAnchorUnverifiable` |
| 9 | Trusted-time required | Signed `anchor_policy = Required` but **no** `time_anchor` present | `AnchorRequired` |
| 10 | Payment mandate (if present) | A `payment`'s mandate binding is not invalid/absent | `MandateRejected` |
| 11 | Classification (re-deriving verify only) | Signed ERT replays from its facts | `ClassificationMismatch` / `TaxonomyUnavailable` |

Because trust is the **last core** gate and is re-derived rather than read, a
receipt can never claim more than its signatures support. A receipt with both a
tampered field and a bad signature reports `HashMismatch` (gate 3 comes first).

**Quorum re-derivation (gates 5 + 7).** When the receipt carries a `multi_approval`
block, the operator signature is checked over the *emptied-approvers base* (action +
`threshold` + sorted `roster`), and each approver leg is verified separately under
the co-sign domain. A leg must be a **distinct roster key** — a re-used key or a
non-roster key fails. Trust re-derives to **L1** (with the `multi_approval` block,
never a higher level) only when **≥ `threshold`** distinct legs verify; fewer fails
`ThresholdNotMet` (which carries the counts, e.g. `ThresholdNotMet:have=1,need=2`).

**`AnchorRequired` (gate 9).** Separate from `TimeAnchorUnverifiable` (a *present*
anchor that fails to verify): if the receipt's signed `anchor_policy` is `Required`
and it carries **no** `time_anchor`, the **offline verifier itself** rejects it with
`AnchorRequired` — the requirement is enforced at verify, not only at the server.
The anchorless-by-default posture (`anchor_policy` unset) is unaffected.

## Verdict strings

All SDK surfaces return the **PascalCase engine tag**: `Valid`,
`WrongAlgorithm:…`, `Unsupported:…`, `HashMismatch`, `InvalidSignature:…`,
`MalformedRedaction:…`, `TrustLevelMismatch:…`, `Malformed:…`, `SelfApproval`,
`ThresholdNotMet:…`, `TimeAnchorUnverifiable:…`, `AnchorRequired`,
`MandateRejected:…`, `ClassificationMismatch:…`, `TaxonomyUnavailable:…`
(`AnchorRequired` carries no detail; `ThresholdNotMet` carries `have`/`need`).
Node (`verify`) and the browser WASM
(`verifyActionReceipt`) put it on `result.verdict`; `@hesohq/sdk`'s `gate()`
returns it verbatim on `GateResult.verdict`; the Python wheel returns it as the
`kind` of a `{ kind, detail, trust_level }` dict. There is **no**
`invalid_approver` verdict — a bad approver co-sign is `InvalidSignature`, and an
operator approving its own action is `SelfApproval`. The HESO console maps these
tags to friendlier snake_case copy for display, but the tag is the contract you
branch on.

## Byte-for-byte canonicalization

Gate 3 only works if everyone agrees which bytes to hash. HESO fixes those bytes
with **RFC-8785 (JCS)** canonicalization: keys sorted, output normalized, so the
same content always produces the same bytes. The `action_hash` field is stripped
before hashing — you cannot hash a value into itself.

**Never write your own canonicalizer.** Your own JCS that orders keys or formats
numbers even slightly differently produces different bytes, a different BLAKE3
hash, and a false `HashMismatch` on a receipt that is actually valid. Always
route through the core — `@hesohq/core`, `@hesohq/verify-wasm`, or the Python `heso`
package. Never rebuild canonical bytes by hand. The browser must call the shared
Rust canonicalizer, not JS code.

When the cloud accepts a receipt at `POST /v1/receipts` it re-verifies through
this same core before storing — the server is not a more-trusted verifier; it runs
the identical gates you can run locally.

## Chains and transparency

Beyond single receipts, the core verifies hash-linked chains and the transparency
log:

- `verifyChain` / `verifySessionChain` — a BLAKE3 hash-linked sequence; a break
  reports the sequence index that failed.
- `verifySessionChainWithRotation(receipts, producerKey, decisionKey?)` — chains
  across a key rotation (TOFU producer key).
- `verifyInclusion` / `verifyConsistency` — RFC-6962 Merkle proofs (SHA-256) that
  a receipt is in the transparency log and that the log only ever appended.

Separate from chain-level rotation: at **finalize** time, if the operator key
rotated between suspend and finalize, the in-core assemble fails closed (an
`OperatorKeyMismatch`) rather than mint under a stale key. The SDK re-suspends the
action under the new key (a fresh suspended L0 with a new `action_hash`) and the
approval re-opens against it. The stale human co-sign cannot be replayed against the
new base.

`verifyWithTime(bytes)` returns the receipt verdict **plus** a trusted-time status:
`"NoTrustedTime"` when anchorless (the default), or `"AnchoredRfc3161:<gen_time>"`
when a verifiable anchor is present. Read `gen_time` as an existed-no-later-than
bound on the assembled (post-approval) body — **not** when a human decided. A
*present* anchor that fails to verify sinks the whole receipt (`TimeAnchorUnverifiable`).

## What a `Valid` verdict means

Exactly two things, both re-derived from the artifact: (1) the bytes are the bytes
the operator signed, unaltered; (2) the re-derived trust level matches the claim —
so the operator authorized this action under a known policy, and at L1 a human
approved it with their own device-held key. It records **what was authorized, not
the downstream outcome**. A valid receipt for a tool call proves the operator
authorized that call — separate from whether the tool returned correct data or a
payment settled.

For a **quorum** (`multi_approval`) L1, `Valid` means narrower per approver: ≥
`threshold` distinct roster keys each co-signed their **own** leg, and the operator
authorized the action under that threshold + roster. It does **not** mean the
operator (or the group) vouches for any single approver's stated `reason` or
`decided_at` — the operator signed an emptied-approvers base and never signed over
those. Read a quorum as "the operator authorized this under this threshold/roster,
and k distinct approvers each signed", not as a group attestation of any one
approver's reasoning.
