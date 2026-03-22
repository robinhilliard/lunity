# How to Write a Mod

This guide walks you through creating a Lunity [mod](../concepts.md#mod) from
scratch. It covers the file structure, the `lunity.*` API, and two complete
examples: the Pong player-input mod, and writing an AI paddle as a mod.

**Prerequisites:** A working Lunity game project (like
[lunity-pong](https://github.com/user/lunity-pong)). Familiarity with Lua
basics (variables, functions, tables, `for` loops). No Elixir knowledge is
needed to write a mod.

---

## Mod file structure

A mod lives in `priv/mods/<name>/` inside your game project:

```
priv/mods/
  my_mod/
    mod.lua             # required: metadata
    data.lua            # optional: content definitions
    data-updates.lua    # optional: patch other mods' data
    data-final-fixes.lua  # optional: final adjustments
    control.lua         # optional: runtime event handlers
    assets/             # optional: mod-specific assets
      prefabs/
        custom_paddle.glb
```

The only required file is `mod.lua`. Everything else is optional -- include
only what your mod needs.

---

## Step 1: mod.lua -- declaring your mod

Every mod needs a `mod.lua` that returns a table with metadata:

```lua
-- priv/mods/my_mod/mod.lua
return {
  name = "my_mod",
  version = "1.0.0",
  title = "My Custom Mod",
  dependencies = {}
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Unique identifier. Must match the folder name by convention. |
| `version` | no | Semver string. Defaults to `"0.0.0"`. |
| `title` | no | Human-readable display name. Defaults to `name`. |
| `dependencies` | no | List of mod names that must load before this one. |

### Dependencies

If your mod patches another mod's data or relies on its entities, declare
the dependency:

```lua
return {
  name = "ai_paddle",
  version = "1.0.0",
  title = "AI Paddle Controller",
  dependencies = { "base" }
}
```

Lunity topologically sorts mods by dependencies. Circular dependencies are
rejected at load time.

---

## Step 2: Enabling mods in your project

Add `mods_enabled: true` to your Lunity config:

```elixir
# config/config.exs  (or config/dev.exs)
config :lunity, :mods_enabled, true
```

Mods are loaded automatically at application startup. The log will show:

```
[info] Lunity.Mod: loaded 1 mod(s): base
```

---

## Step 3: control.lua -- runtime behaviour

`control.lua` is where you write game logic. It runs once at load time, and
you register event handlers that the engine calls during gameplay.

### The event model

Register handlers with `lunity.on(event_name, handler_function)`:

```lua
lunity.on("on_init", function(event)
  lunity.log("Mod loaded!")
end)

lunity.on("on_tick", function(e)
  -- runs every game tick, e.dt is delta time in seconds
end)
```

| Event | Payload | When it fires |
|-------|---------|---------------|
| `on_init` | `{}` | Once, after all mods are loaded |
| `on_tick` | `{dt = <seconds>}` | Every game tick, after systems have run |

`on_tick` is the main entry point for mod logic. It runs after the Elixir
systems (physics, etc.) but before player actions are cleared, so you can
read both the current game state and the player's inputs for this tick.

---

## The lunity.* API

Inside event handlers you have access to the following functions:

### Entity operations

| Function | Description |
|----------|-------------|
| `lunity.entity.get(entity, "position")` | Returns `{x, y, z}` as a Lua table `{[1]=x, [2]=y, [3]=z}` |
| `lunity.entity.set(entity, "position", {x, y, z})` | Sets the entity's position |
| `lunity.entity.find(name)` | Returns the entity ID for a named entity |

Entity names are strings matching the scene node names (e.g. `"paddle_left"`,
`"ball"`).

Position values returned by `get` are Lua tables indexed from 1:
`pos[1]` = x, `pos[2]` = y, `pos[3]` = z.

### Input operations

| Function | Description |
|----------|-------------|
| `lunity.input.is_key_down_for_entity(key, entity)` | `true` if `key` is held by the player controlling `entity` |
| `lunity.input.actions_for_entity(entity)` | Returns a list of action tables from the player's WebSocket this tick |

Key names are strings like `"w"`, `"s"`, `"arrow_up"`, `"arrow_down"`,
`"space"`, `"a"`, `"d"`. See the Keymap module for the full list.

Actions are tables sent by the browser client via the player protocol.
Each action has at least an `op` field (string). For Pong, the browser
sends `{op = "move", dz = <-1..1>}`.

### Logging

| Function | Description |
|----------|-------------|
| `lunity.log(message)` | Prints `[Mod:<name>] <message>` to the Elixir logger |

---

## Example 1: Player input mod (Pong base)

This is the actual `control.lua` from the Pong sample game. It reads player
input (keyboard keys and WebSocket actions) and moves the paddles.

```lua
-- priv/mods/base/control.lua

lunity.on("on_init", function(event)
  lunity.log("Pong base mod initialized")
end)

lunity.on("on_tick", function(e)
  local dt = e.dt
  local speed = 40.0
  local zlim = 6.0

  local function clamp(z, lo, hi)
    if z < lo then return lo end
    if z > hi then return hi end
    return z
  end

  local function move(entity, up_key, down_key)
    local dz = 0.0

    -- Priority 1: WebSocket actions from the browser client
    local actions = lunity.input.actions_for_entity(entity)
    if actions then
      for _, a in ipairs(actions) do
        if a.op == "move" then
          local m = a.dz or 0.0
          dz = dz + m * speed * dt
        end
      end
    end

    -- Priority 2: keyboard fallback (native window or viewer)
    if dz == 0.0 then
      if lunity.input.is_key_down_for_entity(up_key, entity) then
        dz = dz + speed * dt
      end
      if lunity.input.is_key_down_for_entity(down_key, entity) then
        dz = dz - speed * dt
      end
    end

    -- Apply movement
    if dz ~= 0.0 then
      local pos = lunity.entity.get(entity, "position")
      if pos then
        local x, y, z = pos[1], pos[2], pos[3]
        z = clamp(z + dz, -zlim, zlim)
        lunity.entity.set(entity, "position", {x, y, z})
      end
    end
  end

  move("paddle_left", "w", "s")
  move("paddle_right", "arrow_up", "arrow_down")
end)
```

### How it works, step by step

1. **`on_tick` fires** after the Elixir systems (physics, collision) have
   finished. `e.dt` contains the time since the last tick in seconds
   (e.g. ~0.0167 at 60 ticks/second).

2. **`move("paddle_left", "w", "s")`** is called for each paddle.

3. **Actions check:** `lunity.input.actions_for_entity("paddle_left")`
   returns any actions the browser player sent this tick. If the player
   sent `{op: "move", dz: 0.5}`, the mod computes `dz = 0.5 * 40.0 * dt`.

4. **Keyboard fallback:** If no WebSocket actions arrived (no browser player,
   or the player didn't press anything), the mod checks keyboard state.
   `lunity.input.is_key_down_for_entity("w", "paddle_left")` returns `true`
   if the player bound to `paddle_left` is holding the W key.

5. **Position update:** The mod reads the paddle's current position, adds
   the computed `dz` (clamped to bounds), and writes it back.

### Why this is a mod and not an Elixir system

The Elixir `AutoPaddle` system handles AI-controlled paddles using tensor
math. The Lua mod handles *human-controlled* paddles using the input API.
This separation means the AI logic can be swapped, extended, or disabled
by adding or removing mods -- without recompiling the game.

---

## Example 2: AI paddle mod

Let's write the AI paddle logic as a mod. This replaces the Elixir
`AutoPaddle` system for paddles that have no human player attached. The mod
reads the ball's position and moves the paddle toward it, with configurable
speed and imperfection.

### File structure

```
priv/mods/ai_paddle/
  mod.lua
  control.lua
```

### mod.lua

```lua
-- priv/mods/ai_paddle/mod.lua
return {
  name = "ai_paddle",
  version = "1.0.0",
  title = "AI Paddle Controller",
  dependencies = { "base" }
}
```

We depend on `"base"` so the base mod's player-input handler runs first.
If a human player is moving the paddle, the AI should not fight them.

### control.lua

```lua
-- priv/mods/ai_paddle/control.lua

-- Configuration: tune these to change AI difficulty
local AI_SPEED = 30.0     -- how fast the AI paddle moves (units/sec)
local AI_Z_LIMIT = 6.0    -- paddle movement bounds
local AI_REACTION = 0.8   -- 0.0 = ignores ball, 1.0 = perfect tracking
local AI_OVERSHOOT = 0.5  -- random offset to make the AI beatable

-- Track which paddles a human is controlling this tick
local human_moved = {}

lunity.on("on_tick", function(e)
  local dt = e.dt

  -- Step 1: detect which paddles humans moved this tick
  human_moved = {}
  for _, entity in ipairs({"paddle_left", "paddle_right"}) do
    local actions = lunity.input.actions_for_entity(entity)
    if actions then
      for _, a in ipairs(actions) do
        if a.op == "move" and a.dz ~= 0 then
          human_moved[entity] = true
        end
      end
    end
    if not human_moved[entity] then
      if lunity.input.is_key_down_for_entity("w", entity) or
         lunity.input.is_key_down_for_entity("s", entity) or
         lunity.input.is_key_down_for_entity("arrow_up", entity) or
         lunity.input.is_key_down_for_entity("arrow_down", entity) then
        human_moved[entity] = true
      end
    end
  end

  -- Step 2: get the ball position (our tracking target)
  local ball_pos = lunity.entity.get("ball", "position")
  if not ball_pos then return end
  local ball_z = ball_pos[3]

  -- Step 3: move each uncontrolled paddle toward the ball
  for _, entity in ipairs({"paddle_left", "paddle_right"}) do
    if not human_moved[entity] then
      ai_move(entity, ball_z, dt)
    end
  end
end)

function ai_move(entity, ball_z, dt)
  local pos = lunity.entity.get(entity, "position")
  if not pos then return end

  local x, y, z = pos[1], pos[2], pos[3]

  -- Apply reaction factor: the AI doesn't perfectly track the ball
  -- A reaction of 0.8 means the target is 80% ball + 20% center
  local target_z = ball_z * AI_REACTION

  -- Add a small constant offset to make the AI imperfect
  -- (in a real mod you might vary this with math.random)
  target_z = target_z + AI_OVERSHOOT

  -- Clamp target to court bounds
  if target_z > AI_Z_LIMIT then target_z = AI_Z_LIMIT end
  if target_z < -AI_Z_LIMIT then target_z = -AI_Z_LIMIT end

  -- Move toward target at limited speed
  local diff = target_z - z
  local max_step = AI_SPEED * dt

  if diff > max_step then
    diff = max_step
  elseif diff < -max_step then
    diff = -max_step
  end

  z = z + diff

  -- Clamp final position
  if z > AI_Z_LIMIT then z = AI_Z_LIMIT end
  if z < -AI_Z_LIMIT then z = -AI_Z_LIMIT end

  lunity.entity.set(entity, "position", {x, y, z})
end
```

### How this compares to the Elixir AutoPaddle system

The Elixir `AutoPaddle` system and this Lua mod do the same thing -- move
paddles toward the ball. Here is what each approach looks like:

| Aspect | Elixir system (AutoPaddle) | Lua mod (ai_paddle) |
|--------|---------------------------|---------------------|
| **Language** | Elixir + Nx tensors | Lua |
| **Processing** | All entities at once (batch tensor math) | One entity at a time (loop) |
| **Filtering** | Boolean mask (`should_move`) | Check `human_moved[entity]` |
| **Ball lookup** | `entities: [:ball]` -> `ball_idx` input | `lunity.entity.get("ball", "position")` |
| **Position read** | Implicit (full tensor passed in) | `lunity.entity.get(entity, "position")` |
| **Position write** | Return `%{position: new_pos}` tensor | `lunity.entity.set(entity, "position", ...)` |
| **Clamping** | `Nx.min(Nx.max(...))` on tensors | Plain Lua `if` checks |
| **Recompile needed?** | Yes | No -- edit the file and reload |
| **Performance** | Batch GPU-style; processes all entities in one call | Per-entity; fine for a few paddles |
| **Moddability** | Requires Elixir knowledge | Lua only -- modders don't need to understand Nx or Elixir |

**When to use which:** Use an Elixir system when you need high-performance
batch processing (physics, particle systems, pathfinding for hundreds of
agents). Use a Lua mod when the logic is per-entity, event-driven, or you
want modders to be able to customise it without recompiling.

### Making the AI harder or easier

Because the tuning values are plain Lua variables at the top of
`control.lua`, anyone can tweak the AI without touching Elixir code:

```lua
local AI_SPEED = 50.0     -- faster paddle (harder)
local AI_REACTION = 0.95  -- better tracking (harder)
local AI_OVERSHOOT = 0.1  -- less random miss (harder)
```

Or make it comically bad:

```lua
local AI_SPEED = 10.0     -- sluggish
local AI_REACTION = 0.3   -- barely watches the ball
local AI_OVERSHOOT = 3.0  -- always way off
```

---

## Example 3: Using data.lua for content

The data stage lets mods define game content (scenes, prefabs, entities)
without writing Elixir. This is useful for total-conversion mods or adding
new levels.

```lua
-- priv/mods/my_mod/data.lua
data:extend({
  {
    type = "scene",
    name = "my_arena",
    nodes = {
      {
        name = "floor",
        prefab = "box",
        position = {0, -0.5, 0},
        scale = {20, 1, 12}
      },
      {
        name = "paddle_left",
        prefab = "box",
        entity = "Pong.Entities.Paddle",
        position = {-9, 1.5, 0},
        scale = {1, 1, 3},
        properties = { side = "left" }
      },
      {
        name = "ball",
        prefab = "box",
        entity = "Pong.Entities.Ball",
        position = {0, 1.5, 0},
        scale = {0.8, 0.8, 0.8}
      }
    }
  }
})
```

This defines a scene called `"my_arena"` that the SceneLoader can resolve.
The `entity` field references an Elixir entity module by name. The `prefab`
field references a GLB file (from `priv/prefabs/` or a mod's
`assets/prefabs/`).

The three data files run in order per mod: `data.lua` first (base
definitions), `data-updates.lua` second (patching other mods), and
`data-final-fixes.lua` last (final adjustments).

---

## Debugging tips

### Logging

Use `lunity.log()` liberally during development:

```lua
lunity.on("on_tick", function(e)
  local pos = lunity.entity.get("ball", "position")
  if pos then
    lunity.log("ball z=" .. tostring(pos[3]))
  end
end)
```

Output appears in the Elixir logger (`tmp/lunity_edit.log` when running the
editor).

### Nil checks

Always check that `lunity.entity.get` returned a value. If the entity
doesn't exist yet (scene still loading) or the name is wrong, you'll get
`nil`:

```lua
local pos = lunity.entity.get("paddle_left", "position")
if not pos then
  lunity.log("paddle_left not found!")
  return
end
```

### Hot reload

When running the editor (`mix lunity.edit`), the FileWatcher reloads the
scene when `priv/` files change. For mod changes, you currently need to
restart the editor. A future version will support live mod reloading.

---

## Sandbox restrictions

Mod Lua code runs in a sandbox. The following standard library functions are
**removed** for security:

- `io`, `os`, `debug` -- no file/system access
- `load`, `loadfile`, `dofile`, `require` -- no arbitrary code loading
- `rawget`, `rawset`, `collectgarbage`, `getfenv`, `setfenv`

You can use: `table`, `string`, `math`, `pairs`, `ipairs`, `type`,
`tostring`, `tonumber`, `select`, `unpack`, `error`, `pcall`, `xpcall`.

---

## Event handler execution order

When multiple mods register handlers for the same event, they run in
**dependency order** (the same order mods were loaded). Within one mod,
handlers run in the order they were registered.

If the `base` mod and `ai_paddle` mod both handle `on_tick`:

1. `base` on_tick runs first (handles human input)
2. `ai_paddle` on_tick runs second (handles AI for uncontrolled paddles)

This is why `ai_paddle` depends on `base` -- it needs to check whether
the human moved the paddle before deciding to apply AI.

---

## Further reading

- [Concepts: Mod](../concepts.md#mod) -- high-level overview
- [Mod System internals](../subsystems/07_mod_system.md) -- how the loader,
  data stage, runtime stage, event bus, and sandbox work
- [Input](../subsystems/04_input.md) -- how sessions, keyboards, and actions
  flow from players to mods
- [Player Protocol](../subsystems/05_player_protocol_and_auth.md) -- how
  browser clients send actions that mods consume
