# Lunity

Game engine and editor utilities for EAGL. Provides scene, entity, and prefab DSLs, ECSx integration, file watching for auto-reload, and MCP tooling for agent-driven development.

## Project structure

When Lunity is a dependency, your game's layout:

```
lib/
  my_game/
    scenes/       # Scene modules (use Lunity.Scene)
    prefabs/      # Prefab modules (use Lunity.Prefab)
    entities/     # Entity modules (use Lunity.Entity)
priv/
  prefabs/
    *.glb         # Visual assets (referenced by prefab modules)
  scenes/
    *.glb         # Blender-authored scenes (alternative to scene modules)
  config/
    scenes/       # Config-driven scene .exs files (fallback)
    prefabs/      # Legacy prefab config .exs files (fallback)
```

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
                  position: {0, 0, 1}, extras: %{health: 100}
    node :floor,  prefab: MyGame.Prefabs.Box, position: {0, -1, 0}, scale: {10, 0.1, 10}
  end
end
```

Scenes can nest other scenes (Godot-style composition). Sub-scene nodes are grafted as children with the parent transform applied. No override/variant system.

### Entity DSL

Entities define what things do -- game logic, ECSx components, and properties editable in the Lunity editor. Use `use Lunity.Entity`:

```elixir
defmodule MyGame.Player do
  use Lunity.Entity

  entity do
    property :health, :integer, default: 100, min: 0
    property :speed,  :float,   default: 5.0

    component MyGame.Components.Health
    component MyGame.Components.Movement
  end

  @impl Lunity.Entity
  def init(config, entity_id) do
    ECSx.add(entity_id, MyGame.Components.Health, %{value: config.health})
    ECSx.add(entity_id, MyGame.Components.Movement, %{speed: config.speed})
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
- `:extras` - Map of per-instance overrides (merged with config; extras win)
- `:position` - `{x, y, z}` tuple or `[x, y, z]` list
- `:scale` - `{x, y, z}` tuple or `[x, y, z]` list
- `:rotation` - `{x, y, z, w}` quaternion

A node can have:
- Just `prefab:` -- static visual, no game logic (scenery)
- Both `prefab:` and `entity:` -- interactive game object (the common case)
- Just `scene:` -- sub-scene composition
- None of the above -- empty grouping node (parent for children)

## Property separation

Prefab and entity properties occupy different domains:

- **Prefab properties** -- visual/physical, intrinsic to the mesh, editable in Blender (colour, material, hinge offset). A prefab can be used by many entity types.
- **Entity properties** -- game logic, specific to the entity type, editable in the Lunity editor (health, speed, side). Meaningless without the entity module.

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
entity module defaults  <-  scene extras          =  game config
                                ↓
                entity.init(merged_config, entity_id)
```

## Scene resolution order

When `SceneLoader.load_scene` is called with a string path:

1. **Scene builders** - Explicit `{Module, :function}` in `:lunity, :scene_builders` config
2. **Config file** - `priv/config/scenes/<path>.exs` returning `%Lunity.Scene.Def{}`
3. **glTF file** - `priv/scenes/<path>.glb`

When called with a module atom, the module's `__scene_def__/0` is used directly.

## File watcher (editor mode)

In editor mode, Lunity watches `priv/config/`, `priv/scenes/`, and `priv/prefabs/` for file changes. When a change is detected the current scene is automatically reloaded with the camera position preserved. Changes are debounced (300ms). If `inotify-tools` is not installed (Linux/WSL2), the watcher logs a warning and continues without file watching.

## MCP server

### HTTP (default) - stdio breaks due to group leader issues

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

Call **set_project** first with `cwd` (and optional `app`). Port 4111 (override with `LUNITY_HTTP_PORT`).

**Tools**: `set_project`, `project_structure`, `scene_load`, `scene_get_hierarchy`, `get_blender_extras_script`, `editor_get_context`, `editor_set_context`, `editor_push`, `editor_pop`, `editor_peek`, `view_list`, `view_capture`, `entity_list`, `entity_get`, `entity_at_screen`, `node_screen_bounds`, `camera_state`, `view_annotate`, `highlight_node`, `clear_annotations`, `pause`, `step`, `resume`, `entity_set`

## Installation

```elixir
def deps do
  [
    {:lunity, "~> 0.1.0", path: "../lunity"}
  ]
end
```

Lunity depends on [EAGL](https://github.com/robinhilliard/eagl) for rendering.

## Coordinate system

Right-handed XYZ, Y up. Horizon plane is XZ.

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be found at <https://hexdocs.pm/lunity>.
