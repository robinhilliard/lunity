# How Nx Works With ECS

This guide explains how Lunity uses [Nx](https://github.com/elixir-nx/nx)
tensors to store and process game state. It starts from zero -- you do not
need prior Nx experience. Every concept is illustrated with real code from
the Pong sample game.

**Prerequisites:** You should understand what [entities, components, and
systems](../concepts.md#entity) are at a high level. This guide
focuses on the *tensor* side -- how data is actually laid out in memory, how
systems operate on it, and the Nx operations you will use most.

---

## Part 1: What a tensor component looks like in memory

### The entity table

Pong has six entities. When the scene loads, the ComponentStore assigns each
entity an integer index:

```
Index   Entity ID
─────   ──────────────
  0     :floor
  1     :paddle_left
  2     :paddle_right
  3     :wall_top
  4     :wall_bottom
  5     :ball
```

Every tensor component is a contiguous block of numbers with one *row* per
index. The ComponentStore pre-allocates 128 rows (the default capacity), but
only the first 6 are used. A **presence mask** tracks which rows are active.

### A vector component: Position

`Position` is defined as `shape: {3}, dtype: :f32` -- three 32-bit floats
per entity (x, y, z). In memory, this produces a `{128, 3}` tensor. After
scene init, the first 6 rows look like this:

```
Position tensor {128, 3}         Presence mask {128}
─────────────────────────        ───────────────────
index 0: [ 0.0, -0.5,  0.0 ]    1    ← floor
index 1: [-14.0, 1.5,  0.0 ]    1    ← paddle_left
index 2: [ 14.0, 1.5,  0.0 ]    1    ← paddle_right
index 3: [ 0.0,  1.0,  8.5 ]    1    ← wall_top
index 4: [ 0.0,  1.0, -8.5 ]    1    ← wall_bottom
index 5: [ 0.0,  1.5,  0.0 ]    1    ← ball
index 6: [ 0.0,  0.0,  0.0 ]    0    ← empty slot
index 7: [ 0.0,  0.0,  0.0 ]    0    ← empty slot
...
```

When you call `Position.put(:ball, {3.0, 1.5, 2.0})`, the ComponentStore
looks up `:ball` -> index 5, then writes `[3.0, 1.5, 2.0]` into row 5 of
the position tensor and sets bit 5 of the presence mask to 1.

### A scalar component: Speed

`Speed` is defined as `shape: {}, dtype: :f32` -- one float per entity with
no inner dimensions. This produces a `{128}` tensor (a flat vector):

```
Speed tensor {128}
──────────────────
index 0:  0.0     ← floor (no speed)
index 1:  8.0     ← paddle_left
index 2:  8.0     ← paddle_right
index 3:  0.0     ← wall_top
index 4:  0.0     ← wall_bottom
index 5: 10.0     ← ball
index 6:  0.0     ← empty
...
```

### Why this layout matters

Because every entity occupies the same row index across *all* tensor
components, a system can read position row 5 and velocity row 5 and know
they belong to the same entity (`:ball`). This is what makes batch processing
possible -- you operate on entire columns or entire tensors at once, and the
row alignment keeps everything in sync.

---

## Part 2: How a tensor system receives its data

When the TickRunner is about to call a system, it:

1. Reads the `@spec` to find which components the system uses.
2. Calls `ComponentStore.get_tensor(component)` for each one.
3. Builds a map: `%{position: <{128,3} tensor>, velocity: <{128,3} tensor>, ...}`.
4. Passes this map to the system's `run/1` function.

The system returns a map of *modified* tensors. The TickRunner writes those
back with `ComponentStore.put_tensor/2`.

A system never loops over entities in Elixir. Instead, it performs tensor
operations that apply to all rows simultaneously -- like applying a formula
to an entire spreadsheet column.

---

## Part 3: The simplest system -- ApplyVelocity

This system adds velocity to position, scaled by delta time. The entire
implementation is three lines:

```elixir
defmodule Lunity.Physics.Systems.ApplyVelocity do
  use Lunity.System, type: :tensor

  alias Lunity.Components.{Position, DeltaTime}
  alias Lunity.Physics.Components.Velocity

  @spec run(%{position: Position.t(), velocity: Velocity.t(), delta_time: DeltaTime.t()}) ::
          %{position: Position.t()}
  defn run(%{position: pos, velocity: vel, delta_time: dt}) do
    dt3 = Nx.reshape(dt, {:auto, 1})
    %{position: Nx.add(pos, Nx.multiply(vel, dt3))}
  end
end
```

Let's trace what happens, assuming 60 ticks per second (`dt ≈ 0.0167`).

### Step 1: `Nx.reshape(dt, {:auto, 1})`

`DeltaTime` is a scalar component -- shape `{128}`. Each element is the same
value (delta time is global). We need to multiply it with the `{128, 3}`
velocity tensor, but `{128}` and `{128, 3}` don't align for element-wise
operations.

`Nx.reshape(dt, {:auto, 1})` reshapes `{128}` to `{128, 1}`. The `:auto`
means "figure out this dimension from the total number of elements."

```
Before reshape: dt shape {128}
  [0.0167, 0.0167, 0.0167, 0.0167, 0.0167, 0.0167, ...]

After reshape: dt3 shape {128, 1}
  [[0.0167],
   [0.0167],
   [0.0167],
   ...]
```

### Step 2: `Nx.multiply(vel, dt3)`

Now Nx **broadcasts** the `{128, 1}` tensor against the `{128, 3}` velocity
tensor. Broadcasting is Nx's way of stretching a smaller dimension to match
a larger one. Each row's single dt value gets multiplied with all three
velocity components:

```
vel {128, 3}               dt3 {128, 1}        result {128, 3}
────────────────────        ────────────        ────────────────────
[ 0.0, 0.0,  0.0 ]    *    [0.0167]       =    [ 0.000, 0.000, 0.000 ]   floor
[ 0.0, 0.0,  0.0 ]    *    [0.0167]       =    [ 0.000, 0.000, 0.000 ]   paddle_left
[ 0.0, 0.0,  0.0 ]    *    [0.0167]       =    [ 0.000, 0.000, 0.000 ]   paddle_right
[ 0.0, 0.0,  0.0 ]    *    [0.0167]       =    [ 0.000, 0.000, 0.000 ]   wall_top
[ 0.0, 0.0,  0.0 ]    *    [0.0167]       =    [ 0.000, 0.000, 0.000 ]   wall_bottom
[10.0, 0.0, -7.0 ]    *    [0.0167]       =    [ 0.167, 0.000,-0.117 ]   ball
```

### Step 3: `Nx.add(pos, ...)`

The position displacement is added to the position tensor element-wise. Both
are `{128, 3}`, so they align directly:

```
pos {128, 3}                 displacement          new pos {128, 3}
────────────────────         ────────────          ────────────────────
[ 0.0, -0.5,  0.0 ]    +    [ 0.000, ...]    =    [ 0.0, -0.5,  0.0  ]   floor (unchanged)
[-14.0, 1.5,  0.0 ]    +    [ 0.000, ...]    =    [-14.0, 1.5,  0.0  ]   paddle_left (unchanged)
...
[ 0.0,  1.5,  0.0 ]    +    [ 0.167,...,-0.117] =  [ 0.167, 1.5, -0.117]  ball (moved!)
```

Only the ball moved because it is the only entity with non-zero velocity.
The system didn't need an `if` statement or a loop -- the math naturally
produces zero displacement for stationary entities.

---

## Part 4: Filtering entities with boolean masks

Most systems should only affect certain entities. In traditional game code
you would write an `if` check. In tensor code, you compute a **boolean mask**
and use `Nx.select` to choose between the new value and the old value.

The `AutoPaddle` system from Pong demonstrates this. Let's walk through it:

```elixir
defn run(%{position: pos, speed: speed, paddle_control: ctrl,
           static: static_flag, delta_time: dt} = inputs) do
```

The system receives all entity data. It needs to move only the auto-controlled
paddles -- entities that are static (walls and paddles are static; the ball is
dynamic), have a speed, and have `paddle_control == 0` (auto mode).

### Building the mask

```elixir
  is_auto = Nx.equal(ctrl, 0)
  has_speed = Nx.greater(speed, 0)
  is_static = Nx.equal(static_flag, 1)
  should_move = Nx.logical_and(is_auto, Nx.logical_and(has_speed, is_static))
```

Each of these produces a `{128}` tensor of 0s and 1s:

```
                    floor  p_left  p_right  w_top  w_bottom  ball
ctrl:                 0       0       0       0       0       0
is_auto:              1       1       1       1       1       1

speed:                0       8       8       0       0      10
has_speed:            0       1       1       0       0       1

static_flag:          1       1       1       1       1       0
is_static:            1       1       1       1       1       0

should_move:          0       1       1       0       0       0
                           ✓ paddle  ✓ paddle
```

The floor is auto but has no speed. The ball has speed but is not static. The
walls have no speed. Only the two paddles pass all three checks.

### Using the mask with `Nx.select`

After computing the desired new Z positions, the system applies the mask:

```elixir
  final_z = Nx.select(should_move, new_z, paddle_z)
```

`Nx.select(condition, if_true, if_false)` works element-wise:

```
should_move:  [0,   1,     1,      0,    0,     0    ]
new_z:        [0.0, 2.1,  -1.3,    0.0,  0.0,   0.0 ]   (computed target)
paddle_z:     [0.0, 0.0,   0.0,    8.5, -8.5,   0.0 ]   (original)
final_z:      [0.0, 2.1,  -1.3,    8.5, -8.5,   0.0 ]
                    ↑ new  ↑ new   ↑ kept  ↑ kept  ↑ kept
```

Entities where `should_move == 0` keep their original Z. Entities where
`should_move == 1` get the new Z. No branch, no loop.

---

## Part 5: Accessing a specific entity by index

Sometimes a system needs data from one specific entity. In Pong, the
`AutoPaddle` system needs to know where the ball is so the paddles can track
it. The system declares `entities: [:ball]`:

```elixir
use Lunity.System, type: :tensor, entities: [:ball]
```

The TickRunner looks up `:ball` in the entity registry (`:ball` -> index 5)
and adds `ball_idx: Nx.tensor(5, type: :s32)` to the input map.

### Reading a specific row

```elixir
  ball_idx = inputs[:ball_idx]

  ball_z = Nx.select(
    Nx.greater_equal(ball_idx, 0),
    pos[ball_idx][2],
    Nx.tensor(0.0, type: :f32)
  )
```

`pos[ball_idx]` indexes into the position tensor, extracting row 5:
`[0.0, 1.5, 0.0]`. Then `[2]` extracts the Z coordinate: `0.0`.

The `Nx.select` guard handles the case where the ball doesn't exist
(`ball_idx == -1`), defaulting to 0.0.

### Why not just use an Elixir variable?

Inside a `defn`, you cannot call Elixir functions or use Elixir control flow.
Everything must be tensor operations. `pos[ball_idx][2]` is a tensor indexing
operation, not an Elixir map lookup. This is why the guard uses `Nx.select`
instead of an `if` statement.

---

## Part 6: Clamping and bounding values

Game systems frequently need to clamp values to a range. Nx provides `Nx.min`
and `Nx.max` which work element-wise on tensors:

```elixir
  target_z = Nx.min(Nx.max(ball_z, -@z_limit), @z_limit)
```

This clamps `ball_z` to the range `[-6.0, 6.0]`. Written out:

```
ball_z = 9.5

Nx.max(9.5, -6.0)  →  9.5       (not below -6)
Nx.min(9.5,  6.0)  →  6.0       (not above 6) ✓
```

The same pattern clamps the movement step to a maximum speed:

```elixir
  max_step = Nx.multiply(dt, @paddle_speed)
  clamped = Nx.min(Nx.max(diff, Nx.negate(max_step)), max_step)
```

If the difference between the paddle and ball is 5.0 but the max step per
tick is 0.67, the paddle only moves 0.67 this tick.

---

## Part 7: Reassembling a tensor from modified columns

After computing the new Z coordinates for every entity, the system needs to
produce a new position tensor. It keeps the original X and Y but replaces Z:

```elixir
  new_pos = Nx.stack([pos[[.., 0]], pos[[.., 1]], final_z], axis: 1)
```

### Slicing columns with `pos[[.., 0]]`

The syntax `tensor[[.., N]]` selects column N across all rows. It is
equivalent to "give me the Nth value from every row":

```
pos[[.., 0]] → all X values: [ 0.0, -14.0,  14.0, 0.0, 0.0, 0.0, ...]   shape {128}
pos[[.., 1]] → all Y values: [-0.5,   1.5,   1.5, 1.0, 1.0, 1.5, ...]   shape {128}
pos[[.., 2]] → all Z values: [ 0.0,   0.0,   0.0, 8.5,-8.5, 0.0, ...]   shape {128}
```

### Stacking with `Nx.stack`

`Nx.stack([col_x, col_y, col_z], axis: 1)` combines three `{128}` tensors
back into one `{128, 3}` tensor by placing them side by side as columns:

```
col_x {128}       col_y {128}      final_z {128}        stacked {128, 3}
────────           ────────         ──────────           ────────────────
  0.0               -0.5              0.0           →    [ 0.0, -0.5,  0.0 ]
-14.0                1.5              2.1           →    [-14.0, 1.5,  2.1 ]
 14.0                1.5             -1.3           →    [ 14.0, 1.5, -1.3 ]
  ...                ...              ...                 ...
```

`axis: 1` means "stack along the column axis." `axis: 0` would stack along
the row axis (making a `{3, 128}` tensor instead).

---

## Part 8: Writing to a single row with `Nx.indexed_put`

Sometimes you need to modify just one entity's data within a full tensor. The
`Scoring` system in Pong does this when the ball goes out of bounds -- it
resets just the ball's position, velocity, and random key without touching any
other entity.

```elixir
  new_pos_row = Nx.tensor([[0.0, ball_y, 0.0]], type: :f32)
  new_vel_row = Nx.tensor([[s * x_sign, 0.0, s * z_ratio * z_sign]], type: :f32)

  idx = Nx.tensor([[i]])

  %{
    position: Nx.indexed_put(pos, idx, new_pos_row),
    velocity: Nx.indexed_put(vel, idx, new_vel_row),
  }
```

### How `Nx.indexed_put` works

`Nx.indexed_put(tensor, indices, updates)` replaces rows at the given indices
with new values:

- `tensor` -- the full `{128, 3}` position tensor
- `indices` -- `[[5]]` (a `{1, 1}` tensor meaning "row 5")
- `updates` -- `[[0.0, 1.5, 0.0]]` (a `{1, 3}` tensor with the new values)

The result is a new tensor identical to the original except row 5 is
replaced:

```
Before:                          After:
index 5: [3.2, 1.5, -4.1]  →    index 5: [0.0, 1.5, 0.0]   (reset to center)
```

All other rows are unchanged. This is the tensor equivalent of
`array[i] = new_value`.

---

## Part 9: Broadcasting -- the key concept

Broadcasting is the single most important Nx concept for ECS work. It lets
you combine tensors of different shapes by automatically stretching the
smaller one.

### The rule

Two dimensions are compatible for broadcasting if they are equal or one of
them is 1. A dimension of size 1 is stretched to match the other.

### Common patterns in Lunity

**Scalar * vector (scaling velocity by dt):**

```
vel:  {128, 3}     dt3: {128, 1}     result: {128, 3}
                         ↑
                   broadcasts across
                   the 3-column axis
```

Each row in `dt3` has one value that multiplies all three columns of that
row in `vel`.

**Vector * vector (element-wise mask):**

```
speed: {128}     is_auto: {128}     result: {128}

  8.0       *       1          =       8.0
  0.0       *       0          =       0.0
```

Same shape, element-wise multiplication. Masking by multiplying with 0 or 1.

**N-by-N pairwise operations (collision detection):**

```
pos:     {N, 3}
pos_i:   {N, 1, 3}    ← reshape to add a "partner" dimension
pos_j:   {1, N, 3}    ← reshape to add an "entity" dimension

diff:    {N, N, 3}    ← broadcasts both to produce all pairs
```

This creates every possible entity-entity distance in one operation. Row `i`,
column `j` of the result is the distance between entity `i` and entity `j`.
This is the foundation of the AABB collision system.

---

## Part 10: `defn` vs `def` -- when to use which

### `defn` (numerical definition)

Used for pure tensor math that operates on the full dataset. The Nx compiler
can optimise these into efficient native code.

Rules inside `defn`:
- All values must be tensors (no atoms, strings, maps, or Elixir structs)
- No Elixir `if`/`case`/`cond` -- use `Nx.select` instead
- No side effects (IO, ETS writes, etc.)
- No calling regular `def` functions

`ApplyVelocity` and `AutoPaddle` are `defn` systems -- they do pure math on
the full tensor set.

### `def` (regular Elixir function)

Used when you need Elixir control flow, side effects, or to escape from the
tensor world to inspect individual values with `Nx.to_number/1`.

`Scoring` is a `def` system -- it uses `Nx.to_number` to read the ball's X
position into a regular Elixir number, then uses a normal `if` to decide
whether to reset:

```elixir
def run(inputs) do
  ball_idx = Nx.to_number(inputs[:ball_idx])
  ball_x = Nx.to_number(inputs.position[ball_idx][0])

  if ball_x < -@reset_x or ball_x > @reset_x do
    reset_ball(inputs, ball_idx)
  else
    %{position: inputs.position, velocity: inputs.velocity, ...}
  end
end
```

You pay a small cost for `Nx.to_number` (it copies data from the tensor
backend), but it is fine for rare events like scoring.

**Rule of thumb:** Use `defn` when processing all entities uniformly. Use
`def` when you need to branch on a specific entity's value or do rare
event handling.

---

## Nx operations reference

Here are the Nx functions used most often in Lunity systems, grouped by
what they do:

### Arithmetic

| Operation | Example | Description |
|-----------|---------|-------------|
| `Nx.add(a, b)` | `Nx.add(pos, displacement)` | Element-wise addition |
| `Nx.subtract(a, b)` | `Nx.subtract(target, current)` | Element-wise subtraction |
| `Nx.multiply(a, b)` | `Nx.multiply(vel, dt)` | Element-wise multiplication |
| `Nx.divide(a, b)` | `Nx.divide(extents, 2.0)` | Element-wise division |
| `Nx.negate(a)` | `Nx.negate(max_step)` | Flip sign of every element |
| `Nx.abs(a)` | `Nx.abs(diff)` | Absolute value of every element |
| `Nx.sign(a)` | `Nx.sign(direction)` | -1, 0, or 1 for each element |

### Comparison (returns 0/1 tensors)

| Operation | Example | Description |
|-----------|---------|-------------|
| `Nx.equal(a, b)` | `Nx.equal(ctrl, 0)` | 1 where equal, 0 elsewhere |
| `Nx.greater(a, b)` | `Nx.greater(speed, 0)` | 1 where a > b |
| `Nx.greater_equal(a, b)` | `Nx.greater_equal(idx, 0)` | 1 where a >= b |
| `Nx.less(a, b)` | `Nx.less(t_enter, t_exit)` | 1 where a < b |
| `Nx.logical_and(a, b)` | `Nx.logical_and(auto, has_speed)` | Boolean AND on 0/1 tensors |
| `Nx.logical_or(a, b)` | `Nx.logical_or(compat_fwd, compat_rev)` | Boolean OR on 0/1 tensors |

### Conditional

| Operation | Example | Description |
|-----------|---------|-------------|
| `Nx.select(cond, a, b)` | `Nx.select(should_move, new_z, old_z)` | Pick `a` where cond=1, `b` where cond=0 |
| `Nx.min(a, b)` | `Nx.min(val, upper_bound)` | Element-wise minimum |
| `Nx.max(a, b)` | `Nx.max(val, lower_bound)` | Element-wise maximum |

### Shape manipulation

| Operation | Example | Description |
|-----------|---------|-------------|
| `Nx.reshape(t, shape)` | `Nx.reshape(dt, {:auto, 1})` | Change shape without changing data |
| `Nx.stack(list, axis: n)` | `Nx.stack([x, y, z], axis: 1)` | Combine tensors along a new axis |
| `Nx.broadcast(t, shape)` | `Nx.broadcast(Nx.tensor(1), {m})` | Expand a scalar to fill a shape |
| `Nx.squeeze(t)` | `Nx.squeeze(result, axes: [1])` | Remove dimensions of size 1 |

### Indexing and slicing

| Operation | Example | Description |
|-----------|---------|-------------|
| `t[i]` | `pos[5]` | Get row at index i |
| `t[i][j]` | `pos[5][2]` | Get element at row i, column j |
| `t[[.., n]]` | `pos[[.., 0]]` | Get column n across all rows |
| `Nx.take(t, indices)` | `Nx.take(pos, Nx.tensor([1,2,5]))` | Gather specific rows by index |
| `Nx.slice(t, start, len)` | `Nx.slice(t, [i, 0], [1, 3])` | Extract a rectangular sub-tensor |
| `Nx.indexed_put(t, idx, val)` | `Nx.indexed_put(pos, [[5]], row)` | Replace rows at given indices |

### Reduction

| Operation | Example | Description |
|-----------|---------|-------------|
| `Nx.sum(t, axes: [n])` | `Nx.sum(push, axes: [1])` | Sum along an axis (collapse it) |
| `Nx.reduce_min(t, axes: [n])` | `Nx.reduce_min(overlap, axes: [2])` | Min along an axis |
| `Nx.reduce_max(t, axes: [n])` | `Nx.reduce_max(t_near, axes: [2])` | Max along an axis |
| `Nx.argmin(t, axis: n)` | `Nx.argmin(overlap, axis: 2)` | Index of the minimum along an axis |
| `Nx.argmax(t, axis: n)` | `Nx.argmax(t_near, axis: 2)` | Index of the maximum along an axis |

### Type conversion

| Operation | Example | Description |
|-----------|---------|-------------|
| `Nx.as_type(t, type)` | `Nx.as_type(mask, :f32)` | Convert dtype (e.g. u8 boolean to f32 for math) |
| `Nx.to_number(t)` | `Nx.to_number(pos[5][0])` | Extract a scalar to an Elixir number (exits tensor world) |
| `Nx.to_flat_list(t)` | `Nx.to_flat_list(row)` | Convert to an Elixir list (exits tensor world) |
| `Nx.tensor(val, type: t)` | `Nx.tensor(0.0, type: :f32)` | Create a tensor from an Elixir value |

---

## Tips for writing systems

1. **Start with `defn`.** Most systems process all entities uniformly. Only
   drop to `def` when you need Elixir control flow or `Nx.to_number`.

2. **Think in columns, not rows.** Instead of "for each entity, update its
   Z position," think "compute the new Z column, then reassemble the
   position tensor."

3. **Mask instead of branch.** Compute the update for everyone, then use
   `Nx.select` to keep the old value for entities that shouldn't change.

4. **Reshape before multiply.** When combining a `{N}` tensor with a
   `{N, 3}` tensor, reshape the `{N}` to `{N, 1}` first so broadcasting
   stretches it across the 3 columns.

5. **Return only what changed.** If your system reads position and velocity
   but only modifies position, the output map only needs
   `%{position: new_pos}`. Unchanged tensors don't need to be written back.

6. **Use `entities: [:name]` for lookups.** When you need one specific
   entity's data, declare it in the system options and use the `_idx` input
   rather than searching.
