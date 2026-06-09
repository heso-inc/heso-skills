# Python gating reference (`heso`)

The `heso` package (Python ≥ 3.10) is the only HESO surface that **captures and
signs** an agent's actions. It runs in-process — the Rust core ships as the
`heso._core` wheel, so there is no subprocess for gate operations. Capture, policy
evaluation, signing, and the audit chain all happen inside your process.
Auto-instrumentation was removed; supported gating is the decorators, `wrap()`,
and the framework adapters.

## Scaffold

```bash
pip install heso     # or: uv add heso
heso init
```

`heso init` mints the operator identity, writes a starter `heso.toml`, and
gitignores the local data dir. Idempotent. Leaves `heso_bootstrap.py`,
`heso.toml`, and `.heso/` (key + JSONL audit chain + outbox). Commit `heso.toml`,
never `.heso/`.

## init

```python
heso.init(
    project_root=None,    # HESO_PROJECT_ROOT
    binary=None,          # HESO_BIN
    workflow=None,        # HESO_WORKFLOW
    account=None,         # HESO_ACCOUNT
    clock_override=None,  # HESO_CLOCK
    timeout=None,         # HESO_TIMEOUT
    blocking=None,        # HESO_BLOCKING (default True)
) -> Config
```

Resolution order: explicit args → env vars → `heso.toml` → defaults. Must run
before any gated code. Either import the generated `heso_bootstrap` at the top of
your entrypoint, or call `heso.init()` on the first line:

```python
# main.py
import heso_bootstrap        # runs heso.init() before other imports

from agent import run
run()
```

## Decorators

| Decorator | Verb | Notes |
| --- | --- | --- |
| `@heso.tool` | `tool_call` | `redact: list[str]` for commit-and-reveal redaction. |
| `@heso.destructive` | `delete` | Rides a pinned floor — can't be allowed without approval. Redacts destructively. |
| `@heso.action("domain.action_id")` | (label) | Declare the fine catalog action on a gated function — a descriptive label stamped on the receipt; the coarse verb stays authoritative. |

```python
@heso.tool
def search(query: str) -> str:
    return web.search(query)          # body runs only if policy allows

@heso.destructive
def delete_record(record_id: str) -> None:
    db.delete(record_id)

@heso.tool(redact=["api_key"])        # api_key redacted (BLAKE3 commitment) before signing
def call_partner_api(api_key: str, endpoint: str) -> dict:
    return requests.get(endpoint, headers={"Authorization": api_key}).json()
```

**Blocking** is the default (`blocking=True`, set on `heso.init`, not per-decorator):
a blocked action raises `BlockedError` *before* the body runs. `blocking=False` is
shadow mode — useful to
roll HESO out and collect receipts (including for what *would* be blocked) without
changing behavior, then flip to blocking once the policy looks right.

The call's arguments become the action's `fields`, so policy conditions match them.

## Gate a whole client — `heso.wrap()`

```python
import heso
from openai import OpenAI

heso.init()
client = heso.wrap(OpenAI())

resp = client.chat.completions.create(   # gated at the leaf as llm_call
    model="gpt-4o",
    messages=[{"role": "user", "content": "summarize the filing"}],
)
```

The stand-in reaches into nested attributes (`client.chat.completions.create`),
gates `.create()` as `llm_call` and `.request()` as `http_request`, and passes
everything else through. On a refused gate it raises `BlockedError` or
`SuspendedError`.

## Scope a unit of work — `heso.step()`

```python
with heso.step(workflow="run-42"):
    search("pricing for the enterprise tier")
    call_partner_api(api_key, "https://api.partner.example/v1/quote")
```

Every action captured inside the block is scoped to that workflow, matchable by a
`workflow` subject in policy.

## Approvals — suspend / resume

When policy returns `require_approval`, a gated call raises **`SuspendedError`**
instead of running. The action is captured and an approval opens for the
configured approvers; once a human co-signs with a device-held key the receipt
reaches **L1** and the work can resume. The lower-level suspend/resume API:

- `configure(...)`, `gated(callable)`, `gate(action)`, `gate_async(action)` —
  gate an action and get a `Gate` result.
