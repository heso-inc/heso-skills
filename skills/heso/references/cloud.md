# The cloud — commitment store, reconciliation, proof

The cloud is **not** a place the firehose lands. Raw receipt content **never
leaves the customer VPC.** The cloud is an **index + commitment ledger + proof
surface** over a trail whose bodies it has never seen, plus a **reconciliation
engine** that diffs that trail against the rails' own ledgers.

> **This replaces the old receipt-mirror.** Earlier HESO pushed the full
> `ActionReceipt` and "the server re-ran the identical check." That is retired.
> If you see `pushReceipt` / "server re-runs the check" / a 0–100 compliance
> score, it is old framing — the cloud now ingests a **commitment** and proves
> **inclusion** + **reconciliation state**, not a number.

The cloud has three capabilities.

## 1. Commitment store — fingerprint + index, never the body

The SDK pushes a **commitment**, not the receipt:

- a **BLAKE3 fingerprint** (`action_hash`) of the receipt — *the* commitment,
- **queryable metadata** indexed by **destructive primitive** (the crown-jewel
  query axis — see [taxonomy.md](taxonomy.md)),
- the **chain head** (`chain_prev` / `chain_head` / `session_id` / `seq`) so the
  trail stays hash-linked and tamper-evident,
- the **signatures** (detached — the cloud holds **no** minting key; it only
  verifies; see [recorder-and-gate.md](recorder-and-gate.md) "keys held
  customer-side"),
- the verdict + the `taxonomy_hash` the action was classified under,
- the destination **`rail`** (the join key reconciliation needs).

The payload carries that and **nothing more** — no `content`, no free-text
action body. Everything in it is a fingerprint, a structural classification, a
verdict, or a signature. The store is **append-only** (a commitment, once
recorded, is frozen; a re-push is a `409 duplicate`, not an overwrite).

The two load-bearing index columns — **`primitive`** ("show me every
`move-value` last week" is index-only) and **`rail`** (the reconciliation join) —
are *new*: the old store only knew org + time. Raw bodies stay customer-side and
are fetched on demand, only from the customer side, only for an exhibit.

The wire change is a **protocol change**, not a silent storage swap:

```
OLD  POST /v1/receipts     { content: <full ActionReceipt> }       # receipt-mirror (retired)
NEW  POST /v1/commitments  { action_hash, chain_prev, chain_head, session_id, seq,
                             primitive, coarse_verb, taxonomy_hash,
                             resource_class, rail, trust_level, decision,
                             winning_rule_id, winning_severity,
                             occurred_at, signer_fpr, signature, envelope_kind }
```

Because it changes what crosses the customer/cloud boundary, it ships with **new
conformance vectors** (a golden commitment vector + a golden DSSE-envelope vector)
so the Rust signer, both SDKs, and the open verifier are provably byte-identical.
Vectors are owned by the open **heso-spec** repo.

## 2. Reconciliation — the loop that catches the unwitnessed action

The gate signs a commitment for every action it intercepts. Reconciliation closes
the loop the gate alone cannot: *did the agent do something we never saw?* It
ingests each rail's **own** ledger and diffs it against the signed commitment
trail.

```
   rail ledger (truth)              signed commitment trail (HESO)
   Stripe events (webhook)   ┐
   AWS CloudTrail (S3/EB)    ┼──►  DIFF  ◄──  commitment store (primitive-indexed)
                             ┘       │
                                     ▼  reconciliation state (deterministic, exact-ID match)
                          matched      → witnessed (a signed commitment exists before the rail saw it)
                          unwitnessed  → ⚠ ALERT (rail moved value/destroyed and HESO never signed it)
                          cant_verify  → declared coverage gap (rail fact declares no heso_action_hash)
```

- **`matched`** — a rail fact whose declared `heso_action_hash` exactly equals a
  `commitment.action_hash`. Witnessed. The good path.
- **`unwitnessed`** — a rail fact with **no** matching commitment. Something
  touched the rail HESO never signed (a leaked credential, a bypassed SDK). **This
  is the alert**, tiered by primitive (`move-value` / `destroy` /
  `change-authority` page; `disclose` high; `execute` logs).
- **`cant_verify`** — a rail fact that declares no (or a malformed)
  `heso_action_hash`, so the match is undecidable. A first-class declared state,
  **never silently folded** into either of the above.

Matching is **deterministic — exact correlation-ID match, never fuzzy.** It is
**prevent-first**: because the agent can only reach a rail through a HESO-issued
scoped/federated credential (the rail-boundary floor — see
[recorder-and-gate.md](recorder-and-gate.md)), ungated access is *rejected at
source* (AWS SCP/RCP deny-unless-HESO; Stripe restricted-keys-only + rotate old
keys at onboarding), so the diff is tight and every `unwitnessed` event is
genuinely suspicious. Findings are committed to the transparency log. Launch rails
are **Stripe + AWS**; others fast-follow by demand behind a stable adapter
interface (ingest → classify-to-primitive → extract-correlation-key).

The asymmetry matters: **unwitnessed-in-rail is the security alert** (something
happened we didn't witness). A commitment with no rail event (HESO signed an
intent the rail never executed) is a lower-severity outcome signal — a commitment
proves *authorization*, not *outcome*; reconciliation is what supplies the outcome
side.

## 3. Proof — inclusion / consistency, not a score

Keep the **proof primitives** — they map straight to the proof layer and are
correct:

- `verifyInclusionJs` — a receipt is in the transparency log.
- `verifyConsistencyJs` — the log only ever appended (no rewrite).

The transparency log is moving onto **Tessera** (the commitment leaf is appended;
the checkpoint is Tessera's native signed checkpoint; `ProofBuilder` synthesizes
inclusion + consistency proofs from served tiles) with externally-witnessed
checkpoint cosignatures. The commitment fits in a Tessera entry (≤64KB) trivially;
a full receipt body would not — mechanically enforcing "raw stays in the VPC."

> **The 0–100 compliance score is retired** (and so is any `ControlVerdict`
> met/partial/failed framing). The wedge is **inclusion/consistency proofs +
> reconciliation state**, not a number. The security-review **exhibit** is built
> around them: "here is the signed trail, here is the rail's own ledger, here is
> the proof every money/destroy/authority event reconciles." An exhibit with zero
> unwitnessed actions over a period is the assurance claim. Do not synthesize,
> hardcode, or imply a coverage score.

## Evidence bundles — offline, self-verifying

The core assembles a **self-contained evidence bundle**: a directory (and a
deterministic POSIX tar) holding `receipts.jsonl`, a `VERIFY.sh`, and a
`README.txt`. The relying party unpacks it and runs `./VERIFY.sh` — which resolves
the released standalone `heso-verify-cli` and re-checks every receipt **offline,
with no HESO install and no network.** The Rust entry point is
`heso._core.evidence_bundle_tar`; on the cloud, eligible orgs export via `POST
/v1/evidence/export`. A bundle proves the same thing one receipt does —
authorization, re-derived — never downstream success (see the honesty rules in
[SKILL.md](../SKILL.md)).

## Multi-tenancy

Every cloud table is **org-scoped via Postgres RLS** (`organisation_id` /
`current_setting('app.current_org')`) — the real tenant boundary. The
org-scoping lives in a thin repository layer, and the commitment is a typed
`Commitment` model, not an untyped `dict`.

## Pointers

- The taxonomy the store indexes by (canonical, do not restate): [taxonomy.md](taxonomy.md)
- Where the commitment comes from (the gate signs it; the transport pushes it): [recorder-and-gate.md](recorder-and-gate.md)
- The HTTP surface + status codes: [cli-and-api.md](cli-and-api.md)
- Where unwitnessed-action alerts fan out (Slack/Datadog/Vanta): [embeds.md](embeds.md)
- Wire constants + conformance vectors are owned by the open **heso-spec** repo.
