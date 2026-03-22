# Concepts and Terminology

This guide introduces Lunity's core concepts for readers new to game engines
and for experienced developers coming from Godot, Unreal, or Unity. Each
concept includes a concrete example from the Pong sample game.

For detailed internals, follow the links to the subsystem documentation.

---

## Entity

An entity is a named thing in the game world -- a ball, a paddle, a wall.
In Lunity, entities are not objects with methods; they are just identifiers
(atoms like `:ball` or `:paddle_left`) that components are attached to.

An entity *type* is an Elixir module that declares which components it uses
and how to initialise them. Here is a wall from Pong:

```elixir
defmodule Pong.Entities.Wall do
  use Lunity.Entity

  entity do
    component(Lunity.Components.Position)
    component(Lunity.Physics.Components.Velocity)
    component(Lunity.Physics.Components.BoxCollider)
    component(Lunity.Physics.Components.Static)
  end

  @impl Lunity.Entity
  def init(config, entity_id) do
    Position.put(entity_id, Map.get(config, :position, {0, 0, 0}))
    Velocity.put(entity_id, {0, 0, 0})
    BoxCollider.put(entity_id, Map.get(config, :scale, {1, 1, 1}))
    Static.put(entity_id, 1)
    :ok
  end
end
```

`init/2` receives a config map (from the scene definition) and the entity ID,
then sets the initial component values.

**Coming from other engines:**

| Engine | Equivalent | Key difference |
|--------|-----------|----------------|
| Unity | `GameObject` | Lunity entities have no `Transform` by default -- position is an explicit component |
| Godot | `Node` (loosely) | No inheritance hierarchy; entities are flat bags of components |
| Unreal | `AActor` | No blueprint system; use the Scene DSL or Lua mods instead |

Detailed internals: [ECS Core](subsystems/01_ecs_core.md)

---

## Component

A component is a piece of data attached to an entity. Lunity has two storage
flavours:

### Tensor components

