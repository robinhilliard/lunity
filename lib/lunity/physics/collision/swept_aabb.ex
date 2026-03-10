defmodule Lunity.Physics.Collision.SweptAABB do
  @moduledoc """
  Swept AABB collision detection and response.

  Uses ray-casting along entity movement paths to detect collisions that
  discrete overlap checks would miss, preventing tunneling at high velocities.

  Split into `detect/1` and `resolve_reflect/2` so the detection phase can be
  reused with different response strategies (e.g. a future rigid body solver).
  """

  import Nx.Defn

  @doc """
  Detect swept AABB collisions along entity movement paths.

  Ray-casts each entity's velocity vector against the Minkowski-expanded AABBs
  of all other entities to find the earliest collision time.

  Expects a map with keys:
  - `:position`        - `{N, 3}` pre-integration positions
  - `:velocity`        - `{N, 3}` velocities (movement this tick)
  - `:box_collider`    - `{N, 3}` AABB full sizes
  - `:collision_layer` - `{N}` integer bitmask
  - `:collision_mask`  - `{N}` integer bitmask
  - `:static`          - `{N}` 1 = static, 0 = dynamic
  - `:presence`        - `{N}` 1 = entity exists, 0 = empty slot

  Returns a contacts map:
  - `:has_collision`  - `{N}` u8, whether entity has a swept collision
  - `:collision_time` - `{N}` f32, earliest collision time (0..1)
  - `:collision_axis` - `{N}` s64, normal axis (0=x, 1=y, 2=z)
  - `:normal_sign`    - `{N}` f32, sign of collision normal (+1 or -1)
  """
  defn detect(inputs) do
    pos = inputs.position
    vel = inputs.velocity
    extents = Nx.divide(inputs.box_collider, 2.0)
    layers = inputs.collision_layer
    masks = inputs.collision_mask
    presence = inputs.presence

    n = Nx.axis_size(pos, 0)

    pos_i = Nx.reshape(pos, {n, 1, 3})
    pos_j = Nx.reshape(pos, {1, n, 3})
    vel_i = Nx.reshape(vel, {n, 1, 3})
    vel_j = Nx.reshape(vel, {1, n, 3})
    ext_i = Nx.reshape(extents, {n, 1, 3})
    ext_j = Nx.reshape(extents, {1, n, 3})

    rel_vel = Nx.subtract(vel_i, vel_j)
    sum_ext = Nx.add(ext_i, ext_j)

    box_min = Nx.subtract(pos_j, sum_ext)
    box_max = Nx.add(pos_j, sum_ext)

    # Safe reciprocal velocity (clamp near-zero to epsilon to avoid inf/NaN)
    eps = Nx.tensor(1.0e-10, type: :f32)
    abs_rv = Nx.abs(rel_vel)
    vel_nonzero = Nx.greater(abs_rv, eps)

    safe_vel =
      Nx.select(
        vel_nonzero,
        rel_vel,
        Nx.select(Nx.greater_equal(rel_vel, 0), eps, Nx.negate(eps))
      )

    inv_vel = Nx.divide(1.0, safe_vel)
    t1 = Nx.multiply(Nx.subtract(box_min, pos_i), inv_vel)
    t2 = Nx.multiply(Nx.subtract(box_max, pos_i), inv_vel)

    t_near = Nx.min(t1, t2)
    t_far = Nx.max(t1, t2)

    # Zero-velocity axes: use static containment
    # Inside -> always overlapping on this axis; outside -> never
    inside =
      Nx.logical_and(
        Nx.greater(pos_i, box_min),
        Nx.less(pos_i, box_max)
      )

    big = Nx.tensor(1.0e10, type: :f32)
    t_near = Nx.select(vel_nonzero, t_near, Nx.select(inside, Nx.negate(big), big))
    t_far = Nx.select(vel_nonzero, t_far, Nx.select(inside, big, Nx.negate(big)))

    # Slab intersection: entry = max of per-axis entries, exit = min of per-axis exits
    t_enter = Nx.reduce_max(t_near, axes: [2])
    t_exit = Nx.reduce_min(t_far, axes: [2])

    # Collision normal axis: the last axis to enter (bottleneck slab)
    collision_axis_pair = Nx.argmax(t_near, axis: 2)

    # Valid swept collision: ray enters before it exits, within [0, 1]
    valid =
      Nx.logical_and(
        Nx.less_equal(t_enter, t_exit),
        Nx.logical_and(Nx.greater_equal(t_enter, 0.0), Nx.less_equal(t_enter, 1.0))
      )

    # No self-collision
    valid = Nx.logical_and(valid, Nx.equal(Nx.eye(n), 0))

    # Presence filter
    pres_i = Nx.reshape(presence, {n, 1})
    pres_j = Nx.reshape(presence, {1, n})

    valid =
      Nx.logical_and(
        valid,
        Nx.logical_and(Nx.greater(pres_i, 0), Nx.greater(pres_j, 0))
      )

    # Layer/mask compatibility
    layers_i = Nx.reshape(layers, {n, 1})
    layers_j = Nx.reshape(layers, {1, n})
    masks_i = Nx.reshape(masks, {n, 1})
    masks_j = Nx.reshape(masks, {1, n})

    compat =
      Nx.logical_or(
        Nx.greater(Nx.bitwise_and(masks_i, layers_j), 0),
        Nx.greater(Nx.bitwise_and(masks_j, layers_i), 0)
      )

    valid = Nx.logical_and(valid, compat)

    # --- Per-entity: find earliest collision across all partners ---
    no_hit = Nx.tensor(2.0, type: :f32)
    t_enter_masked = Nx.select(valid, t_enter, no_hit)

    earliest_t = Nx.reduce_min(t_enter_masked, axes: [1])
    earliest_j = Nx.argmin(t_enter_masked, axes: [1])
    has_collision = Nx.less(earliest_t, no_hit)

    # Gather collision axis for the earliest partner
    idx = Nx.reshape(earliest_j, {n, 1})
    collision_axis = Nx.squeeze(Nx.take_along_axis(collision_axis_pair, idx, axis: 1))

    # Normal sign: direction from partner j toward entity i on the collision axis
    pos_diff = Nx.subtract(pos_i, pos_j)
    idx_3 = Nx.broadcast(Nx.reshape(earliest_j, {n, 1, 1}), {n, 1, 3})
    diff_vec = Nx.squeeze(Nx.take_along_axis(pos_diff, idx_3, axis: 1), axes: [1])

    axis_one_hot =
      Nx.as_type(
        Nx.equal(Nx.reshape(collision_axis, {n, 1}), Nx.tensor([0, 1, 2])),
        :f32
      )

    diff_on_axis = Nx.sum(Nx.multiply(diff_vec, axis_one_hot), axes: [1])
    normal_sign = Nx.sign(diff_on_axis)
    normal_sign = Nx.select(Nx.equal(normal_sign, 0), Nx.tensor(1.0, type: :f32), normal_sign)

    %{
      has_collision: has_collision,
      collision_time: earliest_t,
      collision_axis: collision_axis,
      normal_sign: normal_sign
    }
  end

  @doc """
  Resolve collisions with simple velocity reflection.

  Integrates velocity into position, reflecting on the collision normal for
  dynamic entities that had a swept collision. Suitable for simple bounce
  physics (e.g. Pong).

  For each dynamic entity with a collision at time `t`:
  1. Advance to collision point: `pos + vel * t`
  2. Reflect velocity on collision axis (scaled by restitution)
  3. Apply remaining movement: `pos += reflected_vel * (1 - t)`

  Entities without collisions integrate normally: `pos + vel`.
  Static entities keep their original velocity.
  """
  defn resolve_reflect(inputs, contacts) do
    pos = inputs.position
    vel = inputs.velocity
    restitution = inputs.restitution
    static = inputs.static

    n = Nx.axis_size(pos, 0)

    is_dynamic = Nx.equal(static, 0)
    apply_response = Nx.logical_and(contacts.has_collision, is_dynamic)
    apply_f = Nx.as_type(apply_response, :f32)
    apply_3 = Nx.reshape(apply_f, {n, 1})

    # Reflect velocity: negate collision-axis component, scale by restitution
    axis_mask =
      Nx.as_type(
        Nx.equal(Nx.reshape(contacts.collision_axis, {n, 1}), Nx.tensor([0, 1, 2])),
        :f32
      )

    rest = Nx.reshape(restitution, {n, 1})
    reflect_factor = Nx.subtract(1.0, Nx.multiply(axis_mask, Nx.add(1.0, rest)))
    reflected_vel = Nx.multiply(vel, reflect_factor)

    # Dynamic entities with collision get reflected velocity; everyone else keeps theirs
    new_vel =
      Nx.add(
        Nx.multiply(reflected_vel, apply_3),
        Nx.multiply(vel, Nx.subtract(1.0, apply_3))
      )

    # Position: pos + vel * t  +  new_vel * (1 - t)
    # No-collision entities: t = 1.0, remaining = 0.0 -> pos + vel
    # Collision entities: advance to contact, then continue with reflected velocity
    t = Nx.select(apply_response, contacts.collision_time, Nx.tensor(1.0, type: :f32))
    t_col = Nx.reshape(t, {n, 1})
    remaining = Nx.subtract(1.0, t_col)

    new_pos =
      Nx.add(
        Nx.add(pos, Nx.multiply(vel, t_col)),
        Nx.multiply(new_vel, remaining)
      )

    %{position: new_pos, velocity: new_vel}
  end
end
