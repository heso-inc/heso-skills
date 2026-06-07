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
| `alg` | `"heso-action/v2+ed25519"` | ✓ | Algorithm tag. Checked first; unknown → `wrong_algorithm`. |
| `content` | `ActionContent` | ✓ | The signed body — everything the signatures cover. |
| `signatures` | `SignatureEntry[]` | ✓ | Ed25519 signatures over the canonical content. Operator always; approver at L1. |
| `transparency` | `unknown[]` | | Optional RFC-6962 Merkle inclusion/consistency proofs (SHA-256). Absent until logged. |

## ActionContent (the signed body)

Canonicalized with **RFC-8785 (JCS)**, with `action_hash` removed before hashing.
That canonical form is what every signature covers and what `action_hash` is the
BLAKE3 digest of.

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `action_version` | `"heso-action/2.0"` | ✓ | Schema version. Unknown → `unsupported_version`. |
| `captured_at` | string (ISO-8601) | ✓ | When the action was captured, before the policy decision. |
| `agent_identity` | string | ✓ | Operator public key, base64 — the identity that signs. |
| `action` | `ActionDetail` | ✓ | What the agent did (below). |
| `policy` | `PolicyOutcome` | ✓ | The rule that matched and the path taken (below). |
| `approver_decision` | `ApproverRecord` | | Present when routed to a human (below). |
| `redaction` | `RedactionRecord` | | Present when fields were redacted before signing (below). |
| `trust_level` | `"L0" \| "L1"` | ✓ | Claimed trust. Re-derived on verify; mismatch → `trust_mismatch`. No L2/L3. |
| `action_hash` | string | ✓ | BLAKE3 of the canonical content, lowercase 64-hex. Recomputed on verify; differ → `hash_mismatch`. Stripped before hashing. |

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
| `signature` | string | ✓ | Ed25519 signature over the canonical content, base64. Bad operator sig → `invalid_signature`; bad approver sig → `invalid_approver`. |

## ApproverRecord (`content.approver_decision`)

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `decision` | `"approved" \| "rejected" \| "escalated"` | ✓ | What the human decided. |
| `approver_identity` | string | ✓ | Approver public key, base64 — same key as the approver signature. |
| `reason` | string | ✓ | The reason given. |
| `decided_at` | string (ISO) | ✓ | When the decision was made. |
| `sla_minutes` | number | | The SLA window the decision was expected within. |

## RedactionRecord (`content.redaction`)

| Field | Type | Req | Meaning |
| --- | --- | --- | --- |
| `mode` | `"destructive" \| "commit_and_reveal"` | ✓ | `destructive` drops the value; `commit_and_reveal` keeps a hash commitment so the value can be revealed and checked later. |
| `markers` | `RedactionMarker[]` | ✓ | One marker per redacted field. |
| `merkle_root` | string | | Merkle root over the commitments. Present only in `commit_and_reveal`. |

`RedactionMarker` = `{ field_path: string, algorithm: "blake3", commitment: string }`.
`field_path` e.g. `action.fields.member_id`. `commitment` is a 64-hex BLAKE3
digest in `commit_and_reveal` mode, or an **empty string** in `destructive` mode —
never omitted. A malformed marker → `redaction_malformed`.

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
