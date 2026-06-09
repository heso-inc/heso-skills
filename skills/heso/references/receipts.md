# Action Receipt schema

One Action Receipt records exactly one action: what the agent did, the policy
verdict that gated it, who approved it (if anyone), redaction markers, and a hash
that locks the bytes. The shapes are the single source of truth in the Rust core —
the Python wheel, the Node addon, and the browser WASM all read the same structure,
so a receipt made on one runtime verifies byte-for-byte on another. Every field is
snake_case on the wire.

## ActionReceipt (envelope)

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `alg` | `"heso-action/v2+ed25519"` | ✓ | Algorithm tag. Checked first; unknown → `WrongAlgorithm`. |
| `content` | `ActionContent` | ✓ | The signed body — everything the signatures cover. |
| `signatures` | `SignatureEntry[]` | ✓ | Ed25519 signatures over the canonical content. Operator always; approver at L1. |
| `transparency` | `unknown[]` | | Optional RFC-6962 Merkle inclusion/consistency proofs (SHA-256). Absent until logged. |

## ActionContent (the signed body)

Canonicalized with **RFC-8785 (JCS)**, with `action_hash` removed before hashing.
That canonical form is what every signature covers and what `action_hash` is the
BLAKE3 digest of.

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `action_version` | `"heso-action/2.0"` | ✓ | Schema version. Unknown → `Unsupported`. |
| `captured_at` | string (ISO-8601) | ✓ | When the action was captured, before the policy decision. |
| `agent_identity` | string | ✓ | Operator public key, base64 — the identity that signs. |
| `action` | `ActionDetail` | ✓ | What the agent did (below). |
| `policy` | `PolicyOutcome` | ✓ | The rule that matched and the path taken (below). |
| `approver_decision` | `ApproverRecord` | | Present on a **single-approver** L1 (one human). Mutually exclusive with `multi_approval` — both present → `Malformed`. |
| `multi_approval` | `MultiApproval` | | Present on a **quorum** (k-of-n) L1 (below). The block — never the level — distinguishes a quorum L1 from a single-approver L1; both re-derive to L1. |
| `time_anchor` | `unknown` | | Optional RFC-3161 TSA token binding when the assembled post-approval body existed. Absent ⇒ no trusted time. Present-but-bad → `TimeAnchorUnverifiable`. |
| `anchor_policy` | `"Required"` | | Signed marker that trusted time is required for this lane. If `Required` and `time_anchor` is absent → `AnchorRequired` (the offline verifier rejects it). |
| `redaction` | `RedactionRecord` | | Present when fields were redacted before signing (below). |
| `trust_level` | `"L0" \| "L1"` | ✓ | Claimed trust. Re-derived on verify; mismatch → `TrustLevelMismatch`. No L2/L3. L1 has two shapes — single-approver (`approver_decision`) and quorum (`multi_approval`) — told apart by which block is present, **never** by the level. |
| `action_hash` | string | ✓ | BLAKE3 of the canonical content, lowercase 64-hex. Recomputed on verify; differ → `HashMismatch`. Stripped before hashing. |

**v2 signed-content (reserved-absent).** A standalone receipt omits these and
canonicalizes byte-identically to one minted before they existed, but `content`
may also carry: a chain block (`session_id`, `seq`, `prev_receipt_hash`), a
trusted-time `time_anchor` (RFC-3161 → `TimeAnchorUnverifiable` if present and
bad) and its `anchor_policy` requirement (`Required` + no anchor → `AnchorRequired`),
a quorum `multi_approval` block (k-of-n → still L1), descriptive `action.domain` /
`action.action` labels, a re-derivable `action.ert` (classification), a payment
`action.mandate`, a `guardrail` record, and the suspend/resume `kind` /
`suspension` / `key_rotation`. All are signed; the coarse `verb` stays the
authoritative lane every decision keys on.

## ActionDetail

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `verb` | `Verb` | ✓ | One of `llm_call`, `tool_call`, `http_request`, `payment`, `data_export`, `account_change`, `delete`. |
| `tool_name` | string | ✓ | The tool/method invoked, e.g. `stripe.transfers.create`. |
| `target_host` | string | | Destination host. Omitted for `llm_call` and other host-less actions. |
| `workflow` | string | ✓ | The workflow this action belongs to (a policy subject can scope to it). |
| `account` | string | ✓ | The account the action ran under. |
| `fields` | `Record<string,string>` | ✓ | The action arguments, **post-redaction**. Any redacted field is already removed/replaced before signing. |
| `result_hash` | string | | Optional hash of the action result, when captured. |
| `error` | string | | Optional error, when the action failed. |

