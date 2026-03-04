# Lunity

Game engine and editor utilities for EAGL. Provides debug drawing, config loading, prefabs, ECSx integration (SceneLoader, Entity, EntityFactory), scene and entity DSLs, file watching for auto-reload, and MCP tooling for agent-driven development.

## Project structure

When Lunity is a dependency, your game's `priv/` layout:

```
priv/
  prefabs/
    *.glb           # glTF only; config in config/prefabs/
  scenes/
    *.glb           # glTF scenes (Blender-authored)
  config/           # Code-behind configs (.exs)
    scenes/         # Config-driven scene definitions
    prefabs/
```

Paths resolve via `Application.app_dir(app, "priv")` where `app` is your application. Loaders use convention-based resolution; directory walking is sufficient for typical project sizes.

## Scene DSL

Config-driven scenes are defined in `.exs` files using the scene DSL. These are first-class scene sources — drop a file at `priv/config/scenes/<name>.exs` and `SceneLoader.load_scene("<name>")` finds it automatically.

```elixir
# priv/config/scenes/pong.exs
import Lunity.Scene.DSL

scene do
  node :floor,        prefab: "box", position: {0, 0, -1}, scale: {12, 6, 0.3}
  node :paddle_left,  prefab: "box", entity: Pong.Paddle,
                      position: {-18, 0, 0.5}, scale: {0.3, 1.5, 0.3},
                      extras: %{side: :left}
  node :paddle_right, prefab: "box", entity: Pong.Paddle,
                      position: {18, 0, 0.5}, scale: {0.3, 1.5, 0.3},
                      extras: %{side: :right}
  node :ball,         prefab: "box", entity: Pong.Ball,
                      position: {0, 0, 0.5}, scale: {0.4, 0.4, 0.4}
end
```

### Node options

- `:prefab` - Prefab ID to load (e.g. `"box"` loads `priv/prefabs/box.glb`)
- `:entity` - Entity module atom (e.g. `Pong.Paddle`) for ECSx integration
- `:config` - Config path for entity defaults (relative to `priv/config/`)
- `:extras` - Map of per-instance overrides (merged with config; extras win)
- `:position` - `{x, y, z}` tuple or `[x, y, z]` list
- `:scale` - `{x, y, z}` tuple or `[x, y, z]` list
- `:rotation` - `{x, y, z, w}` quaternion

### Scene resolution order

When `SceneLoader.load_scene("pong")` is called:

1. **Scene builders** - Explicit `{Module, :function}` in `:lunity, :scene_builders` config (escape hatch for custom logic)
2. **Config file** - `priv/config/scenes/pong.exs` returning `%Lunity.Scene.Def{}`
3. **glTF file** - `priv/scenes/pong.glb`

## Entity DSL

Entity types define what an ECSx entity is made of: its properties (inputs) and components (outputs). Use `use Lunity.Entity` in a module:

```elixir
defmodule Pong.Paddle do
  use Lunity.Entity

  entity do
    property :speed, :float, default: 5.0, min: 0
    property :side,  :atom,  values: [:left, :right]

    component Pong.Components.Velocity
    component Pong.Components.PaddleInput
  end

  @impl Lunity.Entity
  def init(config, entity_id) do
    ECSx.add(entity_id, Pong.Components.Velocity, %{vx: 0, vy: 0})
    ECSx.add(entity_id, Pong.Components.PaddleInput, %{side: config.side, speed: config.speed})
    :ok
  end
end
```

### Property types

- `:string` - Binary string
- `:integer` - Integer with optional `min:`, `max:` constraints
- `:float` - Number with optional `min:`, `max:` constraints
- `:atom` - Atom with optional `values: [...]` constraint
- `:boolean` - Boolean
- `:module` - Module atom (verified loaded at validation time)

### Entity vs prefab vs config vs extras

- **Prefab** (`prefab: "box"`) - The visual representation. A `.glb` mesh file. Multiple entity types can share the same prefab.
- **Entity** (`entity: Pong.Paddle`) - The entity type. Defines which ECSx components to add and how to initialise them. This is where game logic lives.
- **Config** (`config: "paddles/fast"`) - Game design defaults from a `.exs` file. Base values that can be varied without changing code (wooden door, steel door, boss door).
- **Extras** (`extras: %{side: :left}`) - Per-instance overrides in the scene file. Merged with config at load time; extras win on conflicts.

Merge order: config file (base) <- extras (overrides) -> passed to `entity.init(merged_config, entity_id)`.

## File watcher (editor mode)

In editor mode, Lunity watches `priv/config/`, `priv/scenes/`, and `priv/prefabs/` for file changes. When a change is detected the current scene is automatically reloaded with the camera position preserved. Changes are debounced (300ms) to handle editors that write multiple times in quick succession.

## MCP server

### HTTP (default) - stdio breaks due to group leader issues

Stdio forces group leader changes that break wx/GL. Use HTTP instead.

Run from your game project: `mix lunity.mcp`. Cursor config (`.cursor/mcp.json`):

```json
{
  "mcpServers": {
    "lunity": {
      "url": "http://localhost:4111/sse"
    }
  }
}
```

Call the **set_project** tool first with `cwd` (and optional `app`) so scene_load and other tools know which game project to use. Port 4111 (override with `LUNITY_HTTP_PORT`).

