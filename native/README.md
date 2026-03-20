# Native crates (Rustler NIFs)

Rust crates in this directory provide platform services (audio, input, etc.) to Elixir. Each crate is built as a `cdylib` and loaded via [Rustler](https://github.com/rusterlium/rustler).

## Web / native compatibility

Engine-facing APIs should stay **independent of any one native library**. The **browser stack is the compatibility reference** for anything that also exists on the web:

| Area | Reference | Native crates here |
|------|-----------|-------------------|
| Streaming PCM output | Web Audio (buffers / worklet → speakers) | `lunity_audio` (PortAudio) |
| Gamepads | [W3C Gamepad API](https://w3c.github.io/gamepad/) (axis and button order) | `lunity_gamepad` ([gilrs](https://docs.rs/gilrs/), mapped to that order) |

Rules of thumb:

1. **Contracts live in Elixir** (`Lunity.Audio.*`, `Lunity.Input.*`, etc.) — sample rates, channels, gamepad state shape, not raw crate types.
2. **Swapping backends** (e.g. PortAudio → SDL audio, gilrs → SDL game controller) should be an internal change inside a crate or a parallel crate, without changing game or Lua code.
3. **Editor** stays on **wx + OpenGL**; these crates do not own the editor window.
4. **WebGL vs future native shell** — A hypothetical SDL-based player would still implement the same PCM and input contracts as WebGL clients; SDL is implementation detail, not the API definition.

Some crates (e.g. TrackIR) have **no web equivalent** and are optional or editor-focused; they are not part of the web parity contract.

## Crates

- **`lunity_audio`** — Callback-based PCM output via PortAudio.
- **`lunity_gamepad`** — Poll gamepads; state matches Web Gamepad standard layout.
- **`lunity_trackir`** — TrackIR SDK integration (platform-specific).

Build artifacts live under each crate’s `target/` directory (ignored by git).