Numeric data stored as contiguous [Nx](https://github.com/elixir-nx/nx)
tensors. Every entity occupies one row in a fixed-capacity tensor. Ideal for
data processed every tick by systems using GPU-style batch operations.

```elixir
defmodule Pong.Components.Speed do
  use Lunity.Component, storage: :tensor, shape: {}, dtype: :f32
end
```

This creates a scalar float per entity. The built-in `Position` component
uses `shape: {3}` for a 3D vector. `shape` and `dtype` follow Nx conventions.

### Structured components

Arbitrary Elixir terms stored in ETS tables. Ideal for non-numeric or
variable-length data (inventories, names, quest state) that changes
infrequently.

```elixir
defmodule MyGame.Components.Inventory do
  @type t :: [MyGame.Item.t()]
  use Lunity.Component, storage: :structured
end
```

Structured components require a `@type t` before `use`.

**Coming from other engines:**

| Engine | Equivalent | Key difference |
|--------|-----------|----------------|
| Unity | Fields on a `MonoBehaviour` | Lunity components are pure data, never behaviour |
| Godot | Node properties / resources | No inspector integration; use the Properties system for editable values |
| Unreal | `UActorComponent` data | No tick function on components; all logic lives in systems |

Detailed internals: [ECS Core](subsystems/01_ecs_core.md)

---

## System

A system is a function that runs once per tick, reading and writing
components. Systems contain all game logic -- components never have methods.

### Tensor system

Operates on full tensors at once using `Nx.Defn` (numerical definitions).
The framework reads declared tensors, passes them as a map, and writes the
returned tensors back.

```elixir
defmodule Pong.Systems.AutoPaddle do
  use Lunity.System, type: :tensor, entities: [:ball]

  alias Lunity.Components.{Position, DeltaTime}
  alias Pong.Components.{Speed, PaddleControl}

  @spec run(%{position: Position.t(), speed: Speed.t(),
              paddle_control: PaddleControl.t(),
              delta_time: DeltaTime.t()}) :: %{position: Position.t()}
  defn run(%{position: pos, speed: speed,
             paddle_control: ctrl, delta_time: dt} = inputs) do
    # ... batch-process all entities at once ...
    %{position: new_pos}
  end
end
```

The `@spec` on `run` declares which components are read (input map) and
written (output map). The framework derives this at compile time.

### Structured system

Operates on individual entities. The framework iterates entities that have
the declared components and calls `run/2` for each.

```elixir
defmodule MyGame.Systems.DecayBuffs do
  use Lunity.System, type: :structured

  @spec run(integer(), %{active_buffs: ActiveBuffs.t()}) :: %{active_buffs: ActiveBuffs.t()}
  def run(_entity_id, %{active_buffs: buffs}) do
    %{active_buffs: Enum.reject(buffs, &expired?/1)}
  end
end
```

**Coming from other engines:**

| Engine | Equivalent | Key difference |
|--------|-----------|----------------|
| Unity | `MonoBehaviour.Update()` | Systems process *all* entities with matching components, not one object at a time |
| Godot | `_process(delta)` on a node | Systems are standalone modules, not attached to scene nodes |
| Unreal | `USystem` / tick groups | Lunity systems are ordered explicitly in the Manager's `systems/0` list |

Detailed internals: [ECS Core](subsystems/01_ecs_core.md)

---

## Scene

A scene is a declarative tree of nodes that defines the layout of a game
world. Each node can have a position, scale, rotation, a prefab (visual
geometry), an entity binding (game logic), materials, and lights.

```elixir
defmodule Pong.Scenes.Pong do
  use Lunity.Scene

  scene do
    node :floor,        prefab: Pong.Prefabs.Box,
                         position: {0, -0.5, 0}, scale: {30, 1, 18}
    node :paddle_left,  prefab: Pong.Prefabs.Box, entity: Pong.Entities.Paddle,
                         position: {-14, 1.5, 0}, scale: {1, 1, 3},
                         properties: %{side: :left}
    node :ball,         prefab: Pong.Prefabs.Box, entity: Pong.Entities.Ball,
                         position: {0, 1.5, 0}, scale: {1, 1, 1}
  end
end
```

Scenes support composition -- a node can reference another scene module
via `scene:`, embedding it as a subtree (similar to Godot's instanced
scenes).

**Coming from other engines:**

| Engine | Equivalent | Key difference |
|--------|-----------|----------------|
| Unity | Scene (.unity) | Lunity scenes are code, not binary files; loaded via a 5-source resolution pipeline |
| Godot | PackedScene (.tscn) | Compiled modules with full IDE support; can also be `.exs` config files or Lua mod data |
| Unreal | Level / World | No streaming or sublevel system; scenes are loaded atomically |

Detailed internals: [Scene and Prefab Loading](subsystems/02_scene_and_prefab.md)

---

## Prefab

A prefab is a reusable visual asset -- a `.glb` file in `priv/prefabs/` --
with optional typed properties. Prefabs provide geometry and materials;
entities provide game logic. A scene node often has both.

```elixir
defmodule Pong.Prefabs.Box do
  use Lunity.Prefab, glb: "box"

  prefab do
    # properties would go here, e.g.:
    # property :color, :float_array, length: 4, default: [1, 1, 1, 1]
  end
end
```

When a scene node references `prefab: Pong.Prefabs.Box`, the loader opens
`priv/prefabs/box.glb`, builds GPU-ready meshes, and clones the scene graph
into the parent node.

**Coming from other engines:**

| Engine | Equivalent | Key difference |
|--------|-----------|----------------|
| Unity | Prefab (.prefab) | Lunity prefabs are visual-only; game logic is on the entity, not baked into the prefab |
| Godot | PackedScene used as prefab | No variant/override chains; properties are flat and validated at compile time |
| Unreal | Blueprint / Static Mesh | GLB is the only supported format; PBR materials from Blender export directly |

Detailed internals: [Scene and Prefab Loading](subsystems/02_scene_and_prefab.md)

---

## Instance

An instance is one running copy of a game. Each instance has its own
ComponentStore (isolated ETS tables and tensors), its own entity set, and its
own tick loop. You can run multiple instances in parallel -- for example, one
Pong game per match.

```elixir
{:ok, _pid} = Lunity.Instance.start(Pong.Scenes.Pong, manager: Pong.Manager)
```

Instances can be paused, stepped, snapshotted, cloned, and run
deterministically with `run_ticks/2` for testing.

**Coming from other engines:**

| Engine | Equivalent | Key difference |
|--------|-----------|----------------|
| Unity | No direct equivalent | Unity has one world; Lunity isolates each game in its own store |
| Godot | SceneTree (one per process) | Lunity can run many instances in the same BEAM process |
| Unreal | GameInstance / World | Lunity instances are lightweight GenServers, not full engine worlds |

Detailed internals: [ECS Core](subsystems/01_ecs_core.md)

---

## Manager

The manager is a configuration registry that tells instances which components
to register, which systems to run (and in what order), and how fast to tick.

```elixir
defmodule Pong.Manager do
  use Lunity.Manager

  def components do
    [Lunity.Components.Position, Lunity.Physics.Components.Velocity,
     Lunity.Physics.Components.BoxCollider, Pong.Components.Speed, ...]
  end

  def systems do
    [Pong.Systems.AutoPaddle,
     Lunity.Physics.Systems.SweptAABBCollision,
     Pong.Systems.Scoring]
  end

  def tick_rate, do: 60

  def setup do
    {:ok, _pid} = Lunity.Instance.start(Pong.Scenes.Pong, manager: __MODULE__)
    :ok
  end
end
```

A game defines exactly one Manager. `setup/0` is called once on first start.

Detailed internals: [ECS Core](subsystems/01_ecs_core.md)

---

## Tick

A tick is one step of the game simulation. Every tick:

1. Delta time is computed and stored in the `DeltaTime` component.
2. Each system runs in order (as listed in the Manager).
3. The Lua mod event bus dispatches `on_tick`.
4. Player actions are cleared.

The tick rate is set by the Manager (e.g. 60 ticks per second for Pong).
The tick loop is driven by Erlang `send_after` messages, so it is
cooperative -- a slow system delays the next tick rather than dropping frames.

Detailed internals: [ECS Core](subsystems/01_ecs_core.md)

---

## Session

A session represents one connected input source -- a player's browser
tab, a native window, or a test harness. Each session has its own keyboard,
mouse, gamepad, and head-pose state, plus metadata binding it to an instance
and entity.

Sessions are stored in a single shared ETS table (`:lunity_input`) for
zero-overhead reads from any process. The session ID is typically a
`make_ref()` created when a WebSocket connects or a test starts.

**Coming from other engines:** Most engines have a single global input
state. Lunity's session model supports multiple simultaneous players, each
with their own input, bound to different entities in the same or different
instances.

Detailed internals: [Input](subsystems/04_input.md)

---

## Player

A player is a game client connected over a WebSocket. The player protocol
defines a lifecycle:

1. **Connect** -- WebSocket handshake with a transport token
2. **Hello / Hello Ack** -- version negotiation
3. **Auth** -- JWT verification establishing user identity
4. **Join** -- binding to a game instance and entity
5. **Actions** -- sending semantic game inputs (e.g. "move paddle up")
6. **State** -- receiving periodic ECS snapshots

Players can reconnect within a grace window without losing their session
state.

Detailed internals: [Player Protocol and Auth](subsystems/05_player_protocol_and_auth.md)

---

## Editor

The Lunity editor is a native desktop application built with wxWidgets and
OpenGL. It provides a quad-viewport scene viewer, a hierarchy tree, a
component inspector, and transport controls (play/pause/step). It is started
with `mix lunity.edit` from a game project.

The editor communicates with AI agents via the MCP (Model Context Protocol)
server, allowing tools like Cursor to load scenes, inspect entities, capture
viewports, and manipulate game state programmatically.

**Coming from other engines:** Similar in role to the Unity Editor, Godot
Editor, or Unreal Editor, but much lighter -- no visual scripting, no asset
pipeline UI. Authoring is code-first; the editor is for spatial preview and
debugging.

Detailed internals: [Editor](subsystems/08_editor.md), [MCP Tooling](subsystems/09_mcp_tooling.md)

---

## Mod

A mod is a Lua-based content and behaviour extension, inspired by Factorio's
mod system. Mods live in `priv/mods/<name>/` and have two stages:

**Data stage** (`data.lua`): defines game content (scenes, prefabs, entities)
using `data:extend()`. All mods share one Lua state, run in dependency order.

**Runtime stage** (`control.lua`): registers event handlers using
`lunity.on("on_tick", handler)`. Each mod gets its own isolated Lua state
with the `lunity.*` API for reading input and manipulating entities.

```lua
-- priv/mods/base/control.lua
lunity.on("on_tick", function(e)
  local actions = lunity.input.actions_for_entity("paddle_left")
  if actions then
    for _, a in ipairs(actions) do
      if a.op == "move" then
        local pos = lunity.entity.get("paddle_left", "position")
        pos[3] = pos[3] + a.dz * 40.0 * e.dt
        lunity.entity.set("paddle_left", "position", pos)
      end
    end
  end
end)
```

Detailed internals: [Mod System](subsystems/07_mod_system.md)

---

## AABB

**Axis-Aligned Bounding Box.** A rectangular box whose edges are parallel to
the coordinate axes (X, Y, Z). Used for fast collision detection because
overlap checks reduce to simple comparisons on each axis.

Lunity provides two AABB collision strategies:

- **Discrete AABB** -- checks for overlap after movement. Simple and fast,
  but small/fast objects can pass through thin walls ("tunneling").
- **Swept AABB** -- ray-casts the movement path to find the exact collision
  point. Prevents tunneling at the cost of more computation.

In Pong, the ball uses swept AABB collision (`SweptAABBCollision` system) to
ensure it never passes through a paddle, even at high speed.

The `BoxCollider` component stores the AABB half-extents (or full size for
swept). The `CollisionLayer` and `CollisionMask` components control which
entities can collide with each other using bitmasks.

Detailed internals: [Physics](subsystems/03_physics.md)

---

## GLB / glTF

**GL Transmission Format (Binary).** An open standard for 3D models. `.glb`
files contain meshes, materials, textures, and animations in a single binary
file. Lunity uses GLB as its only 3D asset format -- export from Blender,
drop into `priv/prefabs/`, and reference from a Prefab module.

The `GLTF.EAGL` library (in the EAGL dependency) parses GLB files and creates
GPU-ready vertex buffers, textures, and PBR material uniforms.

---

## ETS

**Erlang Term Storage.** A high-performance in-memory key-value store built
into the BEAM VM. Lunity uses ETS tables extensively:

- **ComponentStore** -- tensor storage, entity registry, structured
  component data (one set of tables per instance)
- **Input sessions** -- keyboard, mouse, gamepad, actions (one shared table)
- **Editor state** -- scene, camera, commands, results (one shared table)
- **Mod registry** -- loaded mod data (one shared table)

ETS tables are `:public`, allowing any process to read or write without
message passing. This avoids GenServer bottlenecks on the hot path (e.g.
input reads during a tick).

---

## Nx / Defn

**[Nx](https://github.com/elixir-nx/nx)** is Elixir's numerical computing
library, providing tensor operations similar to NumPy or PyTorch. Lunity
uses Nx for tensor component storage and for system computation.

**Defn** (numerical definitions) are functions annotated with `defn` instead
of `def`. They are compiled to optimised numerical code and can operate on
full tensors without Elixir-level loops. Tensor systems use `defn` to process
all entities in a single batch operation.

---

## ComponentStore

The ComponentStore is a GenServer that owns all ECS data for one game
instance. It manages:

- ETS tables for tensor data, presence masks, and structured components
- An entity registry mapping entity IDs (atoms) to integer tensor indices
- Automatic tensor growth when capacity is exceeded

The "active store" is tracked in the process dictionary, so game code never
needs to pass a store reference explicitly -- `ComponentStore.with_store/2`
handles the scoping.

Detailed internals: [ECS Core](subsystems/01_ecs_core.md)

---

## Presence mask

A `{capacity}` tensor of `:u8` values (0 or 1) that tracks which tensor
indices actually hold entities. When systems read a tensor component, the
presence mask tells them which rows contain real data and which are empty
slots.

---

## Wire format

The JSON envelope used by the player WebSocket protocol. Every message has
a version (`v`) and type (`t`) field:

```json
{"v": 1, "t": "hello"}
{"v": 1, "t": "auth", "token": "eyJ..."}
{"v": 1, "t": "actions", "frame": 42, "actions": [{"op": "move", "dz": 0.5}]}
```

Detailed internals: [Player Protocol and Auth](subsystems/05_player_protocol_and_auth.md)

---

## JWT

**JSON Web Token.** A signed token used for player authentication. Lunity
uses HS256 (HMAC-SHA256) JWTs containing `user_id` and optional `player_id`
claims, signed with the `:player_jwt_secret` configuration value. Tokens
expire after 1 hour by default.

Detailed internals: [Player Protocol and Auth](subsystems/05_player_protocol_and_auth.md)

---

## MCP

**Model Context Protocol.** An open protocol for AI assistants to interact
with tools and data sources. Lunity runs an MCP server (via ExMCP) that
exposes editor and ECS operations to agents. This is how Cursor reads scene
hierarchies, captures viewport screenshots, and manipulates entities.

Detailed internals: [MCP Tooling](subsystems/09_mcp_tooling.md)

---

## EAGL

**E**lixir **A**nd open**GL**. Lunity's rendering library (a separate
dependency). Provides OpenGL bindings, scene graph, orbit camera, mesh
loading, PBR shaders, and the wxWidgets window wrapper. EAGL handles
everything GPU-side; Lunity builds on top for game logic and tooling.

---

## NIF

**Native Implemented Function.** A way for the BEAM VM to call compiled
native code (C, Rust, etc.). Lunity uses Rustler NIFs for audio output
(PortAudio), gamepad input (gilrs), and head tracking (TrackIR). NIFs
run in the same OS thread as the calling process, so they must be fast
and non-blocking.

Detailed internals: [Native Extensions](subsystems/10_native_extensions.md)
