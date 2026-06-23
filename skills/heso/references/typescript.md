# TypeScript / Node reference (`@hesohq/sdk`)

`@hesohq/sdk` (Node ≥ 18) does two jobs: it **gates and records** an agent's
actions in-process, and it **verifies** receipts and talks to the cloud. Zero
crypto in TS — it binds to the native `@hesohq/core` (verify) and `@hesohq/node`
(mint), so a verdict here is byte-identical to a reviewer's browser. `@hesohq/core`
ships prebuilt native binaries as optionalDependencies; minting needs
`@hesohq/node` (loaded lazily, so verify-only deployments never need it).

```bash
pnpm add @hesohq/sdk          # verify + cloud
pnpm add @hesohq/node         # also gate/mint (optional; the native addon)
```

There are **two capture surfaces** — the async **recorder** (off the hot path) and
the fail-closed **gate** (the egress interceptor that blocks). The conceptual split
and the two pillars (keys customer-side, redact-before-sign) live in
[recorder-and-gate.md](recorder-and-gate.md); this page is the Node API.

## Gate an agent (Node)

Call `init()` once, then gate tool calls — via a framework adapter or the `engine`
capture core. The native addon mints; a blocked/suspended action throws.

```ts
import { init, engine, SuspendedError } from "@hesohq/sdk"
import { gateTool, gateTools } from "@hesohq/sdk/adapters/ai-sdk" // or .../mastra

init({ workflow: "vendor-payouts", account: "acct_19" })

// Vercel AI SDK: gate a tool's execute BEFORE it runs.
const tools = { search: gateTool("search", tool({ inputSchema, execute })) }

// ...or the engine core directly:
const action = engine.gate("transfer_funds", { amountUsd: 4200 }, { verb: "payment" })
const result = await transferFunds({ amountUsd: 4200 })
engine.recordResult(action, result)         // bind result to a follow-up commitment
```

- `init(options?)` — engine runtime config (projectRoot/workflow/account/
  clockOverride/blocking); resolves explicit → `HESO_*` env → discovery → default.
  `currentConfig()` reads it back.
- `engine.gate(toolName, input, opts?)` — capture + classify-by-effect + ENFORCE
  (throws `BlockedError` / `SuspendedError`). The gate classifies against the
  [taxonomy](taxonomy.md) into a destructive primitive before signing.
  `engine.evaluate(...)` captures without enforcing → `{ outcome, action }`.
- Adapters: `aiSdk.gateTool` / `gateTools`, `mastra.*` — thin wrappers over the
  engine core. (Python is the lead binding with more adapters; on Node the same one
  Rust core does the work — see [python.md](python.md).)
- **Two-phase approval:** `engine.gate` throws `SuspendedError(actionHash)`; out of
  band, `waitForApproval(actionHash)` → `finalizeL1(suspendedContent, parts)`
  assembles the L1. A rejected decision throws `ApprovalRejectedError`.
- **Quorum (k-of-n):** `getQuorumParts(actionHash)` returns all relayed legs;
  `finalizeQuorum(suspendedContent, parts, opts?)` assembles a quorum receipt that
  re-derives to **L1 with a `multi_approval` block**. Under-quorum at verify is
  `ThresholdNotMet`. (Quorum semantics: [receipts.md](receipts.md).)

The co-sign / relay flow and the key-rotation fail-closed behavior are **one
canonical statement** in [SKILL.md](../SKILL.md) — TS exposes them via `getL1Parts`
/ `getQuorumParts` / `waitForApproval` (relayed parts), `finalizeL1` /
`finalizeQuorum` (re-mint + local re-verify before push), and
`finalizeQuorum(..., { loadedOperatorPubkeyB64, onKeyRotation })` (the proactive
rotation check + auto-re-suspend under a new key, `OperatorKeyMismatchError` /
`ReSuspendResult`).

## Local verification (no config, no network)

```ts
import { gate, assertGate, isDecisionAllowed, shortHash } from "@hesohq/sdk"

const r = gate(receiptBytes, "L0")     // GateResult — verifies bytes locally
r.allowed      // boolean — verifies AND meets the minimum trust level
r.trustLevel   // "L0" | "L1" | null
r.verdict      // engine tag: "Valid" | "HashMismatch" | "TrustLevelMismatch" | ...

assertGate(receiptBytes, "L1")          // throws unless valid AND human co-signed

const receipt: ActionReceipt = JSON.parse(receiptJson)
isDecisionAllowed(receipt, ["allow", "redact"])  // branch on policy, not crypto

shortHash(hex, "rcpt")  // "rcpt:9f2c4e7a" — display helper
```

- `gate(receiptBytes, minTrust = "L0"): GateResult`
- `assertGate(receiptBytes, minTrust = "L0"): void`
- `isDecisionAllowed(receipt, allowed: DecisionPath[]): boolean`

`GateResult.verdict` is the PascalCase engine tag, returned verbatim from the
native `verify`. **Never read `trustLevel` off parsed JSON — get it from
`gate()`** (re-derived on every verify; see the honesty rules in
[SKILL.md](../SKILL.md)).

## Verify-on-response proxy — `wrap`

