# Phase 0 spikes (S0–S6) — findings

End-to-end assumption checks before Phase 1 (player session module) and Phase 2 (protocol).

**Implementation touchpoints (this repo):** `Lunity.Web.PlayerSocket`, `test/lunity/web/player_socket_test.exs`, `Lunity.Input.SessionMeta`, `lib/lunity/input/session_meta.ex`.

**Sample game (`lunity-pong`):** `priv/mods/base/control.lua`, `test/pong/phase0_input_spike_test.exs` — exercises input → ECS in a game project that depends on Lunity.

---

## S0: Input → ECS — **passed**

Structured tick system reads `Lunity.Input.Session` + `SessionMeta` and writes `Position`. Covered by ExUnit in the pong project.

---

## S1: Session identity — **scoped; stable id deferred**

| Concept | Role |
|---------|------|
| `input_session_id` | ETS key (`ref()`), one per WebSocket / test |
| `player_id` | Optional stable id (auth / roster); stored on `SessionMeta` for future reconnect |
| `instance_id` | **Required** for gameplay binding — must equal `ComponentStore.current_store!/0` |

`make_ref()` alone is insufficient for reconnect or cross-tab identity; add tokens + `player_id` in Phase 2+.

**Test:** `S1: SessionMeta.instance_id scopes input…` — two instances, same `:paddle_left`, input only affects the bound instance.

---

## S2: Multi-session routing — **passed**

Two refs, two metas, one instance, different `entity_id` — paddles move independently.

---

## S3: Transport (ViewerSocket vs player) — **decision**

- **`Lunity.Web.ViewerSocket`** — legacy WebGL POC (orbit / watch). Not extended for players.
- **`Lunity.Web.PlayerSocket`** — canonical game client WebSocket at `/ws/player/websocket` (Phoenix path).
- No WebGL editor planned; authoring stays wx + EAGL.

---

## S4: Auth bootstrap — **spike implemented**

- **`Lunity.Web.PlayerSocket.connect/1`** requires query param `token` to equal `Application.get_env(:lunity, :player_ws_token)`.
- If `:player_ws_token` is unset or empty → **reject** (fail closed).
- Unit tests in `test/lunity/web/player_socket_test.exs` call `connect/1` directly (no browser).

**Next:** OIDC / signed tokens, pass token via query or `Sec-WebSocket-Protocol` (see Phoenix `auth_token` option), map to `user_id` / `player_id` on `SessionMeta`.

**Manual E2E:** start endpoint (e.g. `mix lunity.edit` or app that runs `Lunity.Web.Endpoint`), connect WebSocket to  
`/ws/player/websocket?token=<secret>` with `:player_ws_token` set in config.

---

## S5: EAGL shell — **reference path (no new binary)**

Existing flows validate wx + GL + input:

- `mix lunity.input_test` — [`Mix.Tasks.Lunity.InputTest`](../lib/mix/tasks/lunity.input_test.ex) + `EAGL.Window.run/3`.
- Pong / editor use the same stack for a future “player window”: register `Lunity.Input.Session`, wire capture, then (later) `PlayerSocket` in a separate process.

**Checklist for a future `player` Mix task:** `Application.ensure_all_started(:lunity)` → open `EAGL` window → `Session.register` → bind `SessionMeta` + connect WebSocket — same order as production.

---

## S6: WebGL shell / browser constraints — **policy**

Not implemented as code; constraints for Phase 3:

| Topic | Note |
|-------|------|
| **HTTP cache** | Versioned asset URLs + `Cache-Control` / immutable for static packs |
| **Storage** | Cache API / IndexedDB / OPFS for large blobs between sessions |
| **GPU** | Textures re-upload each session; network cache avoids re-download |
| **First load** | In-engine loading screen (no HTML game shell); long first loads are acceptable if budget allows |

---

## Config / test ergonomics (lunity-pong sample)

When using the pong project as a dependency app:

- `config/test.exs`: `mode: :runtime` — no wx editor during `mix test`.
- `Pong.Application` — `Application.ensure_all_started(:lunity)`.

## Lunity config

- `config :lunity, :player_ws_token, nil` — set in deploy or local `config/*.exs` for WebSocket clients.
