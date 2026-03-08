defmodule Lunity.Physics.Collision.AABB do
  @moduledoc """
  Tensor-based AABB collision detection and response.

  Performs N*N pairwise overlap checks using Nx broadcasting, then applies
  position push-out and velocity reflection for colliding pairs.

  The kernel operates on dense `{N, ...}` tensors. Today N = ComponentStore
  capacity (all entities in one call). Future spatial partitioning would
  gather subsets and call this kernel multiple times per tick -- the math
  is identical either way.
  """

  import Nx.Defn

  @doc """
  Detect AABB collisions and apply response (push-out + velocity reflection).

  Expects a map with keys:
  - `:position` - `{N, 3}` entity positions
  - `:velocity` - `{N, 3}` entity velocities
  - `:box_collider` - `{N, 3}` AABB half-extents
  - `:collision_layer` - `{N}` integer bitmask (which layer entity is on)
  - `:collision_mask` - `{N}` integer bitmask (which layers entity collides with)
  - `:restitution` - `{N}` bounciness 0.0-1.0
  - `:static` - `{N}` 1 = static/kinematic, 0 = dynamic
  - `:presence` - `{N}` 1 = entity exists, 0 = empty slot

  Returns `%{position: corrected_pos, velocity: corrected_vel}`.
  """
  defn check_and_respond(inputs) do
    pos = inputs.position
    vel = inputs.velocity
    extents = Nx.divide(inputs.box_collider, 2.0)
    layers = inputs.collision_layer
    masks = inputs.collision_mask
    restitution = inputs.restitution
    static = inputs.static
    presence = inputs.presence

    n = Nx.axis_size(pos, 0)

    # --- Step 1: Pairwise overlap ---
    pos_i = Nx.reshape(pos, {n, 1, 3})
    pos_j = Nx.reshape(pos, {1, n, 3})
    ext_i = Nx.reshape(extents, {n, 1, 3})
    ext_j = Nx.reshape(extents, {1, n, 3})

    diff = Nx.abs(Nx.subtract(pos_i, pos_j))
    sum_ext = Nx.add(ext_i, ext_j)
    overlap = Nx.subtract(sum_ext, diff)

    # --- Step 2: Determine colliding pairs ---
    overlap_positive = Nx.greater(overlap, 0)
    colliding = Nx.reduce_min(overlap_positive, axes: [2])

    # Remove self-collision
    not_self = Nx.subtract(1, Nx.eye(n))
    colliding = Nx.multiply(colliding, not_self)

    # Apply presence masks
    pres_i = Nx.reshape(presence, {n, 1})
    pres_j = Nx.reshape(presence, {1, n})
    colliding = Nx.multiply(colliding, Nx.multiply(pres_i, pres_j))

    # --- Step 3: Layer/mask compatibility ---
    layers_i = Nx.reshape(layers, {n, 1})
    layers_j = Nx.reshape(layers, {1, n})
    masks_i = Nx.reshape(masks, {n, 1})

    # Entity i collides with j if j's layer is in i's mask
    layer_compat = Nx.greater(Nx.bitwise_and(masks_i, layers_j), 0)
    # Symmetry: also check j's mask against i's layer
    masks_j = Nx.reshape(masks, {1, n})
    reverse_compat = Nx.greater(Nx.bitwise_and(masks_j, layers_i), 0)
    compat = Nx.logical_or(layer_compat, reverse_compat)

    colliding = Nx.multiply(colliding, compat)

    # --- Step 4: Find minimum overlap axis (collision normal) ---
    big = Nx.tensor(1.0e10, type: :f32)

    safe_overlap =
      Nx.select(
        Nx.logical_and(Nx.greater(overlap, 0), Nx.reshape(colliding, {n, n, 1})),
        overlap,
        big
      )

    min_overlap_axis = Nx.argmin(safe_overlap, axis: 2)

    axis_mask =
      Nx.equal(
        Nx.reshape(min_overlap_axis, {n, n, 1}),
        Nx.tensor([0, 1, 2])
      )

    axis_mask = Nx.as_type(axis_mask, :f32)

    # --- Step 5: Compute push-out ---
    direction = Nx.sign(Nx.subtract(pos_i, pos_j))
    # Clamp direction to avoid zero (when positions are identical on an axis)
    direction = Nx.select(Nx.equal(direction, 0), Nx.tensor(1.0, type: :f32), direction)

    push_per_pair =
      Nx.multiply(
        Nx.multiply(Nx.multiply(direction, overlap), axis_mask),
        Nx.reshape(colliding, {n, n, 1})
      )

    total_push = Nx.sum(push_per_pair, axes: [1])

    is_dynamic = Nx.reshape(Nx.as_type(Nx.equal(static, 0), :f32), {n, 1})
    total_push = Nx.multiply(total_push, is_dynamic)

    new_pos = Nx.add(pos, total_push)

    # --- Step 6: Velocity reflection ---
    # For each entity, determine which axes had collisions
    abs_axis_contrib = Nx.multiply(axis_mask, Nx.reshape(colliding, {n, n, 1}))
    collision_axes = Nx.as_type(Nx.greater(Nx.sum(abs_axis_contrib, axes: [1]), 0), :f32)

    rest = Nx.reshape(restitution, {n, 1})
    # On collision axes: negate and scale by restitution. On others: keep.
    vel_factor = Nx.subtract(1.0, Nx.multiply(collision_axes, Nx.add(1.0, rest)))
    reflected_vel = Nx.multiply(vel, vel_factor)

    # Static entities keep original velocity, dynamic entities get reflected
    # (is_dynamic is {n, 1}, broadcasts to {n, 3} via multiply)
    new_vel =
      Nx.add(
        Nx.multiply(reflected_vel, is_dynamic),
        Nx.multiply(vel, Nx.subtract(1.0, is_dynamic))
      )

    %{position: new_pos, velocity: new_vel}
  end
end