`fields` records the inputs the agent passed and the policy that gated them — not
whether the call succeeded downstream.

## PolicyOutcome

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `rule_id` | string | ✓ | Id of the matched rule. |
| `rule_display` | string | ✓ | The rule's plain-English sentence, e.g. "Require approval to pay over $5,000". |
| `matched_conditions` | `MatchedCondition[]` | ✓ | The rule conditions that evaluated true. |
| `decision_path` | `DecisionPath` | ✓ | `allow` \| `block` \| `redact` \| `require_approval`. |

`MatchedCondition` = `{ field: string, op: ConditionOp, value: JSON }`. `op` is one
of `gt`, `lt`, `gte`, `lte`, `eq`, `neq`, `in`, `not_in`, `exists`, `matches`.
Numeric ops carry a number; `in`/`not_in` carry a string array; `exists` ignores
its value.

## SignatureEntry

The operator entry is always present; the approver entry is present at L1. The
approver signs with their own device-held key — the cloud holds no signing key.

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `algorithm` | `"Ed25519"` | ✓ | Always Ed25519. |
| `key_id` | `"operator" \| "approver"` | ✓ | Which key produced the signature. |
| `public_key` | string | ✓ | Signing public key, base64. The verifier checks against this. |
| `signature` | string | ✓ | Ed25519 signature over the canonical content, base64. Bad operator sig → `InvalidSignature`; bad approver sig → `InvalidSignature` (or `SelfApproval` if the approver key equals the operator's). |

## ApproverRecord (`content.approver_decision`)

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `decision` | `"approved" \| "rejected" \| "escalated"` | ✓ | What the human decided. |
| `approver_identity` | string | ✓ | Approver public key, base64 — same key as the approver signature. |
| `reason` | string | ✓ | The reason given. |
| `decided_at` | string (ISO) | ✓ | When the approver claims they decided. **Approver-claimed**: bound only by that approver's own co-signature, never certified by a TSA. In a quorum it is bound *solely* by that one approver's leg — the operator does not sign over it. |
| `sla_minutes` | number | | The SLA window the decision was expected within. |

## MultiApproval (`content.multi_approval`)

Present on a **quorum** (k-of-n) L1 receipt instead of `approver_decision`.

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `threshold` | number | ✓ | How many distinct roster keys must co-sign (the `k` in k-of-n). The operator signs over it, so it can't be lowered after the fact. |
| `roster` | string[] | ✓ | The sorted set of eligible approver public keys (base64) the operator signed over. An approver whose key is not on the roster is rejected (`Malformed`). |
| `approvers` | `ApproverRecord[]` | ✓ | One record per approver who signed (same shape as `approver_decision`), sorted ascending by `approver_identity`. **Empty** in the operator base; the full `k`-element set on the wire. |

The operator signs an **emptied-approvers base** (action + `threshold` + sorted
`roster`) — *not* the individual approver records. Each approver's own
co-signature is a separate `signatures[]` entry with `key_id: "approver"` (so a
2-of-3 quorum has one operator entry plus two approver entries), and each is bound
solely by that approver's own signature over the base-plus-only-their-own-record.
A quorum re-derives to **L1** when ≥ `threshold` distinct roster keys verify; fewer
→ `ThresholdNotMet`.

## RedactionRecord (`content.redaction`)

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `mode` | `"destructive" \| "commit_and_reveal"` | ✓ | `destructive` drops the value; `commit_and_reveal` keeps a hash commitment so the value can be revealed and checked later. |
| `markers` | `RedactionMarker[]` | ✓ | One marker per redacted field. |
| `merkle_root` | string | | Merkle root over the commitments. Present only in `commit_and_reveal`. |

`RedactionMarker` = `{ field_path: string, algorithm: "blake3", commitment: string }`.
`field_path` e.g. `action.fields.member_id`. `commitment` is a 64-hex BLAKE3
digest in `commit_and_reveal` mode, or an **empty string** in `destructive` mode —
never omitted. A malformed marker → `MalformedRedaction`.

## Worked example — an L1 payment receipt

Over the approval cap, routed to a human and approved, one field redacted with a
commitment before signing. Carries both operator and approver signatures.

```json
{
  "alg": "heso-action/v2+ed25519",
  "content": {
    "action_version": "heso-action/2.0",
    "captured_at": "2026-06-06T14:22:09Z",
    "agent_identity": "ed25519:uP3…b1",
    "action": {
      "verb": "payment",
      "tool_name": "stripe.transfers.create",
      "target_host": "api.stripe.com",
      "workflow": "vendor-payouts",
      "account": "acct_19",
      "fields": { "amount_usd": "12500", "payee": "Globex LLC", "member_id": "[redacted]" },
      "result_hash": "7c41…9ab2"
    },
    "policy": {
      "rule_id": "pay-cap",
      "rule_display": "Require approval to pay over $5,000",
      "matched_conditions": [ { "field": "amount_usd", "op": "gt", "value": 5000 } ],
      "decision_path": "require_approval"
    },
    "approver_decision": {
      "decision": "approved",
      "approver_identity": "ed25519:mK7…c4",
      "reason": "Verified invoice INV-2207 against the PO.",
      "decided_at": "2026-06-06T14:25:41Z",
      "sla_minutes": 60
    },
    "redaction": {
      "mode": "commit_and_reveal",
      "markers": [ { "field_path": "action.fields.member_id", "algorithm": "blake3", "commitment": "b9e0…f72d" } ],
      "merkle_root": "1f88…a330"
    },
    "trust_level": "L1",
    "action_hash": "9f2c…e1c0"
  },
  "signatures": [
    { "algorithm": "Ed25519", "key_id": "operator", "public_key": "ed25519:uP3…b1", "signature": "3a9f…04af" },
    { "algorithm": "Ed25519", "key_id": "approver", "public_key": "ed25519:mK7…c4", "signature": "d710…5b2e" }
  ]
}
```

To check it: recompute `action_hash` over the canonical content, verify both
Ed25519 signatures, confirm the redaction markers are well-formed, and re-derive
the trust level from the signatures that passed. See
[verification.md](verification.md).

## Worked example — a 2-of-3 quorum receipt

A payment gated to require **2 of 3** approvers. The receipt uses `multi_approval`
instead of `approver_decision`, and carries one operator signature plus two approver
signatures. It is still `trust_level: "L1"` — a quorum is **not** a higher level.

```json
{
  "alg": "heso-action/v2+ed25519",
  "content": {
    "action_version": "heso-action/2.0",
    "captured_at": "2026-06-06T14:22:09Z",
    "agent_identity": "ed25519:uP3…b1",
    "action": { "verb": "payment", "tool_name": "stripe.transfers.create", "target_host": "api.stripe.com", "workflow": "vendor-payouts", "account": "acct_19", "fields": { "amount_usd": "50000", "payee": "Globex LLC" } },
    "policy": { "rule_id": "pay-cap-hi", "rule_display": "Require 2 approvers to pay over $25,000", "matched_conditions": [ { "field": "amount_usd", "op": "gt", "value": 25000 } ], "decision_path": "require_approval" },
    "multi_approval": {
      "threshold": 2,
      "roster": [ "ed25519:aa1…", "ed25519:bb2…", "ed25519:cc3…" ],
      "approvers": [
        { "decision": "approved", "approver_identity": "ed25519:aa1…", "reason": "Matched PO-8841.", "decided_at": "2026-06-06T14:25:41Z", "sla_minutes": 120 },
        { "decision": "approved", "approver_identity": "ed25519:bb2…", "reason": "Vendor on file; ok.", "decided_at": "2026-06-06T14:31:02Z", "sla_minutes": 120 }
      ]
    },
    "trust_level": "L1",
    "action_hash": "4d7a…0e55"
  },
  "signatures": [
    { "algorithm": "Ed25519", "key_id": "operator", "public_key": "ed25519:uP3…b1", "signature": "9c01…aa3f" },
    { "algorithm": "Ed25519", "key_id": "approver", "public_key": "ed25519:aa1…", "signature": "1f22…77b0" },
    { "algorithm": "Ed25519", "key_id": "approver", "public_key": "ed25519:bb2…", "signature": "ab90…41ce" }
  ]
}
```

The operator signature covers the **emptied-approvers base** — action + `threshold`
+ sorted `roster` — so it vouches for *which keys are eligible and how many must
sign*, but for **nothing** about either approver's `reason` or `decided_at`. Each
approver signature covers the base plus only its own record. The verifier re-derives
**L1** because 2 distinct roster keys (`aa1…`, `bb2…`) each signed; only 1 would
fail `ThresholdNotMet:have=1,need=2`.
