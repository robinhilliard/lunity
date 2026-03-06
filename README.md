# Lunity

Game engine and editor utilities for EAGL. Provides scene, entity, and prefab DSLs, ECSx integration, a Lua mod system for data-driven content and runtime scripting, file watching for auto-reload, and MCP tooling for agent-driven development.

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
  mods/
    base/         # Base game mod (Lua)
      mod.lua
      data.lua
      control.lua
      assets/
        prefabs/
          *.glb
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
                  position: {0, 0, 1}, properties: %{health: 100}
    node :floor,  prefab: MyGame.Prefabs.Box, position: {0, -1, 0}, scale: {10, 0.1, 10}
  end
end
```

Scenes can nest other scenes (Godot-style composition). Sub-scene nodes are grafted as children with the parent transform applied. No override/variant system.

### Entity DSL

Entities define what things do -- game logic, ECSx components, and properties editable in the Lunity editor. Use `use Lunity.Entity` (optionally with `config: "path"` for default config relative to `priv/config/`):

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
    },
    components = { "MyGame.Components.Health", "MyGame.Components.Movement" }
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

## File watcher (editor mode)

In editor mode, Lunity watches `priv/config/`, `priv/scenes/`, and `priv/prefabs/` for file changes. When a change is detected the current scene is automatically reloaded with the camera position preserved. Changes are debounced (300ms). If `inotify-tools` is not installed (Linux/WSL2), the watcher logs a warning and continues without file watching.

## MCP server

### HTTP (default) - stdio breaks due to group leader issues

Run from your game project: `mix lunity.edit`. Cursor config (`.cursor/mcp.json`):

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

Lunity depends on [EAGL](https://github.com/robinhilliard/eagl) for rendering and [luerl](https://github.com/rvirding/luerl) for the Lua mod system.

## Coordinate system

Right-handed XYZ, Y up. Horizon plane is XZ.

## Documentation

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc) and published on [HexDocs](https://hexdocs.pm). Once published, the docs can be found at <https://hexdocs.pm/lunity>.