- `resume(action_hash)` → a `ResumeOutcome`; `decision(action_hash)` reads the
  current decision; `append_decision(action_hash, decision)` records one;
  `current_action_hash()` for the in-flight action.
- Outcome/marker types: `Gate`, `ResumeOutcome`, `SUSPENDED`, `DENIED`, `Paused`,
  `ContextLost`.

**How the co-sign actually happens (console + relay).** A trusted, role-gated human
approves in the web console and co-signs the action **in their browser** with a
per-device key; the thin cloud relays the detached co-signature and **holds no
signing key**. The operator side fetches the relayed parts and re-mints + locally
re-verifies the L1 before pushing:

- `heso.cloud.get_l1_parts(action_hash)` → `L1Parts`, then
  `heso.finalize_l1(action_hash, suspended_content, parts)` assembles the
  single-approver L1 and pushes it.
- `heso.cloud.get_quorum_parts(action_hash)` → `QuorumParts`, then
  `heso.finalize_quorum(action_hash, suspended_content, parts)` assembles a **k-of-n
  quorum** receipt. A quorum re-derives to **L1 with a `multi_approval` block** — not
  a higher level, and honestly narrower per approver (the operator signs only the
  action + threshold + roster). Under-quorum at verify is `ThresholdNotMet`.
- A non-approved record makes either finalize raise before touching the keystore;
  every leg of a quorum must be `approved`.

**Key rotation fails closed.** If the operator key rotates between suspend and
finalize, the in-core assemble rejects the stale base (`OperatorKeyMismatchError`).
`finalize_quorum` takes `loaded_operator_pubkey_b64` (proactive check) and an
`on_key_rotation` callback that re-suspends under the new key — a fresh suspended L0
with a new `action_hash` the approval re-opens against. Never a silent mint under a
stale key.

`heso.process(action: Action) -> Outcome` runs the full pipeline imperatively for
a manually-built `Action`.

## Exceptions

| Exception | Raised when |
| --- | --- |
| `BlockedError` | Policy blocked the action (and `blocking=True`). |
| `SuspendedError` | Policy routed the action to a human; it's paused for approval. |
| `BridgeError` | The Rust engine bridge failed. |
| `HesoConfigError` | Bad/missing configuration. |

## Adapters

All drop-ins are exposed **lazily**, so a bare `import heso` never imports a
framework you aren't using. Each runs every call through the same gate as the
decorators.

- **LangChain / LangGraph:** add `heso.HesoCallbackHandler()` to your
  `AgentExecutor` callbacks; tool calls in the agent are captured and gated.
  ```python
  executor = AgentExecutor(agent=agent, tools=tools, callbacks=[heso.HesoCallbackHandler()])
  ```
- **OpenAI / Anthropic:** wrap the client with `heso.wrap()` (above).
- **Framework namespaces** (reached as `heso.<name>` after a bare `import heso`):
  `heso.crewai` (e.g. `heso.crewai.heso_before_hook`), `heso.openai_agents`,
  `heso.claude_agent`, `heso.pydantic_ai`, `heso.langgraph`, and `heso.mcp`
  (e.g. `heso.mcp.wrap_call_tool` to gate MCP tool calls).

## Exported types

`Config`, `Action`, `Verb`, `OutcomeKind`, `Outcome`, `RedactStrategy`.

## What each gated call produces

- A signed **Action Receipt** (verb, tool, policy verdict + `rule_display`,
  redaction markers, Ed25519 operator signature). See [receipts.md](receipts.md).
- A new BLAKE3 **audit chain** entry, hash-linked to the previous receipt.
- An artifact anyone can **verify offline** with no HESO infrastructure. See
  [verification.md](verification.md).

Capture timing (`captured_at`) is the operator's own clock — **informational only**.
An optional RFC-3161 `time_anchor` can bind when the (post-approval) receipt body
existed; it is off by default, so most receipts carry no trusted time.

A receipt proves the operator *authorized* the action under a known policy, and at
L1 that one or more people *approved* it (single-approver, or a k-of-n quorum) with
device-held keys. It does not prove the action *succeeded* downstream.
