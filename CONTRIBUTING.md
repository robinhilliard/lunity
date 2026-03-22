# Contributing to Lunity

Lunity is a large surface area: ECS and instances, editor/wx, Lua mods, HTTP/WebSockets, Rustler NIFs (`native/`), and MCP tooling. This file is **project-wide** workflow; feature-specific notes live in the [README](README.md) and under [`docs/`](docs/).

## Before you open a PR

When you use Lunity as a **path dependency** (e.g. from **lunity-pong**), edits under `lunity/` are not picked up until you recompile from the **host** app: `mix deps.compile lunity --force` or `mix compile` there. The BEAM files loaded at runtime come from **`<host>/_build/.../lib/lunity`**, not `lunity/_build`.

The **`mix lunity.player_window`** task runs **`deps.compile lunity`** before compiling, and prints **`[lunity.player_window] Lunity.Player.StateWindow -> …/beam`** so you can confirm which file is loaded. In **lunity-pong**, **`mix pw`** is an alias that compiles the path dep first, then runs **`lunity.player_window`**.

- **Format:** `mix format`
- **Compile:** `mix compile --warnings-as-errors`
- **Tests:** `mix test` (requires Erlang/OTP with **wx** for the full suite, as in the README prerequisites)

`test/support/` holds helpers and is not run as tests (`test_ignore_filters` in `mix.exs`).

## Native code

Rust crates under `native/` are built as part of `mix compile` (Rustler). If you change NIFs, run a clean compile and tests on your platform.

## Player WebSocket (`/ws/player`)

If you change the game-client protocol, keep wire shapes and tests aligned:

- [`lib/lunity/web/player_wire.ex`](lib/lunity/web/player_wire.ex) — canonical maps for certain frames
- Tests: `test/lunity/web/player_transcript_test.exs`, `player_socket_integration_test.exs`, `player_socket_test.exs`
- Clients: `lib/lunity/player/ws_client.ex`, `priv/static/player_shell.js` (`live=1` streams `state.ecs`); **`mix lunity.player_window`** — wx window with the same live ECS stream

The full bootstrap and reconnect story is in the README section **Player WebSocket protocol (`/ws/player`)**.
