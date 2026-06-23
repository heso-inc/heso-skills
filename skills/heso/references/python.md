# Python gating reference (`heso`)

The `heso` package (Python ≥ 3.10) is the **lead binding** — the deepest capture
surface (most adapters, suspend/resume). It runs in-process — the Rust core ships
as the `heso._core` wheel, so there is no subprocess for gate operations. Capture,
classify-by-effect, signing, and the audit chain all happen inside your process.

HESO has **two capture surfaces** — the async **recorder** (off the hot path, an
OTel GenAI consumer) and the fail-closed **gate** (the egress interceptor that
blocks). The conceptual split and the two pillars (keys customer-side,
redact-before-sign) are in [recorder-and-gate.md](recorder-and-gate.md); this page
is the Python API. The decorators, `wrap()`, and the framework adapters are the
supported surface (auto-instrumentation was removed).

## Scaffold

```bash
pip install heso     # or: uv add heso
heso init
```

`heso init` mints the operator identity, writes a starter `heso.toml`, and
gitignores the local data dir. Idempotent. Leaves `heso_bootstrap.py`,
`heso.toml`, and `heso-local-data/` (key + `receipts.jsonl` + audit chain +
outbox). Commit `heso.toml`, never `heso-local-data/`. When `HESO_KEY_PASSPHRASE`
is unset, `heso init` auto-writes a dev-only passphrase
(`heso-local-data/DEV-ONLY.passphrase`, 0600) and `heso.init()` loads it back into
the env so the lifecycle works with zero setup; `HESO_ENV=production` (or
`--require-passphrase`) refuses and demands a real passphrase. The other CLI
commands — `heso demo`, `heso verify <path|hash>`, `heso show <hash>` — read the
local store; see [cli-and-api.md](cli-and-api.md).

**Every allowed action's signed receipt is appended to
`heso-local-data/receipts.jsonl`** (one receipt per line, the exact shape
`heso-verify-cli` and the evidence bundle consume) — so your first receipt is a
file you can verify offline, not a dict that dies with the process.

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
shadow mode — useful to roll HESO out and collect receipts (including for what
*would* be blocked) without changing behavior, then flip to blocking once the
policy looks right.

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

## Install the egress gate — `install_gate()` (the one-liner)

The egress gate (`heso_gate`) has **one process-wide install**, not a per-client
tax. `install_gate()` runs the no-standing-key assert **first** (fail-closed),
auto-instruments the available clients (httpx / requests / urllib3 / aiohttp), and
stores the process-global default credential floor:

```python
from heso_gate import install_gate

install_gate()   # standing-key assert (fail-closed) → auto-instrument httpx/requests/urllib3/aiohttp
```

The credential floor mints **per kernel-classified destructive action** at the
credential boundary — transport-independent, decoupled from which HTTP client got
the in-process shim. Conceptual split + the tiered honesty (mediated vs un-mediated,
asymmetric vs HMAC rails) is in [recorder-and-gate.md](recorder-and-gate.md).

**Per-client shims are the fallback**, for a client `install_gate()` cannot reach:
`HesoGateTransport` / `HesoGateAsyncTransport` on an `httpx.Client` / `AsyncClient`,
and `HesoGateAdapter` mounted on a `requests.Session`'s `https://`.

```python
import httpx
from heso_gate import HesoGateTransport
client = httpx.Client(transport=HesoGateTransport(httpx.HTTPTransport()))  # fallback
```

### Self-check — escalates loudly

`self_check()` returns a `SelfCheckReport`: `.gated` names the **mediated**
(auto-instrumented) clients, `.uncoverable` names the transports the gate **cannot**
see at all (raw `socket`, `subprocess`), and `.escalations` aggregates every
un-mediated / uncoverable surface plus every reachable standing key. `.ok` is true
only when `.escalations` is empty; `self_check(raise_on_gap=True)` raises
`SelfCheckGapError`. The per-client `check_httpx_client(client)` /
`check_requests_session(session)` cover the fallback shims.

### Standing-key check — fails closed

`install_gate()` runs `assert_no_standing_key()` first, **fail-closed by default**:
a reachable broad standing rail key (`sk_live_*`, long-lived `AKIA*`, `ghp_*`,
`xoxb-*`) raises `StandingKeyError` before any shim arms, because a standing key the
floor cannot bound defeats the floor's guarantee. The detector reports only the
env-var name, rail, redacted shape, and severity — **never the secret value**.
Override deliberately with `install_gate(strict_standing_key=False)`.

## Approvals — suspend / resume

When policy returns `require_approval`, a gated call raises **`SuspendedError`**
instead of running. The action is captured and an approval opens for the
configured approvers; once a human co-signs with a device-held key the receipt
reaches **L1** and the work can resume. The lower-level suspend/resume API:

- `configure(...)`, `gated(callable)`, `gate(action)`, `gate_async(action)` —
  gate an action and get a `Gate` result. `@gated` is **named-approval sugar** — an
  explicit "this function needs a human decision" annotation that routes a specific
  function to a named approver regardless of its wire effect; it is not the egress
  path (that is `install_gate()`).
- `resume(action_hash)` → a `ResumeOutcome`; `decision(action_hash)` reads the
  current decision; `append_decision(action_hash, decision)` records one;
  `current_action_hash()` for the in-flight action.
- Outcome/marker types: `Gate`, `ResumeOutcome`, `SUSPENDED`, `DENIED`, `Paused`,
  `ContextLost`.

The co-sign / relay flow and the key-rotation fail-closed behavior are **one
canonical statement** in [SKILL.md](../SKILL.md); quorum semantics are in
[receipts.md](receipts.md). The Python API onto them:

- `heso.cloud.get_l1_parts(action_hash)` → `L1Parts`, then
  `heso.finalize_l1(action_hash, suspended_content, parts)` assembles the
  single-approver L1 and pushes it.
- `heso.cloud.get_quorum_parts(action_hash)` → `QuorumParts`, then
  `heso.finalize_quorum(action_hash, suspended_content, parts)` assembles a **k-of-n
  quorum** (re-derives to **L1** with a `multi_approval` block; under-quorum at
  verify is `ThresholdNotMet`). `finalize_quorum` takes `loaded_operator_pubkey_b64`
  (the proactive rotation check) and an `on_key_rotation` callback that re-suspends
  under the new key (a fresh suspended L0 with a new `action_hash`,
  `OperatorKeyMismatchError` on a stale base).
- A non-approved record makes either finalize raise before touching the keystore;
  every leg of a quorum must be `approved`.

`heso.process(action: Action) -> Outcome` runs the full pipeline imperatively for
a manually-built `Action`.

## Exceptions

| Exception | Raised when |
| --- | --- |
| `BlockedError` | Policy blocked the action (and `blocking=True`). |
| `SuspendedError` | Policy routed the action to a human; it's paused for approval. Carries `action_hash` + `rule_id`; its message is **actionable** — prints the console approvals URL when configured, else the local `@heso.gated` + `append_decision` dev path. |
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

A receipt proves **authorization** (and at L1 human approval), never a downstream
outcome — see the honesty rules in [SKILL.md](../SKILL.md).
