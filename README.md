# Lunity

Game engine and editor utilities for EAGL. Provides debug drawing, config loading, prefabs, ECSx integration (SceneLoader, EntityFactory, NodeBehaviour), and MCP tooling for agent-driven development.

## Project structure

When Lunity is a dependency, your game's `priv/` layout:

```
priv/
  prefabs/
    *.glb           # glTF only; config in config/prefabs/
  scenes/
    *.glb           # glTF only; config in config/scenes/
  config/           # Code-behind configs
    scenes/
    prefabs/
```

Paths resolve via `Application.app_dir(app, "priv")` where `app` is your application. Loaders use convention-based resolution; directory walking is sufficient for typical project sizes.

## MCP server

Run `mix lunity.mcp` to start the Lunity MCP server (stdio transport for Cursor). Configure in Cursor's MCP settings with `cwd` set to your game project path. Phase 6a provides the skeleton; tools are added incrementally.

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

Code-behind config files (Phase 3). Load `.exs` configs from `priv/config/` and merge with node properties (glTF extras):

```elixir
{:ok, config} = Lunity.ConfigLoader.load_config("scenes/doors/level1_door")
merged = Lunity.ConfigLoader.merge_config(config, node.properties)
```

### Lunity.PrefabLoader

Load and instantiate prefabs (reusable glTF + config templates). Prefabs live at `priv/prefabs/<id>.glb` with config at `priv/config/prefabs/<id>.exs`. Uses PBR shader by default; override via `opts[:shader_program]`. Requires an active OpenGL context.

```elixir
# Load prefab (requires GL context)
{:ok, scene, config} = Lunity.PrefabLoader.load_prefab("crate")

# Instantiate and attach to parent
{:ok, parent, merged_config} =
  Lunity.PrefabLoader.instantiate_prefab("crate", parent_node, %{health: 50})

# From pre-loaded (e.g. for caching)
{:ok, parent, merged} =
  Lunity.PrefabLoader.instantiate_prefab_from_loaded(scene, config, parent_node, %{})
```

### Lunity.NodeBehaviour (Phase 5)

Behaviour for node-linked entities. Use `use Lunity.NodeBehaviour` and `behaviour_properties` to define extras schema and implement `init(config, entity_id)` to add ECSx components. Provides `extras_spec/1`, `validate_extras/2`, `from_config/2`, `resolve_module/1`.

### Lunity.SceneLoader (Phase 5)

Orchestrates scene loading: glTF, ConfigLoader, PrefabLoader, and behaviour init. Single entry point. Requires ECSx to be running (game adds ECSx to its supervision tree).

```elixir
{:ok, scene, entities} = Lunity.SceneLoader.load_scene("warehouse")
```

### Lunity.EntityFactory (Phase 5)

Create node-less entities from config. For offscreen processes, AI, inventory, spawn queues. Config returns a list of component structs; EntityFactory adds each. No registry; macros/helpers optional later.

```elixir
# priv/config/spawns/enemy_type_a.exs
alias MyGame.Components.{Movement, Health, AI}
[%Movement{x: 0, y: 0, vx: 1, vy: 0}, %Health{value: 100}, %AI{type: :patrol}]

# Usage
{:ok, entity_id} = Lunity.EntityFactory.create_from_config("spawns/enemy_type_a", %{health: 80})
```

## Concepts

### Behaviour vs Config

- **Behaviour module** – The *type* definition: which ECSx components to add, property schema (types, constraints). Shared by all instances of that entity type. Don't hard-code game design defaults here.
- **Config files** – Game design defaults: health, damage, key_id, etc. One config can back many instances. Create as many config variants as needed (wooden door, steel door, boss door) without touching the behaviour module.
- **Decoupling** – Keeps behaviours stable (schema + logic) and configs flexible (designers add variants without code changes).

### Config + extras = constructor args

Config (from `.exs`) and extras (from `node.properties`) are **merged** at load time. Config is the base; extras override. The merged result is passed to `behaviour.init(config, entity_id)` as constructor arguments.

Properties are not a field inside config—they are two sources that get merged, with extras winning on conflicts. Nil values in extras are ignored (don't override config).

### Entities vs Nodes

ECSx entities and EAGL nodes have a flexible relationship:

- **1:1 (default)** – Each node with a behaviour creates one entity. The entity stores `entity_id` on the node (or node ref in a component) for the link.
- **1:many** – Spawner nodes create multiple entities at runtime (e.g. projectiles, offscreen enemies).
- **0:1 (node-less entities)** – Entities can exist without any node. Use for offscreen processes, AI agents, inventory state, spawn queues, or any game logic that doesn't need a scene-graph presence. Created via `Lunity.EntityFactory.create_from_config("path", overrides)` – config returns a list of component structs; no `Lunity.NodeBehaviour` required.

EAGL.Scene is for rendering; ECSx is for game logic. Node-less entities participate in systems but are not drawn.

### Config vs ECSx components

- **Config/extras** – Load-time, declarative. Design parameters and initial values.
- **ECSx components** – Runtime state. Velocity, health, position—updated by systems each frame. Config feeds into component *initialization*; components are the live state systems operate on.

### Init and systems

The loader creates the entity via `ECSx.add_entity/1`, then calls `behaviour.init(merged_config, entity_id)`. The behaviour adds components and sets initial values.

Systems read and update those components each tick. A sync system writes ECSx Transform to the EAGL scene graph for rendering.

### Programmatic spawning

When spawning via `instantiate_prefab(id, parent, overrides)`, overrides merge with the prefab's config. Same semantics as extras overriding config—just the overrides come from code instead of Blender.

## Coordinate system

Right-handed XYZ, Y up. Horizon plane is XZ.

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be found at <https://hexdocs.pm/lunity>.
