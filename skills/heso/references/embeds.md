# Embeds — where a HESO user actually lives

The daily driver is **not** the web console. It is **Slack + Datadog + the SDK**.
The console demotes to a "visitor control room" — somewhere you go occasionally
to author a policy, debug a run, or build an exhibit, not somewhere you sit.
Embeds are how **HESO meets the user where they already are** — their Slack, their
Datadog, their GitHub PRs, their Vanta.

None of the four embeds is a firehose; each is a *thin* surface over a capability
that already lives in the kernel, the gate, or the cloud. They ship as
**optional/contrib packages** (the OpenTelemetry core-vs-contrib pattern): the open
side (e.g. the Slack Block Kit renderer, the OTel dashboard defs) lives in the SDK
under `packages/embeds/*`; the closed side (anything touching the commitment store
or approval relay) lives in the cloud. They are **co-located, not pre-split** — an
embed earns its own repo only when it grows an independent release cadence.

> **The shared signer.** Every outbound embed signs with the cloud's HMAC-signed
> webhook contract (the `WebhookDispatcher` seed, with an SSRF `url_guard` in front
> of every customer-configured URL). Do not re-implement the signer per embed — it
> is *the* signer for the Slack card signature, the Datadog event push, and the
> GitHub status check alike.

Launch order (resolved): **Slack is the hero**, **GitHub policy-as-code is the
fast-follow**, Datadog/OTel and Vanta ship on demand.

## 1. Slack approval card (the hero)

The **mobile-real, daily approval surface** that replaces the console's
`/approvals` page as the place a human actually approves a risky action.

- **Source primitives (already exist):** the gate's two-phase approval (`gate
  throws SuspendedError → out-of-band finalize` keyed on `action_hash`), the
  approval-token flow, and the `/gate/[token]` web deep link.
- **What the embed adds:** a Slack interactive message (Block Kit) carrying the
  action's **destructive primitive** (see [taxonomy.md](taxonomy.md)), the
  **redacted** action fields, the policy verdict, and approve/deny/delegate
  buttons. Approve co-signs out-of-band exactly as the console co-sign does — the
  thin cloud relays the detached co-signature and **holds no signing key** (keys
  stay customer-side; canonical statement in [SKILL.md](../SKILL.md)). The
  `/gate/[token]` deep link is the web fallback for anything needing the full gate
  UI.
- **The 30-minute wall.** The card shows a **live countdown** because the
  rail-boundary credential behind a gated action is short-lived (STS ≈15-min TTL).
  Approval inside the window finalizes against the still-valid credential; approval
  after it **fails closed with a clear "credential expired, re-trigger" state**,
  never a misleading success. Quorum (k-of-n) is harder under the wall — every
  co-signer must land inside one TTL window — so the card surfaces remaining time
  prominently. Full constraint: [recorder-and-gate.md](recorder-and-gate.md).

Why it leads: **real approvals live in the Slack embed, not the dashboard.** The
console's `/dashboard` + `/approvals` are kept but **demoted** precisely because
this card is now the daily surface.

## 2. GitHub policy-as-code (the fast-follow)

Policy authored **in the repo**, reviewed in a PR, enforced by a status check —
**not** authored in a dashboard. This is the primary policy authoring surface; the
dashboard is *one* surface, not the home of policy (see [policy.md](policy.md)).

A GitHub App/Action that:

- **lints** the committed policy (`heso.toml` + the rule set),
- runs whole-policy SMT analysis to **prove** invariants on the PR (e.g. "no
  `move-value` over $X without approval"),
- posts a **status check** that blocks merge on a policy that violates a pinned
  floor.

The control room's `/policy` editor maps onto this: edits in the editor produce a
PR against the policy repo, so the GitHub embed and the editor are two windows onto
the same policy-as-code source.

## 3. Datadog / OpenTelemetry

**Graphs belong here, not in a bespoke console page** — which is why the control
room **cut its `/analytics` page** (an agent-observability product should not
hand-roll dashboards Datadog/Grafana do better).

- The recorder already emits **OpenTelemetry GenAI semconv** spans (see
  [recorder-and-gate.md](recorder-and-gate.md)), so any customer already on
  OTel/Datadog gets HESO data in their existing dashboards "for free."
- The embed is therefore mostly **a documented mapping + canned dashboard
  definitions**, not a new data plane: action volume by destructive primitive,
  gate verdicts, reconciliation alerts, proof-inclusion latency — as widgets the
  customer drops into their own boards. Datadog ships native support for the OTel
  GenAI conventions, so the surface is a contrib package + dashboard JSON.

## 4. Vanta

The compliance/assurance embed: HESO's signed commitments + inclusion proofs feed
Vanta (and the SOC 2 / ISO evidence story) as **continuous evidence**, so a user's
existing GRC tool shows "agent actions are governed and provable" without a human
exporting anything. It rides on the **proof layer** ([cloud.md](cloud.md)), not on
the retired compliance score — Vanta consumes inclusion/consistency proofs +
reconciliation state as evidence, not a 0–100 number.

## How alerts fan out

An **unwitnessed-action alert** (see [cloud.md](cloud.md)) is exactly the shape
that fans out across embeds — the same `WebhookDispatcher` seed drives the Slack
card, a Datadog monitor, and a Vanta evidence entry. One reconciliation finding,
many surfaces.

## Pointers

- The approval/gate contract these embeds consume: [recorder-and-gate.md](recorder-and-gate.md)
- The proof + reconciliation state they surface: [cloud.md](cloud.md)
- Policy-as-code authoring (the GitHub embed's source): [policy.md](policy.md)
- The destructive primitives the cards display: [taxonomy.md](taxonomy.md)
