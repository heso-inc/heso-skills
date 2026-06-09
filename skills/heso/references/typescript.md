# TypeScript / Node reference (`@hesohq/sdk`)

`@hesohq/sdk` (Node ≥ 18, CommonJS) does two jobs: it **gates and signs** an
agent's actions in-process, and it **verifies** receipts and talks to the cloud
control plane. Zero crypto in TS — it binds to the native `@hesohq/core` (verify)
and `@hesohq/node` (mint), so a verdict here is byte-identical to a reviewer's
browser. `@hesohq/core` ships prebuilt native binaries (darwin/linux/win) as
optionalDependencies; minting needs `@hesohq/node` built with the `process`
feature (loaded lazily, so verify-only deployments never need it).

```bash
pnpm add @hesohq/sdk          # verify + cloud
pnpm add @hesohq/node         # also gate/mint (optional; the native addon)
```

## Gate an agent (Node)

Call `init()` once, then gate tool calls — via a framework adapter or the
`engine` capture core. The native addon mints; a blocked/suspended action throws.

```ts
import { init, engine, SuspendedError } from "@hesohq/sdk"
import { gateTool, gateTools } from "@hesohq/sdk/adapters/ai-sdk" // or .../mastra

init({ workflow: "vendor-payouts", account: "acct_19" })

// Vercel AI SDK: gate a tool's execute BEFORE it runs.
const tools = { search: gateTool("search", tool({ inputSchema, execute })) }

// ...or the engine core directly:
const action = engine.gate("transfer_funds", { amountUsd: 4200 }, { verb: "payment" })
const result = await transferFunds({ amountUsd: 4200 })
engine.recordResult(action, result)         // bind result to a follow-up receipt
```

- `init(options?)` — engine runtime config (projectRoot/workflow/account/
  clockOverride/blocking); resolves explicit → `HESO_*` env → discovery → default.
  `currentConfig()` reads it back.
- `engine.gate(toolName, input, opts?)` — capture + drive + ENFORCE (throws
  `BlockedError` / `SuspendedError`). `engine.evaluate(...)` — capture without
  enforcing → `{ outcome, action }`. `engine.recordResult(action, output)`.
- Adapters: `aiSdk.gateTool` / `aiSdk.gateTools`, `mastra.*` — thin wrappers over
  the engine core (also at `@hesohq/sdk/adapters/*`).
- **Two-phase approval:** `engine.gate` throws `SuspendedError(actionHash)`; out of
  band, `waitForApproval(actionHash)` → `finalizeL1(parts.suspendedContent, parts)`
  assembles + mirrors the L1. A rejected decision throws `ApprovalRejectedError`.

The deepest capture surface is still the Python SDK (more adapters, suspend/
resume); on Node the same one Rust core does the work.

## Local verification (no config, no network)

```ts
import { gate, assertGate, isDecisionAllowed, shortHash } from "@hesohq/sdk"

const r = gate(receiptBytes, "L0")     // GateResult — verifies bytes locally
r.allowed      // boolean — verifies AND meets the minimum trust level
r.trustLevel   // "L0" | "L1" | null  (null when verification fails before a level)
r.verdict      // engine tag: "Valid" | "HashMismatch" | "TrustLevelMismatch" | ...

assertGate(receiptBytes, "L1")          // throws unless valid AND human co-signed

const receipt: ActionReceipt = JSON.parse(receiptJson)
isDecisionAllowed(receipt, ["allow", "redact"])  // branch on policy, not crypto

shortHash(hex, "rcpt")  // "rcpt:9f2c4e7a" — display helper
```

- `gate(receiptBytes: Buffer | string, minTrust?: TrustLevel = "L0"): GateResult`
- `assertGate(receiptBytes: Buffer | string, minTrust?: TrustLevel = "L0"): void`
- `isDecisionAllowed(receipt: ActionReceipt, allowed: DecisionPath[]): boolean`

`GateResult.verdict` is the PascalCase engine tag (`gate()` returns it verbatim
from the native `verify`), NOT a snake_case string. Trust is re-derived on every
verify — never read `trustLevel` off parsed JSON; get it from `gate()`.

## Verify-on-response proxy — `wrap`

`wrap` returns a Proxy around a client. After each method it looks for a
`__heso_receipt` field on the result and VERIFIES it against `minTrust` (distinct
from `engine.gate`, which captures + mints your own actions). Methods without
`__heso_receipt` pass through unguarded.

