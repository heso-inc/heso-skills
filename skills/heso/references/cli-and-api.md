# CLI + cloud API

## CLI (`heso`)

```bash
heso init [dir]
```

`heso init` is the one CLI command. It asks the `heso-compliance` Rust engine to
mint your **operator identity**, writes a starter `heso.toml`, and adds the local
data directory to `.gitignore`. It is idempotent — an existing key and policy are
left as-is. It leaves:

```
heso_bootstrap.py   # import heso; heso.init()
heso.toml           # starter policy from the Rust engine (first-match-wins rules)
.heso/              # minted Ed25519 operator key + JSONL audit chain + outbox (gitignored)
```

The engine runs only at `init` (to mint identity and the starter policy). After
that, gating, signing, and the audit chain run **in-process** via the bundled
`heso._core` wheel — no subprocess. Never commit `.heso/`: the signing key, audit
log, and outbox live there and stay on the machine.

## Cloud API

Base URL is your endpoint; auth is a bearer token scoped to one team.

```
Authorization: Bearer <API_KEY>
Content-Type: application/json
```

Get the API key from the dashboard (Settings / Billing). It scopes to a single
team.

| Method | Path | Body | Returns |
| --- | --- | --- | --- |
| GET | `/v1/teams/{teamId}/policy` | — | `{ version, rules[], fetchedAt }` |
| POST | `/v1/receipts` | `ActionReceipt` | `{ receiptId, accepted, rejectionReason? }` |
| POST | `/v1/receipts/batch` | `{ receipts[] }` | `OutboxPushResult[]` |
| POST | `/v1/approvals` | `{ receipt, routingHint? }` | `{ approvalId, token?, expiresAt }` |
| GET | `/v1/approvals/{approvalId}` | — | `{ outcome, approval? }` |
| POST | `/v1/approvals/{approvalId}/token` | `{ token }` | `Approval` |

The server **re-verifies** every receipt through the same Rust core before
accepting it — a tampered or under-signed receipt is rejected at the control plane,
not just locally.

### Status codes

| Code | Meaning |
| --- | --- |
| 400 | Malformed JSON or schema validation failure |
| 401 | Invalid API key |
| 404 | Not found |
| 422 | Receipt failed server re-verification |
| 429 | Rate limited (honor `Retry-After`) |
| 503 | Server at capacity (honor `Retry-After`) |

## Environment variables

Used by the Python SDK (`heso.init()` resolves explicit args → env → `heso.toml`
→ defaults) and the TS SDK (`configure`):

| Var | Used for |
| --- | --- |
| `HESO_API_KEY` | Cloud bearer token (TS `configure`). |
| `HESO_ENDPOINT` | Cloud base URL (TS `configure`). |
| `HESO_PROJECT_ROOT` | Where to discover `heso.toml` / `.heso/`. |
| `HESO_WORKFLOW` | Default workflow label for captured actions. |
| `HESO_ACCOUNT` | Default account. |
| `HESO_BLOCKING` | Default blocking mode (default `true`). |
| `HESO_CLOCK` | Clock override (testing). |
| `HESO_TIMEOUT` | Engine call timeout. |
| `HESO_BIN` | Path to the engine binary. |

**Needs the API key:** `pullPolicy`, `pushReceipt(s)`, `openApproval`,
`pollApproval`, `waitForApproval`, `submitApprovalToken`.
**Needs nothing (local, offline):** `gate`, `assertGate`, all signing, hashing,
redaction, and the browser WASM verify.