`wrap` returns a Proxy around a client; after each method it looks for a
`__heso_receipt` field on the result and VERIFIES it against `minTrust` (distinct
from `engine.gate`, which captures + mints *your own* actions). Methods without
`__heso_receipt` pass through unguarded.

```ts
import { wrap } from "@hesohq/sdk"

const guarded = wrap(agentClient, {
  minTrust: "L1",
  onReceipt: (method, receiptJson) => { /* hand off the verified receipt */ },
  onGateFail: (method, verdict) => { console.error(`${method}: ${verdict}`); return false },
})
```

`WrapOptions`: `minTrust?: TrustLevel`, `onReceipt?: (method, receiptJson) => void
| Promise<void>`, `onGateFail?: (method, verdict) => boolean | Promise<boolean>`
(return `true` to swallow, `false` to throw).

## Cloud client — transport + commitments

`configure(apiKey, endpoint): void` once at startup, before any cloud call
(separate from `init()`, which configures local minting). The org is resolved from
the api-key — there is **no team id**; approvals are keyed by `action_hash`. Local
`gate`/`assertGate` need no config.

> **The transport sends a commitment, not the receipt.** The open SDK depends on an
> injected `@hesohq/transport` interface (not a hard import of the closed cloud
> client), so open code never drags closed code. The transport pushes a
> **commitment** — BLAKE3 fingerprint + queryable index (primitive, rail, chain
> head, signatures) — and **raw content stays in the customer VPC.** This replaces
> the retired `pushReceipt` firehose; the cloud verifies the detached signatures and
> proves **inclusion**, it does **not** re-run a check over a full body. Full model:
> [cloud.md](cloud.md).

| Method | HTTP | Returns |
| --- | --- | --- |
| `pullPolicy()` | GET `/v1/policy/pull` | `{ status, policyId, policyHash, toml }` |
| `pushCommitment(commitment)` | POST `/v1/commitments` | `CommitmentPushResult` |
| `pollApproval(actionHash)` | GET `/v1/approvals/{action_hash}` | `ApprovalView` |
| `waitForApproval(actionHash, { pollIntervalMs?, timeoutMs? })` | polls (+ one assembly GET on approval) | `ResolvedApproval` or throws |
| `getL1Parts(actionHash)` | GET `/v1/approvals/{action_hash}/assembly` (reads `legs[0]`) | `L1Parts` |
| `getQuorumParts(actionHash)` | GET `/v1/approvals/{action_hash}/assembly` (reads all `legs`) | `QuorumParts` |
| `submitApprovalToken(actionHash, input)` | POST `/v1/approvals/{action_hash}/submit-token` | `ApprovalView` |

`waitForApproval` defaults: `pollIntervalMs = 2000`, `timeoutMs = 300000`.
`submitApprovalToken`'s `input` is a `SubmitTokenInput`, not a bare token string.

```ts
const result = await pushCommitment(commitment)
result.status     // "appended" | "duplicate" | "quota_exceeded"
result.entryHash  // echoes the commitment's action_hash
result.seq        // the ledger's per-org append position
```

The store is append-only — a re-pushed commitment is `duplicate` (HTTP 409), never
an overwrite. Client-approval delegation (`signDelegation` /
`mintDelegationEnvelope`) mints an operator delegation envelope so a customer
co-signs from their own browser.

## Exported types

`ActionReceipt`, `ActionContent`, `ActionDetail`, `PolicyOutcome`,
`SignatureEntry`, `PolicyRule`, `Approval`, `GateResult`, `CommitmentPushResult`,
`ApprovalView`, `L1Parts`, `QuorumParts`, `Outcome`, `Action`, `TrustLevel`
(`"L0" | "L1"`), `Verb`, `Primitive`, `DecisionPath` (`"allow" | "block" |
"redact" | "require_approval"`), `ConditionOp`. Wire types are **generated from
the kernel** (ts-rs), not hand-mirrored — the kernel is the one source of truth.

## Raw primitives — `@hesohq/core`

When you need primitives directly (`@hesohq/core` re-exports native `@hesohq/node`):

- `verify(bytes)`, `verifyWithTime(bytes)` (adds a `timeStatus`: `"NoTrustedTime"`
  when anchorless — the default — or `"AnchoredRfc3161:<gen_time>"`; `gen_time`
  bounds when the **post-approval body** existed, not when a human decided),
  `verifyRederiving(bytes)` (replays the signed classification →
  `ClassificationMismatch`).
- Hashing/canonicalization: `contentHash`, `anchoredContentHashJs`,
  `actionCanonicalBytesJs`, `chainHashHex`, `shortHash`, `blake3Hex`.
- Chains: `verifyChain`, `verifySessionChainJs`,
  `verifySessionChainWithRotationJs`, `verifyAuditChain`.
- **Transparency / proof:** `verifyInclusionJs`, `verifyConsistencyJs` (the proof
  primitives the cloud's proof surface is built on — [cloud.md](cloud.md)).
- Approval / delegation: `verifyApprovalToken`, `verifyDelegation`.
- Redaction: `redactDestructiveJs`, `redactCommitJs`.
- Keys (Ed25519): `keyFromSeed`, `generateKey`, `OperatorKey`.
- Minting (process feature): `processAction`, `assembleL1FromParts`,
  `assembleQuorumFromParts` (both re-mint to L1).
