# TypeScript / Node reference (`@heso/sdk`)

`@heso/sdk` (Node ≥ 18, CommonJS) is the surface for **verifying** receipts and
talking to the cloud control plane. It is a thin wrapper over the native
`@heso/core`, so a verdict here is byte-identical to a reviewer's browser. There
is **no Node capture/decorator surface** — gating an agent is the Python SDK's
job. `@heso/core` ships prebuilt native binaries (darwin/linux/win) as
optionalDependencies, so there is no compile step.

```bash
pnpm add @heso/sdk     # npm i @heso/sdk · yarn add @heso/sdk
```

## Local verification (no config, no network)

```ts
import { gate, assertGate, isDecisionAllowed, shortHash } from "@heso/sdk"

const r = gate(receiptBytes, "L0")     // GateResult — verifies bytes locally
r.allowed      // boolean — verifies AND meets the minimum trust level
r.trustLevel   // "L0" | "L1" | null  (null when verification fails before a level)
r.verdict      // "valid" | "hash_mismatch" | "invalid_signature" | ...

assertGate(receiptBytes, "L1")          // throws unless valid AND human co-signed
applyTransfer()

const receipt: ActionReceipt = JSON.parse(receiptJson)
isDecisionAllowed(receipt, ["allow", "redact"])  // branch on policy, not crypto

shortHash(hex, "rcpt")  // "rcpt:9f2c4e7a" — display helper
```

- `gate(receiptBytes: Buffer | string, minTrust?: TrustLevel = "L0"): GateResult`
- `assertGate(receiptBytes: Buffer | string, minTrust?: TrustLevel = "L0"): void`
- `isDecisionAllowed(receipt: ActionReceipt, allowed: DecisionPath[]): boolean`

Trust is re-derived on every verify from the signatures that pass. Never read
`trustLevel` off parsed JSON — get it from `gate()`.

## Gate a client automatically — `wrap`

`wrap` returns a Proxy around a client. After each method it looks for a
`__heso_receipt` field on the result and gates it against `minTrust`. **It only
gates methods that attach a receipt** — methods without `__heso_receipt` pass
through unguarded.

```ts
import { wrap, pushReceipt } from "@heso/sdk"

const guarded = wrap(agentClient, {
  minTrust: "L1",
  onReceipt: async (method, receiptJson) => { await pushReceipt(JSON.parse(receiptJson)) },
  onGateFail: (method, verdict) => { console.error(`${method}: ${verdict}`); return false },
})
const out = await guarded.transfer({ amountUsd: 4200 })
```

`WrapOptions`: `minTrust?: TrustLevel`,
`onReceipt?: (method, receiptJson) => void | Promise<void>`,
`onGateFail?: (method, verdict) => boolean | Promise<boolean>` (return `true` to
swallow the failure, `false` to re-throw).

## Cloud client

`configure(apiKey: string, endpoint: string): void` once at startup, before any
cloud call. Local `gate`/`assertGate` need no config.

| Method | HTTP | Returns |
| --- | --- | --- |
| `pullPolicy(teamId)` | GET `/v1/teams/{teamId}/policy` | `{ version, rules[], fetchedAt }` |
| `pushReceipt(receipt)` | POST `/v1/receipts` | `OutboxPushResult` |
| `pushReceipts(receipts[])` | POST `/v1/receipts/batch` | `OutboxPushResult[]` |
| `openApproval({ receipt, routingHint? })` | POST `/v1/approvals` | `{ approvalId, token?, expiresAt }` |
| `pollApproval(approvalId)` | GET `/v1/approvals/{approvalId}` | `{ outcome, approval? }` |
| `waitForApproval(approvalId, { pollIntervalMs?, timeoutMs? })` | polls | `Approval` or throws |
| `submitApprovalToken(approvalId, token)` | POST `/v1/approvals/{approvalId}/token` | `Approval` |

`waitForApproval` defaults: `pollIntervalMs = 2000`, `timeoutMs = 300000`.

```ts
import { pushReceipt } from "@heso/sdk"
const result = await pushReceipt(JSON.parse(receiptJson))
if (!result.accepted) throw new Error(result.rejectionReason ?? "receipt rejected")
result.receiptId
```

The server **re-verifies** every receipt before accepting — a tampered or
under-signed receipt is rejected at the control plane (HTTP 422), not just
locally.

`OutboxPushResult`: `{ receiptId: string, accepted: boolean, rejectionReason?: string }`.

## Exported types

`ActionReceipt`, `ActionContent`, `ActionDetail`, `PolicyOutcome`,
`SignatureEntry`, `PolicyRule`, `Approval`, `GateResult`, `OutboxPushResult`,
`TrustLevel` (`"L0" | "L1"`), `Verb`, `DecisionPath`
(`"allow" | "block" | "redact" | "require_approval"`), `ConditionOp`
(`gt`/`lt`/`gte`/`lte`/`eq`/`neq`/`in`/`not_in`/`exists`/`matches`).

## Raw primitives — `@heso/core`

When you need the primitives directly (alias `@heso/node`):

- `verify(bytes): { verdict, trustLevel }`, `verifyWithTime(bytes)` (adds RFC-3161
  time status).
- Hashing/canonicalization: `contentHash`, `anchoredContentHashJs`,
  `actionCanonicalBytesJs`, `chainHashHex`, `shortHash`.
- Chains: `verifyChain`, `verifySessionChainJs`,
  `verifySessionChainWithRotationJs`, `verifyAuditChain`.
- Transparency (RFC-6962 Merkle): `verifyInclusionJs`, `verifyConsistencyJs`.
- Approval tokens: `verifyApprovalToken`.
- Redaction: `redactDestructiveJs`, `redactCommitJs`.
- Keys (Ed25519): `keyFromSeed(seed)`, `generateKey()`, `OperatorKey`.

## Honesty boundary

Accepting a receipt proves the operator authorized the action under a known
policy, and at L1 that a person approved it with a device-held key. It records
what was authorized, **not** whether the action succeeded downstream. The cloud
holds no signing key; it only re-checks signatures already on the receipt.
