# TypeScript / Node reference (split `@hesohq/*` packages)

HESO ships as **several small published packages** (Node ≥ 18), not one bundle.
There is **no `@hesohq/sdk`** — you install only the pieces you use:

| Package | Job |
| --- | --- |
| `@hesohq/engine` | runtime config (`init`) + the engine-FFI seam; binds the Rust kernel |
| `@hesohq/gate` | the fail-closed egress gate (`hesoGate`, `gate`, `evaluate`) — the ONLY surface that blocks |
| `@hesohq/recorder` | the async OTel-GenAI recorder, off the hot path (`createRecorder`, `recordTool`) |
| `@hesohq/transport` | the Transport interface + registry — the seam the cloud client plugs into |
| `@hesohq/cloud` | the concrete cloud Transport (`configureCloud`); relays commitments to `api.heso.ca` |
| `@hesohq/node` | the native napi addon — the Rust kernel that mints/signs (loaded lazily) |

Zero crypto in TS: every canonical/signed byte is produced in the Rust kernel
via `@hesohq/node` (loaded lazily, so a host that only records/relays and never
mints doesn't need it). The open packages (`engine`/`gate`/`recorder`/`transport`)
never hard-import the closed `@hesohq/cloud` — they talk to it through the
injected `Transport`.

```bash
pnpm add @hesohq/engine @hesohq/gate @hesohq/recorder   # gate + record in-process
pnpm add @hesohq/transport                              # the Transport seam
pnpm add @hesohq/node                                   # native minting (the addon)
```

There are **two capture surfaces** — the async **recorder** (off the hot path) and
the fail-closed **gate** (the egress interceptor that blocks). The conceptual split
and the two pillars (keys customer-side, redact-before-sign) live in
[recorder-and-gate.md](recorder-and-gate.md); this page is the Node API.

## Gate an agent (Node)

Call `init()` once (from `@hesohq/engine`), then gate. The gate is the **only
blocking surface**: a blocked action throws `BlockedError`, a require-approval
action throws `SuspendedError`. The recommended install is the one-liner
**`installGate()`** (arms every reachable egress transport + the standing-key
assert); for a single tool you can also call the synchronous **`gate()`** core.

```ts
import { init } from "@hesohq/engine"
import { installGate, gate, evaluate, SuspendedError } from "@hesohq/gate"

init({ workflow: "vendor-payouts", account: "acct_19" })

// Recommended: ONE line arms every reachable egress transport, fail-closed.
installGate() // undici + node:http/https + globalThis.fetch + child_process; standing-key assert ran

// ...or call the gate core directly for a single tool, before its side effect runs:
const { action, outcome } = gate("transfer_funds", { amountUsd: 4200 }, { verb: "payment" })
const result = await transferFunds({ amountUsd: 4200 })  // only runs if gate didn't throw
```

- `init(options?)` — engine runtime config (`projectRoot`/`workflow`/`account`/
  `clockOverride`/`blocking`/`replay`/`transport`/`commitmentSigner`); resolves
  explicit option → `HESO_*` env → discovery → built-in default. `currentConfig()`
  reads it back; `requireConfig()` throws if `init()` hasn't run. Imported from
  `@hesohq/engine`.
- `installGate(options?)` — **the one-liner.** Arms EVERY transport the SDK can
  reach (undici global dispatcher, `node:http`/`node:https`, `globalThis.fetch`,
  `child_process`), then runs the no-standing-key assert **last** (fail-closed).
  Idempotent (each installer is `Symbol.for`-guarded). The floor is **default-on
  and transport-independent** — it mints per kernel-classified destructive action
  at the credential boundary, not per HTTP client. `undici` is an optional peer dep
  loaded lazily; `installGate()` throws if it is missing.
- `hesoGate(options?)` — the lower-level undici interceptor for a host that composes
  its own dispatcher. Compose it onto the global dispatcher and every fetch/undici
  call is gated: **ALLOW** forwards unchanged, **REFUSE** (deny / require-approval /
  any thrown pipeline error) short-circuits to a synthetic 403 that never hits the
  network. Fail-closed by default, no log-and-continue. Imported from `@hesohq/gate`.
- `selfCheck()` / `selfCheckOrThrow()` — the **truthful** coverage report. Per-transport
  booleans (`undiciGated`, `nodeHttpGated`, `fetchGated`, `childProcessGated`) name the
  **mediated** transports; `uncoveredTransports` names the **un-mediated** ones (the
  honest gap, not a silent warnings array); `standingKeys` lists reachable findings
  (name + rail + redacted shape, **never the value**); `escalations` aggregates both.
  `ok` is true only when every transport is armed and no FAIL-severity standing key is
  reachable. `selfCheckOrThrow()` refuses to boot ungated.
- `assertNoStandingKeys(options?)` / `detectStandingKeys()` — the standing-key keystone
  `installGate()` runs. **Fail-closed by default**: a reachable broad standing rail key
  (`sk_live_*`, long-lived `AKIA*`, `ghp_*`, `xoxb-*`) throws `StandingKeyError` before
  any shim arms, because a key the floor cannot bound defeats the floor. Override
  deliberately with `installGate({ allowStandingKeys: true | string[] })` or
  `HESO_ALLOW_STANDING_KEYS`. The detector returns env-var name + rail + redacted shape
  only — never the secret value.
- `gate(toolName, input, opts?)` — the synchronous fail-closed core: capture +
  classify-by-effect + ENFORCE. Returns `{ action, outcome }` on allow; throws
  `BlockedError` on deny and `SuspendedError(toolName, actionHash)` on
  require-approval. The classifier maps the call against the
  [taxonomy](taxonomy.md) into a destructive primitive before signing.
- `evaluate(toolName, input, opts?)` — same capture + classify WITHOUT enforcing →
  `{ outcome, action }`, so a caller can map the decision onto its own shape.
- `classifiedVerbOf(outcome)` — the kernel-CLASSIFIED structural verb off an allowed
  outcome (e.g. a Stripe POST classified `payment`, an S3 DELETE classified
  `delete`), or `null`. This is the verb a hard credential floor keys off — NOT the
  install-time `http_request` hint on `action.verb`.

`hesoGate({ credentialFloor })` adds the **hard credential floor** beneath the soft
policy gate (RFC 0003): a destructive ALLOWED call only forwards after a
just-in-time scoped, short-lived rail credential is minted customer-side; if minting
fails the call fails CLOSED. The minted credential is ENFORCED onto the wire
(`credentialRidesHeaders`), never silently dropped. Floor primitives + minters
(`mintFloorCredential`, `RestrictedKeyMinter`, `StsClient`) are exported from
`@hesohq/gate`.

- **Two-phase approval:** `gate` throws `SuspendedError(toolName, actionHash)`
  (phase one). Out of band, poll the cloud client (`pollApproval(actionHash)`) and on
  approval read the relayed parts (`getL1Parts(actionHash) → L1Parts`), then
  `finalizeL1(suspendedContent, relayedParts, keyPassphrase?)` (from `@hesohq/gate`)
  re-mints to L1 — it asserts `approved`, assembles in-core, re-verifies `Valid(L1)`
  locally, then relays the superseding commitment. A rejected decision throws
  `ApprovalRejectedError`.
- **Quorum (k-of-n):** read all legs via the cloud client's
  `getQuorumParts(actionHash) → QuorumParts`, then
  `finalizeQuorum(suspendedContent, relayedParts, options?)` (from `@hesohq/gate`)
  assembles a quorum receipt that re-derives to **L1 with a `multi_approval` block**.
  Under-quorum at verify is `ThresholdNotMet`. (Quorum semantics:
  [receipts.md](receipts.md).)
- **Errors:** `BlockedError`, `SuspendedError`, `ApprovalRejectedError`,
  `OperatorKeyMismatchError` are all exported from `@hesohq/gate`.

The co-sign / relay flow and the key-rotation fail-closed behavior are **one
canonical statement** in [SKILL.md](../SKILL.md). On Node: the cloud client supplies
the relayed parts (`pollApproval` / `getL1Parts` / `getQuorumParts`),
`@hesohq/gate`'s `finalizeL1` / `finalizeQuorum` re-mint + locally re-verify before
push, and `finalizeQuorum(..., { loadedOperatorPubkeyB64, onKeyRotation })` does the
proactive rotation check + auto-re-suspend under a new key
(`OperatorKeyMismatchError` / `ReSuspendResult`).

## Record an agent (off the hot path)

The recorder is the **non-blocking** surface: it consumes OTel GenAI spans, then
fingerprints + signs + appends a commitment OFF-THREAD. The tool body runs
unblocked. Register it ADDITIVELY — never replacing the host's existing exporters.

```ts
import { createRecorder, recordTool, recordTools } from "@hesohq/recorder"

const recorder = createRecorder()

// Vercel AI SDK v5: wrap a tool so each execute EMITS a recorder span.
const search = recordTool(recorder, "search", searchTool)
const tools = recordTools(recorder, { search: searchTool, lookup: lookupTool })
```

- `createRecorder(options?)` — builds the `BatchTracingProcessor`. Register it
  additively (`addTraceProcessor(createRecorder())`), never `setTraceProcessors`.
- `recordTool(recorder, name, tool, opts?)` — wrap one AI SDK v5 tool; each
  `execute` emits a recorder span around the unblocked original. The tool's name is
  supplied by the caller (AI SDK tool objects don't carry their own name). A tool
  with no `execute` (provider/client tools) is returned unchanged. `opts`:
  `{ captureArguments?: boolean }` (OFF by default; the recorder hashes args into the
  fingerprint regardless of capture).
- `recordTools(recorder, tools, opts?)` — wrap a whole `tools` record.
- The Vercel AI SDK adapter lives at the subpath `@hesohq/recorder/adapters/ai-sdk`.
  The `'ai'` package is never imported there — the adapter wraps a structural
  tool-like shape (`{ execute? }`), so importing it doesn't require `ai`.

Recording is async and never blocks; **blocking egress is the gate's job**, not the
recorder's.

## Cloud client — relay commitments

`@hesohq/cloud` is the concrete `Transport`. Construct it once at startup with
`configureCloud({ apiKey, endpoint })` — this registers it as the active transport
(via `@hesohq/transport`'s `setTransport`) so the open recorder/gate drive it. The
api-key + endpoint live here, **off the open SDK**. The org is resolved from the
api-key — there is **no team id**; approvals are keyed by `action_hash`. Local
gating/recording works with **no transport** at all (an open build that never imports
`@hesohq/cloud` gets the fail-closed stub from `@hesohq/transport`).

```ts
import { configureCloud } from "@hesohq/cloud"

const client = configureCloud({
  apiKey: process.env.HESO_API_KEY!,
  endpoint: "https://api.heso.ca",
})
```

> **The transport sends a commitment, not the receipt.** The cloud client pushes a
> **commitment** — BLAKE3 fingerprint + queryable index (primitive, rail, chain head,
> signatures) — and **raw content stays in the customer VPC.** The cloud verifies the
> detached signatures and proves **inclusion**; it does NOT re-run a check over a full
> body. Full model: [cloud.md](cloud.md).

The `Transport` interface (implemented by `CloudClient`, hits `api.heso.ca` with the
`x-api-key` header):

| Method | HTTP | Returns |
| --- | --- | --- |
| `send(commitment, supersedesActionHash?)` | POST `/v1/commitments` | `SendResult` |
| `putBody(actionHash, receipt)` | offloads the body | `void` |
| `pullPolicy()` | GET `/v1/policy/pull` | `PolicyPullResult` |
| `openApproval(req)` | opens the approvals row | `ApprovalView` |
| `pollApproval(actionHash)` | GET the approval state | `ApprovalView` |
| `getL1Parts(actionHash)` | reads `legs[0]` of the assembly | `L1Parts` |
| `getQuorumParts(actionHash)` | reads all `legs` of the assembly | `QuorumParts` |
| `submitApprovalToken(actionHash, input)` | POST the co-sign token | `ApprovalView` |
| `heartbeat(beat)` | signed coverage-interval claim | `HeartbeatResult` |

```ts
const result = await client.send(commitment)
result.status     // "appended" | "duplicate" | "quota_exceeded"
result.entryHash  // echoes the commitment's action_hash
result.seq        // the store's per-org append position (0 when no row was written)
```

The store is append-only — a re-pushed commitment is `duplicate` (idempotent),
never an overwrite; `quota_exceeded` is the monthly soft-cap (the local chain is
unaffected). `submitApprovalToken`'s `input` is a `SubmitTokenInput`, not a bare
token string. Client-approval delegation (`signDelegation` /
`mintDelegationEnvelope`, from `@hesohq/engine`) mints an operator delegation
envelope so a customer co-signs from their own browser.

## Verify a receipt (offline, no config, no network)

Verification is a **separate, offline** surface — it is NOT in the gate/record
packages above. A receipt verifies anywhere from bytes alone; **`Valid` is the only
accept.** Use one of:

- `@hesohq/verify-wasm` — browser / edge offline verify (the reviewer's browser).
- `@hesohq/node` — the same Rust kernel as a Node addon (byte-identical verdict).
- the `heso-verify-cli` binary — standalone, no SDK install.

Verdicts are PascalCase engine tags returned verbatim from the kernel; trust level is
`L0` | `L1` only. **Never read a trust level off parsed receipt JSON — it must be
re-derived on every verify.** See [receipts.md](receipts.md) and [verification.md](verification.md)
for the verify API and the verdict tags.

## Raw primitives — `@hesohq/node`

When you need kernel primitives directly, they live in the native `@hesohq/node`
addon (the same crate the gate/recorder bind for minting and signing):

- `verify(bytes)`, `verifyWithTime(bytes)` (adds a `timeStatus`: `"NoTrustedTime"`
  when anchorless — the default — or `"AnchoredRfc3161:<gen_time>"`; `gen_time`
  bounds when the **post-approval body** existed, not when a human decided),
  `verifyRederiving(bytes)` (replays the signed classification →
  `ClassificationMismatch`).
- Hashing / canonicalization: `contentHash`, `chainHashHex`, `blake3Hex`.
- Chains: `verifyChain`, `verifyAuditChain`.
- **Transparency / proof:** `verifyInclusionJs`, `verifyConsistencyJs` (the proof
  primitives the cloud's proof surface is built on — [cloud.md](cloud.md)).
- Approval / delegation: `verifyApprovalToken`, `verifyDelegation`.
- Keys (Ed25519): `keyFromSeed`, `generateKey`, `OperatorKey`.
- Minting (process feature): `processAction`, `assembleL1FromParts`,
  `assembleQuorumFromParts` (both re-mint to L1).