```ts
import { wrap, pushReceipt } from "@hesohq/sdk"

const guarded = wrap(agentClient, {
  minTrust: "L1",
  onReceipt: async (method, receiptJson) => { await pushReceipt(JSON.parse(receiptJson)) },
  onGateFail: (method, verdict) => { console.error(`${method}: ${verdict}`); return false },
})
```

`WrapOptions`: `minTrust?: TrustLevel`,
`onReceipt?: (method, receiptJson) => void | Promise<void>`,
`onGateFail?: (method, verdict) => boolean | Promise<boolean>` (return `true` to
swallow the failure, `false` to throw).

## Cloud client

`configure(apiKey: string, endpoint: string): void` once at startup, before any
cloud call (separate from `init()`, which configures local minting). The org is
resolved from the api-key — there is **no team id**; approvals are keyed by
`action_hash`. Local `gate`/`assertGate` need no config.

| Method | HTTP | Returns |
| --- | --- | --- |
| `pullPolicy()` | GET `/v1/policy/pull` | `{ status, policyId, policyHash, toml }` |
| `pushReceipt(receipt, supersedesActionHash?)` | POST `/v1/receipts` | `ReceiptPushResult` |
| `pushReceipts(receipts[])` | loops POST `/v1/receipts` | `ReceiptPushResult[]` |
| `pollApproval(actionHash)` | GET `/v1/approvals/{action_hash}` | `ApprovalView` |
| `waitForApproval(actionHash, { pollIntervalMs?, timeoutMs? })` | polls (+ l1-parts on approval) | `ResolvedApproval` or throws |
| `getL1Parts(actionHash)` | GET `/v1/approvals/{action_hash}/l1-parts` | `L1Parts` |
| `submitApprovalToken(actionHash, input)` | POST `/v1/approvals/{action_hash}/submit-token` | `ApprovalView` |

`waitForApproval` defaults: `pollIntervalMs = 2000`, `timeoutMs = 300000`. There
is **no batch route** — `pushReceipts` loops. `submitApprovalToken`'s `input` is a
`SubmitTokenInput` (`{ tokenB64, actionContent, requiredScope?, decision?, ... }`),
not a bare token string.

```ts
const result = await pushReceipt(JSON.parse(receiptJson))
result.status     // "appended" | "duplicate" | "quota_exceeded"
result.entryHash  // echoes the receipt's action_hash
result.seq        // the mirror's per-org append position
```

`ReceiptPushResult`: `{ status: "appended" | "duplicate" | "quota_exceeded",
entryHash: string, seq: number }`. The server **re-verifies** every receipt before
mirroring — a tampered body is rejected at the control plane, not just locally.

Client-approval (delegation): `signDelegation` / `mintDelegationEnvelope` mint an
operator delegation envelope so a customer co-signs from their own browser.

## Exported types

`ActionReceipt`, `ActionContent`, `ActionDetail`, `PolicyOutcome`,
`SignatureEntry`, `PolicyRule`, `Approval`, `GateResult`, `ReceiptPushResult`,
`ApprovalView`, `L1Parts`, `Outcome`, `Action`, `TrustLevel` (`"L0" | "L1"`),
`Verb`, `DecisionPath` (`"allow" | "block" | "redact" | "require_approval"`),
`ConditionOp` (the receipt subset).

## Raw primitives — `@hesohq/core`

When you need the primitives directly (`@hesohq/core` re-exports the native
`@hesohq/node`):

- `verify(bytes): { verdict, trustLevel }`, `verifyWithTime(bytes)` (adds RFC-3161
  time status), `verifyRederiving(bytes)` (replays the signed classification).
- Hashing/canonicalization: `contentHash`, `anchoredContentHashJs`,
  `actionCanonicalBytesJs`, `chainHashHex`, `shortHash`, `blake3Hex`.
- Chains: `verifyChain`, `verifySessionChainJs`,
  `verifySessionChainWithRotationJs`, `verifyAuditChain`.
- Transparency (RFC-6962 Merkle): `verifyInclusionJs`, `verifyConsistencyJs`.
- Approval / delegation: `verifyApprovalToken`, `verifyDelegation`.
- Redaction: `redactDestructiveJs`, `redactCommitJs`.
- Keys (Ed25519): `keyFromSeed(seed)`, `generateKey()`, `OperatorKey`.
- Minting (process feature): `processAction`, `assembleL1FromParts`.

## Honesty boundary

A receipt proves the operator authorized the action under a known policy, and at
L1 that a person approved it with a device-held key. It records what was
authorized, **not** whether the action succeeded downstream. The cloud holds no
signing key; it only re-checks signatures already on the receipt.
