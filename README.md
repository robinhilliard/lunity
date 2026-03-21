<div align="center">
  <img src="assets/lunity_logo.png" alt="Lunity Logo" title="Lunity Logo" width="300">
  <p>
    A 3D Multiplayer Game Engine and Development Environment for Elxir, based on EAGL, NX and Luerl.
  </p>
</div>

# Overview

Game engine and editor utilities for EAGL. Provides scene, entity, and prefab DSLs, an Nx-backed component system with tensor and structured storage, game instance management, a Lua mod system for data-driven content and runtime scripting, file watching for auto-reload, and MCP tooling for agent-driven development.

**Phase 0 (player session spikes S0–S6):** [docs/phase0_findings.md](docs/phase0_findings.md).

## Player WebSocket protocol (`/ws/player`)

Game clients connect over WebSockets with a **small versioned JSON** envelope on each message:

```json
{ "v": 1, "t": "<message_type>", ... }
```

**Bootstrap sequence**

1. **Connect** — Handshake auth (see below).
2. **`welcome`** — Server pushes `{ "v": 1, "t": "welcome", "protocol": 1 }`.
3. **`hello`** → **`hello_ack`** — Capability / version handshake.
4. **`auth`** — `{ "token": "<JWT>" }` → **`ack`** with `user_id` and `player_id`, or **`error`**. JWTs are HS256 and validated by [`Lunity.Auth.PlayerJWT`](lib/lunity/auth/player_jwt.ex) (claims `user_id`, optional `player_id`).
5. **`join`** → **`assigned`** or **`error`**.
   - **Client-driven** (only when `config :lunity, :player_join` is **unset**): `{ "instance_id": "...", "entity_id": "...", "spawn": { ... } }` — client must name an existing instance; `spawn` is game-defined.
   - **Server-assigned** (`config :lunity, :player_join, {MyApp.PlayerJoin, :assign}`): body must be `{}` or `{ "hints": { ... } }` only. Top-level **`instance_id`**, **`entity_id`**, and **`spawn`** are **rejected** (anti-cheat). The callback returns authoritative assignment — see [`Lunity.Web.PlayerJoin`](lib/lunity/web/player_join.ex).
6. **`actions`** — Semantic input: `{ "frame": <int>, "actions": [ { "entity", "op", ... } ] }` → **`actions_ack`**. Mods read these via `lunity.input.actions_for_entity/1` in Lua.
7. Optional **`subscribe_state`** — `{ "filter": null }` for **full ECS** snapshot in periodic **`state`** messages; `filter` is reserved for future spatial / component subsetting. **`unsubscribe_state`** stops pushes.

Legacy ping: `{ "type": "ping" }` is still accepted and answered with **`pong`**.

**Handshake auth (connect)**