**Tools**: `set_project` (call first with HTTP), `project_structure`, `scene_load`, `scene_get_hierarchy`, `get_blender_extras_script`, `editor_get_context`, `editor_set_context`, `editor_push`, `editor_pop`, `editor_peek`, `view_list`, `view_capture`, `entity_list`, `entity_get`, `entity_at_screen`, `node_screen_bounds`, `camera_state`, `view_annotate`, `highlight_node`, `clear_annotations`, `pause`, `step`, `resume`, `entity_set`

## Installation

Add `lunity` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:lunity, "~> 0.1.0", path: "../lunity"}
  ]
end
```

Lunity depends on [EAGL](https://github.com/robinhilliard/eagl) for rendering.

## Modules

### Lunity.Debug

Debug drawing for editor overlays and visualization: `draw_line/5`, `draw_ray/5`, `draw_bounds/4`, `draw_grid_xy/3`, `draw_grid_yz/3`, `draw_grid_xz/3`, `draw_skybox/2`. Calls EAGL.Line under the hood. Use for gizmos, rulers, collision visualization.

### Lunity.ConfigLoader

Code-behind config files. Load `.exs` configs from `priv/config/` and merge with node properties (glTF extras):

```elixir
{:ok, config} = Lunity.ConfigLoader.load_config("scenes/doors/level1_door")
merged = Lunity.ConfigLoader.merge_config(config, node.properties)
```

### Lunity.PrefabLoader

Load and instantiate prefabs (reusable glTF + config templates). Prefabs live at `priv/prefabs/<id>.glb` with config at `priv/config/prefabs/<id>.exs`. Uses PBR shader by default; override via `opts[:shader_program]`. Requires an active OpenGL context.

```elixir
{:ok, scene, config} = Lunity.PrefabLoader.load_prefab("crate")

{:ok, parent, merged_config} =
  Lunity.PrefabLoader.instantiate_prefab("crate", parent_node, %{health: 50})
```

### Lunity.Entity

Entity type definition for ECSx integration. Use `use Lunity.Entity` with an `entity do...end` block to declare properties and components. See the Entity DSL section above for full documentation.

Introspection functions: `extras_spec/1`, `components/1`, `config_path/1`, `validate_extras/2`, `from_config/2`, `resolve_module/1`.

### Lunity.SceneLoader

Orchestrates scene loading from config-driven scenes, glTF files, or scene builders. Resolves prefabs, creates ECSx entities, and runs entity init. Requires ECSx to be running (game adds ECSx to its supervision tree).

```elixir
{:ok, scene, entities} = Lunity.SceneLoader.load_scene("warehouse")
```

### Lunity.EntityFactory

Create node-less entities from config. For offscreen processes, AI, inventory, spawn queues. Config returns a list of component structs; EntityFactory adds each.

```elixir
{:ok, entity_id} = Lunity.EntityFactory.create_from_config("spawns/enemy_type_a", %{health: 80})
```

## Concepts

### Entity type vs config

- **Entity module** - The *type* definition: which ECSx components to add, property schema (types, constraints). Shared by all instances of that entity type. Don't hard-code game design defaults here.
- **Config files** - Game design defaults: health, damage, key_id, etc. One config can back many instances. Create as many config variants as needed (wooden door, steel door, boss door) without touching the entity module.
- **Decoupling** - Keeps entity types stable (schema + logic) and configs flexible (designers add variants without code changes).

### Config + extras = constructor args

Config (from `.exs`) and extras (from scene node or `node.properties`) are **merged** at load time. Config is the base; extras override. The merged result is passed to `entity.init(config, entity_id)` as constructor arguments.

Properties are not a field inside config - they are two sources that get merged, with extras winning on conflicts. Nil values in extras are ignored (don't override config).

### Entities vs Nodes

ECSx entities and EAGL nodes have a flexible relationship:

- **1:1 (default)** - Each node with an entity type creates one ECSx entity. The entity stores `entity_id` on the node for the link.
- **1:many** - Spawner nodes create multiple entities at runtime (e.g. projectiles, offscreen enemies).
- **0:1 (node-less entities)** - Entities can exist without any node. Use for offscreen processes, AI agents, inventory state, spawn queues, or any game logic that doesn't need a scene-graph presence. Created via `Lunity.EntityFactory.create_from_config("path", overrides)`.

EAGL.Scene is for rendering; ECSx is for game logic. Node-less entities participate in systems but are not drawn.

### Config vs ECSx components

- **Config/extras** - Load-time, declarative. Design parameters and initial values.
- **ECSx components** - Runtime state. Velocity, health, position - updated by systems each frame. Config feeds into component *initialisation*; components are the live state systems operate on.

### Init and systems

The loader creates the entity, then calls `entity_module.init(merged_config, entity_id)`. The entity module adds components and sets initial values.

Systems read and update those components each tick. A sync system writes ECSx Transform to the EAGL scene graph for rendering.

### Programmatic spawning

When spawning via `instantiate_prefab(id, parent, overrides)`, overrides merge with the prefab's config. Same semantics as extras overriding config - just the overrides come from code instead of the scene file.

## Coordinate system

Right-handed XYZ, Y up. Horizon plane is XZ.

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be found at <https://hexdocs.pm/lunity>.
