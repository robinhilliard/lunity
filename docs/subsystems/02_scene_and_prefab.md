# Scene and Prefab Loading

[Scenes](../concepts.md#scene) and [prefabs](../concepts.md#prefab) define
the spatial layout of a game world. A scene is a tree of nodes -- each with
optional transforms, prefab geometry, [entity](../concepts.md#entity)
bindings, materials, and lights. Prefabs are reusable visual assets
([GLB](../concepts.md#glb--gltf) files) with typed properties. The loading
pipeline resolves scenes from multiple sources (compiled modules, Lua
[mod](../concepts.md#mod) data, config files, raw `.glb`), builds an
[EAGL](../concepts.md#eagl) scene graph, and initialises ECS entities along
the way.

## Modules

| Module | File | Role |
|--------|------|------|
| `Lunity.Scene` | `lib/lunity/scene/scene.ex` | `use Lunity.Scene` macro; generates `__scene_def__/0` at compile time |
| `Lunity.Scene.Def` | `lib/lunity/scene/dsl.ex` | Struct holding a list of `NodeDef`s |
| `Lunity.Scene.NodeDef` | `lib/lunity/scene/dsl.ex` | Struct for a single node: name, prefab, entity, transform, material, light, children |
| `Lunity.Scene.DSL` | `lib/lunity/scene/dsl.ex` | `scene`, `node`, `light` macros for declarative scene definitions |
| `Lunity.SceneLoader` | `lib/lunity/scene_loader.ex` | Entry point for scene resolution and EAGL scene graph construction |
| `Lunity.Prefab` | `lib/lunity/prefab.ex` | `use Lunity.Prefab` macro; links a module to a `.glb` and typed properties |
| `Lunity.PrefabLoader` | `lib/lunity/prefab_loader.ex` | Loads GLB + config for prefabs; instantiates (clones) into a parent node |
| `Lunity.ConfigLoader` | `lib/lunity/config_loader.ex` | Loads `.exs` config files from `priv/config/`; merges with instance properties |
| `Lunity.Properties` | `lib/lunity/properties.ex` | Shared property DSL, compile-time struct generation, runtime validation |

## How It Works

### Scene DSL

A scene is defined with `use Lunity.Scene` and a `scene do ... end` block.
Inside the block, `node` and `light` calls declare the tree:

```elixir
defmodule Pong.Scenes.PongArena do
  use Lunity.Scene

  scene do
    node :floor, prefab: Pong.Prefabs.Box, position: {0, 0, -1}, scale: {12, 6, 0.3}
    node :ball,  prefab: Pong.Prefabs.Box, entity: Pong.Ball,
                 position: {0, 0, 0.5}, scale: {0.4, 0.4, 0.4}
    light :sun,  type: :directional, intensity: 2.0, rotation: {-0.38, 0, 0, 0.92}
  end
end
```

At compile time this produces a `__scene_def__/0` function returning
`%Lunity.Scene.Def{nodes: [...]}`. The same DSL works in `.exs` config files
(evaluated at runtime, returning the struct directly).

Scenes can compose other scenes via `scene:` on a node -- the referenced
module's `__scene_def__` is inlined as a subtree under a group node.

### NodeDef fields

Each `NodeDef` carries optional fields that control what the loader does with
it:

- `prefab:` -- load a GLB visual asset from `priv/prefabs/`
- `entity:` -- bind an entity module; its `init/2` is called during loading
- `config:` -- path to a `.exs` config file for entity defaults
- `properties:` -- per-instance overrides merged on top of config defaults
- `material:` / `light:` -- inline visual overrides
- `position:`, `scale:`, `rotation:` -- local transform
- `scene:` -- sub-scene composition (mutually exclusive with `prefab:`)
- `children:` -- nested nodes

### Scene resolution pipeline

`SceneLoader.load_scene/2` tries sources in order:

1. **Scene builders** -- explicit `{Module, :function}` registered in
   `:lunity, :scene_builders` config.
2. **Mod data** -- `%Def{}` from Lua mods via `data:extend()`.
3. **Module convention** -- `{App}.Scenes.{CamelizedPath}` (e.g. path
   `"pong_arena"` resolves to `Pong.Scenes.PongArena`).
4. **Config file** -- `priv/config/scenes/<path>.exs` returning a `%Def{}`.
5. **GLB file** -- `priv/scenes/<path>.glb` loaded directly via GLTF.EAGL.

The first source that succeeds wins. Path traversal (`..`, absolute paths)
is rejected at every level.

### Prefabs

A prefab module links a `.glb` file to typed properties:

```elixir
defmodule Pong.Prefabs.Box do
  use Lunity.Prefab, glb: "box"

  prefab do
    property :color, :float_array, length: 4, default: [1, 1, 1, 1]
  end
end
```

`PrefabLoader.load_prefab/2` resolves the GLB path (`priv/prefabs/<id>.glb`)
and optional config (`priv/config/prefabs/<id>.exs`). It can also resolve
mod-defined prefabs via `Mod.Loader`. The loader returns an EAGL scene and a
config map.

`instantiate_prefab/4` clones the loaded scene graph (sharing mesh data) and
attaches the roots under a parent node, merging config overrides.

### ConfigLoader

`.exs` files under `priv/config/` are evaluated with `Code.eval_file/1`.
The result (map or keyword list) is normalised to a map with atom keys.
`merge_config/2` combines a base config with instance properties -- `nil`
values in properties are ignored (they don't override the base).

### Properties

`Lunity.Properties` is the shared foundation for both Entity and Prefab
property declarations. The `property/3` macro accumulates property metadata
at compile time. `__before_compile__` in Entity/Prefab consumes these to
generate:

- A struct with defaults
- `__property_spec__/0` for runtime introspection
- A `@type t` typespec

At runtime, `from_config/2` builds a struct from a merged config map, and
`validate_properties/2` checks values against type/min/max/values/length
constraints.

## Scene Loading (from compiled module)

```mermaid
sequenceDiagram
    participant Caller
    participant SL as SceneLoader
    participant Scene as Scene Module
    participant PL as PrefabLoader
    participant CL as ConfigLoader
    participant Entity as Entity Module
    participant EAGL as EAGL Scene Graph

    Caller->>SL: load_scene(Pong.Scenes.PongArena, opts)
    SL->>Scene: __scene_def__()
    Scene-->>SL: %Def{nodes: [NodeDef, ...]}

    SL->>SL: build_from_def(def, opts)
    SL->>EAGL: Node.new(name: "scene_root")

    loop Each NodeDef
        alt Has prefab
            SL->>PL: load_prefab(prefab_id, opts)
            PL->>PL: resolve GLB path
            PL->>EAGL: GLTF.EAGL.load_scene(glb_path, shader)
            PL-->>SL: {:ok, prefab_scene, config}
            SL->>PL: instantiate_prefab_from_loaded(scene, config, parent, overrides)
            PL->>PL: clone_node (share meshes, copy structure)
            PL-->>SL: {:ok, parent, merged_config}
        else Has scene ref
            SL->>SL: resolve_scene_module(sub_scene)
            SL->>SL: build_from_def (recursive)
        else Plain node
            SL->>EAGL: Node.new(name)
        end

        SL->>SL: apply_transform, maybe_apply_material, maybe_apply_light

        alt Has entity
            SL->>CL: load_config(config_path)
            CL-->>SL: {:ok, base_config}
            SL->>CL: merge_config(base, properties)
            SL->>Entity: init(merged_config, entity_id)
            Entity-->>SL: :ok
        end
    end

    SL-->>Caller: {:ok, scene, entities}
```

## Scene Resolution Pipeline

```mermaid
flowchart TD
    A["load_scene(path, opts)"] --> B{Scene builders config?}
    B -- yes --> C["Call {Module, :function}"]
    C -- ok --> Z["Return {:ok, scene, []}"]
    B -- no/error --> D{Mod data scene?}
    D -- found --> E["build_from_def(mod_def)"]
    E --> Z
    D -- nil --> F{Module by convention?}
    F -- found --> G["build_from_def(module.__scene_def__)"]
    G --> Z
    F -- nil --> H{Config .exs file?}
    H -- found --> I["build_from_def(config_def)"]
    I --> Z
    H -- nil --> J{.glb file exists?}
    J -- yes --> K["GLTF.EAGL.load_scene(path)"]
    K --> Z
    J -- no --> L["Return {:error, :file_not_found}"]
```

## Prefab Loading and Instantiation

```mermaid
sequenceDiagram
    participant Caller
    participant PL as PrefabLoader
    participant ModL as Mod.Loader
    participant CL as ConfigLoader
    participant GLTF as GLTF.EAGL
    participant Props as Properties

    Caller->>PL: load_prefab("door", opts)

    alt Module atom with __glb_id__
        PL->>PL: resolve_prefab_module(module)
        PL->>Props: property_spec(module) for defaults
    else String ID
        PL->>ModL: resolve_prefab_glb("door")
        alt Mod provides GLB path
            ModL-->>PL: glb_path
            PL->>ModL: get_prefab("door") for defaults
        else Standard path
            PL->>PL: priv/prefabs/door.glb
            PL->>CL: load_config("prefabs/door")
            CL-->>PL: {:ok, config} or {:ok, %{}}
        end
    end

    PL->>GLTF: load_scene(glb_path, shader, opts)
    GLTF-->>PL: {:ok, scene, gltf, ds}
    PL-->>Caller: {:ok, scene, config}

    Note over Caller,PL: Instantiation (clone and attach)

    Caller->>PL: instantiate_prefab_from_loaded(scene, config, parent, overrides)
    PL->>CL: merge_config(config, overrides)
    PL->>PL: clone_node for each root (share meshes)
    PL->>PL: Node.add_child(parent, cloned_root)
    PL-->>Caller: {:ok, updated_parent, merged_config}
```

## Cross-references

- [ECS Core](01_ecs_core.md) -- `Instance.init_scene_entities` walks scene definitions to allocate entities and call `init/2`
- [Mod System](07_mod_system.md) -- `DataStage` produces scene and prefab definitions via `data:extend()`; `Mod.Loader` provides them to SceneLoader and PrefabLoader
- [Editor](08_editor.md) -- the editor View uses SceneLoader for load/watch commands; FileWatcher triggers reloads on `priv/` changes
- [MCP Tooling](09_mcp_tooling.md) -- `scene_load` tool calls SceneLoader; `BlenderExtras` reads prefab property specs
