# Lunity

Game engine and editor utilities for EAGL. Provides debug drawing, config loading, prefabs, and (in later phases) ECSx integration and MCP tooling.

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

## Concepts

### Behaviour vs Config

- **Behaviour module** – The *type* definition: which ECSx components to add, property schema (types, constraints). Shared by all instances of that entity type. Don't hard-code game design defaults here.
- **Config files** – Game design defaults: health, damage, key_id, etc. One config can back many instances. Create as many config variants as needed (wooden door, steel door, boss door) without touching the behaviour module.
- **Decoupling** – Keeps behaviours stable (schema + logic) and configs flexible (designers add variants without code changes).

### Config + extras = constructor args

Config (from `.exs`) and extras (from `node.properties`) are **merged** at load time. Config is the base; extras override. The merged result is passed to `behaviour.init/1` as constructor arguments.

Properties are not a field inside config—they are two sources that get merged, with extras winning on conflicts. Nil values in extras are ignored (don't override config).

### Config vs ECSx components

- **Config/extras** – Load-time, declarative. Design parameters and initial values.
- **ECSx components** – Runtime state. Velocity, health, position—updated by systems each frame. Config feeds into component *initialization*; components are the live state systems operate on.

### Init and systems

`behaviour.init(merged_config)` creates the entity, adds components, and sets their initial values from the merged config.

Systems read and update those components each tick. The behaviour defines the entity type and initial state; systems drive ongoing updates.

### Programmatic spawning

When spawning via `instantiate_prefab(id, parent, overrides)`, overrides merge with the prefab's config. Same semantics as extras overriding config—just the overrides come from code instead of Blender.

## Coordinate system

Right-handed XYZ, Y up. Horizon plane is XZ.

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be found at <https://hexdocs.pm/lunity>.