| Mechanism | Purpose |
|-----------|---------|
| Query string | `GET /ws/player/websocket?token=<shared_secret>` — must match `:player_ws_token` (fail closed if unset). |
| `Sec-WebSocket-Protocol` | If the endpoint enables Phoenix `auth_token: true`, a token may be sent per [Phoenix WebSocket auth](https://hexdocs.pm/phoenix/Phoenix.Endpoint.html#socket/3-websocket-configuration); it is exposed as `connect_info[:auth_token]` and accepted as an alternative to `?token=`. |

**Minting JWTs (dev / trusted backend)**

When `:player_mint_secret` is set, `POST /api/player/token` with header `X-Player-Mint-Key` and JSON body `{ "user_id": "...", "player_id": "..." }` returns `{ "token": "<JWT>" }` signed with `:player_jwt_secret`. **Disable in production** or protect behind your own gateway. OAuth flows should mint this JWT (or a session that yields it) from your Phoenix web pipeline—not from game clients holding long-lived mint keys.

**Configuration (`config/config.exs`, per-env under `config/dev.exs` / `config/prod.exs`)**

| Key | Meaning |
|-----|---------|
| `:player_ws_token` | Shared secret for WebSocket upgrade (required for connections unless you rely solely on subprotocol token + matching config). |
| `:player_jwt_secret` | HS256 secret for player JWTs used in `auth`. |
| `:player_mint_secret` | Optional; enables `POST /api/player/token`. |
| `:player_state_push_interval_ms` | Interval for `subscribe_state` **`state`** pushes (default `100`). |
| `:player_join` | Optional `{module, function}` — server assigns instance/entity/spawn on **`join`** (omit `instance_id` from the client). |

**Development defaults** — In this repo, `config/dev.exs` sets non-nil placeholders (`dev_player_ws_token`, `dev_player_jwt_secret`, `dev_player_mint_key`) so a local HTTP endpoint can accept `PlayerSocket` and mint. **`MIX_ENV=test` keeps `nil` from `config.exs`** (tests use `Application.put_env`). Game apps (e.g. **lunity-pong**) should mirror the same `:lunity` keys in **their** `config/dev.exs` when you run the server from that project.

### Phase 3 — client parity (next)

**Where the two clients live**

- **WebGL (browser)** — The **game app’s Phoenix** serves the player shell (static assets + a minimal page/route). For example, **lunity-pong** runs the server and **hosts** the WebGL client; Lunity defines the **protocol and shared expectations**, not necessarily the HTML entrypoint for every game.
- **Elixir desktop** — Implemented **in Lunity**: a small **desktop** process that takes the **game server base URL** on the **command line** (and dev-only flags for tokens/JWT as needed), opens a WebSocket to `/ws/player`, and runs the same bootstrap as the browser. It can start **headless** (transcript / parity) and later attach to **wx + EAGL** for real input and rendering. **Headless CLI:** `mix lunity.player` (see `mix help lunity.player`) connects with [WebSockex](https://hex.pm/packages/websockex), performs `welcome` → `hello` → `auth` → `join` (hints only; no instance override), prints `ack` / `assigned`, or **`--auth-only`** for handshake testing without `join`. **Important:** `mix lunity.edit` (which serves port 4111) must be run from the **game** Mix project when you rely on `config :lunity, :player_join`; running it from the `lunity` repo alone leaves `player_join` unset, so `mix lunity.player` fails with `instance_id required`.

**Why duplicate “browser” work on the desktop**

The native client will **reimplement** many things the browser bundles for free (WebSocket ergonomics, timing, input, audio, GL context lifecycle). That overlap is **intentional**: the **multi-platform promise** is one **frozen wire protocol** and shared **engine contracts**, with **multiple shells**—not one shell pretending to be the only client.

**Parity work**

- **Golden transcripts** — In-process protocol checks live in [`test/lunity/web/player_transcript_test.exs`](test/lunity/web/player_transcript_test.exs); extend these with the same JSON lines you expect from desktop and WebGL shells.
- **Desktop / WebGL** — Both follow the same ordered bootstrap (`welcome` → `hello` → `auth` → …) and message shapes; frame timing may differ, **transcript** should match.

## Design goals

- **BEAM + wx for engine and editor** — The simulation and authoring environment run on the **BEAM**. The editor uses **wxWidgets** and OpenGL (eagl) for the viewport; it is not driven by a separate native shell such as SDL for authoring.
- **WebGL clients** — Game clients target the **browser** (WebGL). Multiplayer and shared assets assume web clients alongside the server-side engine.
- **Portable contracts; Web APIs as the compatibility reference** — Cross-platform features (PCM audio, gamepads, timing visible to game code) are defined by **stable contracts** at the engine boundary. Where the web exposes a standard, **browser APIs set the reference semantics** (e.g. Web Audio–style PCM streaming, [W3C Gamepad API](https://w3c.github.io/gamepad/) button and axis ordering). Native Rustler NIFs under `native/` implement those semantics; low-level types from a specific library (PortAudio, SDL, etc.) must not leak into Elixir game or Lua APIs.
- **Optional alternate native players** — A future standalone native client (e.g. SDL + GL) would be an **optional** alternative to WebGL, not a second source of truth: it must satisfy the same contracts as the web stack.

## Project structure

When Lunity is a dependency, your game's layout:

```
lib/
  my_game/
    manager.ex    # use Lunity.Manager (components, systems, tick loop)
    scenes/       # Scene modules (use Lunity.Scene)
    prefabs/      # Prefab modules (use Lunity.Prefab)
    entities/     # Entity modules (use Lunity.Entity)
    components/   # Component modules (use Lunity.Component)
    systems/      # System modules (use Lunity.System)
priv/
  prefabs/
    *.glb         # Visual assets (referenced by prefab modules)
  mods/
    base/         # Base game mod (Lua)
      mod.lua
      data.lua
      control.lua
      assets/
        prefabs/
          *.glb
```

## Component system

Lunity provides its own ECS component system built on Nx tensors and ETS. Components come in two storage flavours, both sharing a common API for individual entity access.

### Tensor components

Numeric data stored as Nx tensors in contiguous memory. Processed every tick by `defn` systems that operate on entire tensors at once -- no per-entity iteration loops. This runs on CPU today (via Nx.BinaryBackend or EXLA) and can target GPU (CUDA via EXLA) with zero code changes when deployed to servers with GPUs.

```elixir
defmodule MyGame.Components.Position do
  use Lunity.Component,
    storage: :tensor,
    shape: {3},       # {x, y, z} per entity
    dtype: :f32
end

defmodule MyGame.Components.Speed do
  use Lunity.Component,
    storage: :tensor,
    shape: {},         # scalar per entity
    dtype: :f32
end
```

All tensor components share the same entity indexing. Row `i` of every tensor belongs to the same entity. The "zip" across multiple components is free -- just aligned memory access, no hash lookups.

### Structured components

Arbitrary Elixir terms stored in ETS. For variable-length or non-numeric data (inventories, names, quest state) that changes infrequently and is handled by event-driven code rather than tick processing.

```elixir
defmodule MyGame.Components.Inventory do
  use Lunity.Component,
    storage: :structured

  # get/1, put/2, remove/1, exists?/1, all/0
end

defmodule MyGame.Components.PlayerName do
  use Lunity.Component,
    storage: :structured,
    index: true          # enables search/1 for fast value-based lookup
end
```

### Common API

Both storage types implement:

- `get(entity_id)` -- get a component value for an entity
- `put(entity_id, value)` -- set a component value
- `remove(entity_id)` -- remove a component from an entity
- `exists?(entity_id)` -- check if an entity has this component

Tensor components additionally expose:

- `tensor()` -- returns the raw Nx tensor for batch processing
- `put_tensor(t)` -- replaces the tensor (called by the system runner)

Structured components additionally expose:

- `all()` -- returns all `{entity_id, value}` pairs
- `search(value)` -- returns entity IDs with the given value (requires `index: true`)

### ComponentStore

The `Lunity.ComponentStore` GenServer manages all component storage:

- **Tensor storage**: Nx tensors held in an ETS table. Storing an Nx tensor in ETS copies only the small struct, not the underlying native memory buffer.
- **Entity registry**: Maps symbolic entity IDs (`{"pong_1", :ball}`) to integer tensor indices and back. O(1) lookup in both directions.
- **Structured storage**: Per-component ETS tables with optional index tables.
- **Auto-growth**: Tensor capacity doubles automatically when entity count exceeds the current allocation.

## Systems

Systems process component data each tick. The `Lunity.System` behaviour supports tensor and structured types.

### Tensor systems

Declare which components they read and write. The framework reads the tensors, passes them as a map to the system's `defn run/1`, and writes the returned tensors back.

```elixir
defmodule MyGame.Systems.MoveBall do
  use Lunity.System,
    type: :tensor,
    reads: [MyGame.Components.Position, MyGame.Components.Velocity],
    writes: [MyGame.Components.Position]

  import Nx.Defn

  defn run(%{position: pos, velocity: vel}) do
    %{position: Nx.add(pos, vel)}
  end
end
```

Map keys are derived from the component module name: `MyGame.Components.Position` becomes `:position`.

Systems are instance-agnostic -- they process ALL entities across ALL game instances in one pass. This is correct because all instances run the same game. An entity with zero velocity simply doesn't move.

### Structured systems

A function mapped over each entity that has the declared components:

```elixir
defmodule MyGame.Systems.DecayBuffs do
  use Lunity.System,
    type: :structured,
    reads: [MyGame.Components.ActiveBuffs],
    writes: [MyGame.Components.ActiveBuffs]

  def run(_entity_id, %{active_buffs: buffs}) do
    %{active_buffs: Enum.reject(buffs, &expired?/1)}
  end
end
```

### Masking and conditional logic

Not all entities have all components. Entities without a component have zero values in the tensor. Systems use `Nx.select` for conditional logic:

```elixir
defn run(%{position: pos, speed: speed, paddle_control: ctrl}) do
  is_auto = Nx.equal(ctrl, 0)
  has_speed = Nx.greater(speed, 0)
  should_move = Nx.logical_and(is_auto, has_speed)
  move = Nx.select(should_move, calculated_move, 0.0)
  # ...
end
```

## Manager

The game defines a module that `use`s `Lunity.Manager`:

```elixir
defmodule MyGame.Manager do
  use Lunity.Manager

  @impl true
  def components do
    [
      Lunity.Components.InstanceMembership,
      MyGame.Components.Position,
      MyGame.Components.Velocity
    ]
  end

  @impl true
  def systems do
    [
      MyGame.Systems.MoveBall,
      MyGame.Systems.BounceWalls
    ]
  end

  @impl true
  def setup do
    Lunity.Instance.start(MyGame.Scenes.Level1)
  end

  # Optional: default is 20
  @impl true
  def tick_rate, do: 30
end
```

The manager starts the ComponentStore, registers all components, runs `setup/0`, and starts the tick loop calling each system in order.

## Game instances

A `Lunity.Instance` represents a running game. Multiple instances can run simultaneously -- each with its own entities in the shared component tensors.

Entity IDs are scoped to instances: `{"pong_1", :ball}` vs `{"pong_2", :ball}`. Systems process all entities across all instances in one pass (the "zip" is free), and `Lunity.Components.InstanceMembership` (a structured component with an index) provides fast lookup of all entities in a specific instance.

```elixir
# Start a new game instance
{:ok, _pid} = Lunity.Instance.start(MyGame.Scenes.Level1, id: "game_42")

# List all active instances
Lunity.Instance.list()  # => ["game_42", "game_43"]

# Stop an instance (deallocates all its entities)
Lunity.Instance.stop("game_42")
```

### GPU path

Tensor components and `defn` systems run on Nx.BinaryBackend (CPU) during development. In production on a server with an NVIDIA GPU, switching to EXLA with CUDA runs the same `defn` code on GPU with massive parallelism -- no code changes needed. Since game clients render in the browser, the server GPU is free for compute.

## Editor

Run from your game project:

```bash
mix lunity.edit
```

This starts the Lunity editor with:

- wxWidgets/OpenGL viewport with orbit camera
- Scene hierarchy tree
- Live game instance viewing
- MCP server for agent-driven development (see below)
- File watcher for auto-reload on changes to `priv/config/`, `priv/scenes/`, and `priv/prefabs/` (debounced 300ms). If `inotify-tools` is not installed (Linux/WSL2), the watcher logs a warning and continues without file watching.

## MCP server

Configure Cursor (`.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "lunity": {
      "url": "http://localhost:4111/sse"
    }
  }
}
```

Call **set_project** first with `cwd` (and optional `app`). Port 4111 (override with `LUNITY_HTTP_PORT`).

**Tools**: `set_project`, `project_structure`, `scene_load`, `scene_get_hierarchy`, `get_blender_extras_script`, `editor_get_context`, `editor_set_context`, `editor_push`, `editor_pop`, `editor_peek`, `view_list`, `view_capture`, `entity_list`, `entity_get`, `entity_at_screen`, `node_screen_bounds`, `camera_state`, `view_annotate`, `highlight_node`, `clear_annotations`, `pause`, `step`, `resume`, `entity_set`

## Three DSLs

Lunity provides three parallel DSLs for defining scenes, entities, and prefabs. All use module atoms for references, giving go-to-definition, autocomplete, and undefined-module warnings in ElixirLS.

### Scene DSL

Scenes are structural containers that define where things go. They have no properties of their own and no Blender counterpart. Use `use Lunity.Scene`:

```elixir
defmodule MyGame.Scenes.Level1 do
  use Lunity.Scene

  scene do
    node :arena,  scene: MyGame.Scenes.Arena, position: {0, 0, 0}
    node :player, prefab: MyGame.Prefabs.Character, entity: MyGame.Player,
                  position: {0, 0, 1}, properties: %{health: 100}
    node :floor,  prefab: MyGame.Prefabs.Box, position: {0, -1, 0}, scale: {10, 0.1, 10}
  end
end
```

Scenes can nest other scenes (Godot-style composition). Sub-scene nodes are grafted as children with the parent transform applied. No override/variant system.

### Entity DSL

Entities define what things do -- game logic, components, and properties visible in the Lunity editor. Use `use Lunity.Entity` (optionally with `config: "path"` for default config relative to `priv/config/`):

```elixir
defmodule MyGame.Player do
  use Lunity.Entity

  entity do
    property :health, :integer, default: 100, min: 0
    property :speed,  :float,   default: 5.0
  end

  @impl Lunity.Entity
  def init(config, entity_id) do
    MyGame.Components.Position.put(entity_id, Map.get(config, :position, {0, 0, 0}))
    MyGame.Components.Speed.put(entity_id, config.speed)
    :ok
  end
end
```

### Prefab DSL

A Lunity prefab is a visual asset (.glb) with typed properties -- no nesting, no variants, no override chains. Prefab properties are visual/physical and editable in Blender. Use `use Lunity.Prefab`:

```elixir
defmodule MyGame.Prefabs.Door do
  use Lunity.Prefab, glb: "door"

  prefab do
    property :open_angle, :float,
      default: 90.0, min: 0.0, max: 180.0,
      soft_min: 15.0, soft_max: 120.0,
      subtype: :angle,
      description: "Maximum angle the door opens to"

    property :tint, :float_array,
      length: 4, default: [0.5, 0.5, 0.5, 1.0],
      subtype: :gamma_color,
      description: "Tint color (RGBA)"
  end
end
```

The `get_blender_extras_script` MCP tool generates Python from prefab schemas to create matching Blender custom properties with full metadata (min/max, soft limits, step, precision, subtype, description).

## Node options

- `:prefab` - Prefab module or string ID (e.g. `MyGame.Prefabs.Box` or `"box"`)
- `:entity` - Entity module atom (e.g. `MyGame.Player`)
- `:scene` - Scene module atom for sub-scene composition (mutually exclusive with `:prefab`)
- `:config` - Config path for entity defaults (relative to `priv/config/`)
- `:properties` - Map of per-instance property values (merged with config; instance values win)
- `:position` - `{x, y, z}` tuple or `[x, y, z]` list
- `:scale` - `{x, y, z}` tuple or `[x, y, z]` list
- `:rotation` - `{x, y, z, w}` quaternion

A node can have:
- Just `prefab:` -- static visual, no game logic (scenery)
- Both `prefab:` and `entity:` -- interactive game object (the common case)
- Just `scene:` -- sub-scene composition

## Property separation

Prefab and entity properties occupy different domains:

- **Prefab properties** -- visual/physical, intrinsic to the mesh, editable in Blender (colour, material, hinge offset). A prefab can be used by many entity types.
- **Entity properties** -- game logic, specific to the entity type, visible in the Lunity editor (health, speed, side). Meaningless without the entity module.

When a node has both a prefab and an entity, their property schemas must not overlap. Lunity detects conflicts at load time and raises a clear error.

### Property types

- `:string` - Binary string
- `:integer` - Integer with optional `min:`, `max:` constraints
- `:float` - Number with optional `min:`, `max:` constraints
- `:atom` - Atom with optional `values: [...]` constraint
- `:boolean` - Boolean
- `:module` - Module atom (verified loaded at validation time)
- `:float_array` - List of floats with `:length`
- `:integer_array` - List of integers with `:length`
- `:boolean_array` - List of booleans with `:length`

### Blender metadata options

Prefab properties support the full set of Blender custom property metadata:

- `:default` - Default value (Blender's "Reset to Default")
- `:min`, `:max` - Hard limits
- `:soft_min`, `:soft_max` - Soft limits (UI slider range)
- `:step` - Increment multiplier
- `:precision` - Decimal digits displayed (floats)
- `:subtype` - UI hint (`:angle`, `:percentage`, `:factor`, `:distance`, `:linear_color`, `:gamma_color`, `:euler`, `:quaternion`, etc.)
- `:description` - Tooltip text

### Merge order at load time

```
prefab module defaults  <-  Blender glTF extras  =  visual config
entity module defaults  <-  scene properties       =  game config
                                ↓
                entity.init(merged_config, entity_id)
```

## Scene resolution order

When `SceneLoader.load_scene` is called with a string path:

1. **Scene builders** - Explicit `{Module, :function}` in `:lunity, :scene_builders` config
2. **Mod data** - Scene definitions from `data:extend()` in Lua mods (see below)
3. **Scene module** - By convention: path `"pong"` resolves to `{App}.Scenes.Pong`
4. **Config file** - `priv/config/scenes/<path>.exs` returning `%Lunity.Scene.Def{}`
5. **glTF file** - `priv/scenes/<path>.glb`

When called with a module atom, the module's `__scene_def__/0` is used directly.

## Lua mod system

Lunity includes a Factorio-style Lua plugin system powered by [luerl](https://github.com/rvirding/luerl). Mods can define scenes, prefabs, and entities via Lua (data stage) and register event handlers for game logic (runtime stage). The mod system is optional -- enable it with `config :lunity, mods_enabled: true`.

### Mod layout

Each mod lives in a subdirectory of `priv/mods/`:

```
priv/mods/
  base/
    mod.lua                # Required: metadata
    data.lua               # Data stage: define prototypes
    data-updates.lua       # Optional: patch other mods' data
    data-final-fixes.lua   # Optional: final adjustments
    control.lua            # Runtime stage: event handlers
    assets/
      prefabs/
        *.glb              # Mod-specific visual assets
```

### mod.lua

Every mod must have a `mod.lua` that returns a metadata table:

```lua
return {
  name = "base",
  version = "1.0.0",
  title = "My Game",
  dependencies = {}        -- list of mod names this mod depends on
}
```

Mods are topologically sorted by dependencies. Circular dependencies are rejected.

### Data stage

A shared Lua state runs each mod's data files in dependency order. Three files are executed per mod (missing files are skipped):

1. `data.lua` -- initial prototype definitions
2. `data-updates.lua` -- modifications to existing prototypes
3. `data-final-fixes.lua` -- final adjustments

The `data:extend()` function registers prototypes. Each prototype has a `type` and `name`:

```lua
data:extend({
  {
    type = "scene",
    name = "arena",
    nodes = {
      { name = "floor", prefab = "box", position = {0, -1, 0}, scale = {10, 0.1, 10} },
      { name = "player", prefab = "character", entity = "player",
        properties = { health = 100 }, position = {0, 0, 1} },
    }
  },
  {
    type = "prefab",
    name = "character",
    glb = "character",
    properties = {
      { name = "tint", type = "float_array", length = 4,
        default = {1, 1, 1, 1}, subtype = "gamma_color" }
    }
  },
  {
    type = "entity",
    name = "player",
    properties = {
      { name = "health", type = "integer", default = 100, min = 0 },
      { name = "speed",  type = "float",   default = 5.0 }
    }
  }
})
```

Scenes defined in mod data are available via string-based `SceneLoader.load_scene/2` (see resolution order above). Prefab GLB files are resolved from the defining mod's `assets/prefabs/` directory.

### Runtime stage

Each mod gets its own isolated, sandboxed Lua state. Unsafe globals (`io`, `os`, `debug`, `load`, `require`, etc.) are stripped. The `lunity.*` API is injected and `control.lua` is executed:

```lua
lunity.on("on_init", function(event)
  local player = lunity.entity.find("player")
  lunity.log("Player entity:", player)
end)
```

#### Lua API

| Function | Description |
|----------|-------------|
| `lunity.on(event, handler)` | Register an event handler |
| `lunity.log(...)` | Log a message |
| `lunity.entity.get(id, property)` | Get entity property value |
| `lunity.entity.set(id, property, value)` | Set entity property value |
| `lunity.entity.find(name)` | Find entity by name |
| `lunity.entity.spawn(name, overrides?)` | Spawn entity instance |
| `lunity.entity.destroy(id)` | Destroy entity |
| `lunity.scene.get_node(name)` | Get scene node info |
| `lunity.scene.set_node_position(name, x, y, z)` | Set node position |
| `lunity.input.is_key_down(key)` | Check if key is pressed |

Event handlers are dispatched in mod load order. Handler errors are logged but do not stop dispatch to subsequent handlers.

### Resource limits

Lua execution is sandboxed with configurable limits:

```elixir
config :lunity,
  mod_instruction_limit: 1_000_000,   # max instructions per script execution
  mod_handler_timeout: 5_000,         # ms timeout for event handlers
  mod_max_state_size: 10_000_000      # bytes limit for luerl state
```

## Installation

```elixir
def deps do
  [
    {:lunity, "~> 0.1.0", path: "../lunity"}
  ]
end
```

Lunity depends on [EAGL](https://github.com/robinhilliard/eagl) for rendering, [Nx](https://github.com/elixir-nx/nx) for tensor-backed components, and [luerl](https://github.com/rvirding/luerl) for the Lua mod system.

### Requirements

Erlang/OTP 25+ with wx support, Elixir 1.17+, OpenGL 3.3+, and Rust (for the gilrs gamepad NIF). The `.tool-versions` is set to `system` on macOS (Homebrew) and overridden to asdf versions on Linux/WSL2.

#### macOS

Use Homebrew for Erlang and Elixir. Do **not** use asdf-installed Erlang — it links against wxWidgets at build time and breaks when Homebrew upgrades wxWidgets.

```bash
brew install erlang elixir rust
```

Verify: `elixir --version` should show matching OTP versions (e.g. "compiled with Erlang/OTP 26" when running OTP 26). Mismatched versions cause `nif_not_loaded` errors on `:gl.*` calls. See [EAGL README — Installing Erlang and Elixir on macOS](https://github.com/robinhilliard/eagl#installing-erlang-and-elixir-on-macos) for details and alternatives.

**Cursor/ElixirLS**: If ElixirLS shows "Failed to run elixir check command", launch Cursor from the terminal (`cursor .`) so it inherits your shell PATH.

#### Linux / WSL2

The apt Erlang/Elixir packages on Debian/Ubuntu are typically too old (e.g. Elixir 1.14 vs the required 1.17). Use [asdf](https://asdf-vm.com/) instead and update `.tool-versions` to point at the installed versions:

```bash
# Erlang and Elixir via asdf
asdf plugin add erlang
asdf plugin add elixir
asdf install erlang 27.1
asdf install elixir 1.17.3-otp-27
```

Then set `.tool-versions` in the lunity workspace:

```
erlang 27.1
elixir 1.17.3-otp-27
```

Install system libraries and Rust (needed for the gilrs gamepad NIF):

```bash
# OpenGL, wx, file watching, and gilrs NIF dependencies
sudo apt install libgl1-mesa-dev libglu1-mesa-dev inotify-tools libudev-dev pkg-config

# Rust (for gilrs gamepad NIF)
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source "$HOME/.cargo/env"
```

`inotify-tools` is needed for file watching (auto-reload on changes). `libudev-dev` and `pkg-config` are required by the gilrs crate (native gamepad input). WSL2 works for development but OpenGL runs through a software layer — expect lower frame rates and input lag. Game controllers attached to the Windows host are not visible in WSL2 without a custom kernel rebuild; use native Windows instead for gamepad testing.

#### Windows

Install Erlang/OTP and Elixir using the official install script. From PowerShell:

```powershell
curl.exe -fsSO https://elixir-lang.org/install.bat
.\install.bat elixir@1.18.4 otp@27.3.4.7
```

Then add the paths it prints to your `$env:PATH` (or `$PROFILE`):

```powershell
$env:PATH = "$env:USERPROFILE\.elixir-install\installs\otp\27.3.4.7\bin;$env:PATH"
$env:PATH = "$env:USERPROFILE\.elixir-install\installs\elixir\1.18.4-otp-27\bin;$env:PATH"
```

Install Rust and Visual Studio Build Tools (needed for the gilrs gamepad NIF):

```powershell
winget install Microsoft.VisualStudio.2022.BuildTools --override '--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended'
winget install Rustlang.Rustup
```

The `.tool-versions` `system` setting works correctly on Windows since Erlang/Elixir are installed system-wide. Game controllers are detected natively via Windows Gaming Input (WGI) — no USB passthrough needed.

### Editor shutdown crash (SIGSEGV)

On macOS, closing the editor window can occasionally trigger a segmentation fault in `wxAppBase::ProcessIdle` (null pointer dereference). This is a known race between the wx event loop and VM shutdown. A 300ms delay before `System.stop(0)` mitigates it in most cases. If you still see crash reports when closing the editor, the application has already shut down cleanly; the crash occurs during final teardown and does not indicate data loss.

## Coordinate system

Right-handed XYZ, Y up. Horizon plane is XZ.

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be found at <https://hexdocs.pm/lunity>.
