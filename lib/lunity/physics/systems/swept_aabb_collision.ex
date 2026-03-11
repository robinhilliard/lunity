defmodule Lunity.Physics.Systems.SweptAABBCollision do
  @moduledoc """
  Swept AABB collision detection and response with integrated velocity.

  Replaces the separate `ApplyVelocity` + `AABBCollision` pipeline with a
  single system that ray-casts movement paths to prevent tunneling at high
  velocities.

  Uses `SweptAABB.detect/1` for contact finding and `SweptAABB.resolve_reflect/2`
  for simple bounce response. A future rigid body system could call the same
  `detect/1` with a different resolver.
  """
  use Lunity.System, type: :tensor

  alias Lunity.Components.{Position, DeltaTime}

  alias Lunity.Physics.Components.{
    Velocity,
    BoxCollider,
    CollisionLayer,
    CollisionMask,
    Restitution,
    Static
  }

  @spec run(%{
          position: Position.t(),
          velocity: Velocity.t(),
          box_collider: BoxCollider.t(),
          collision_layer: CollisionLayer.t(),
          collision_mask: CollisionMask.t(),
          restitution: Restitution.t(),
          static: Static.t(),
          delta_time: DeltaTime.t()
        }) :: %{position: Position.t(), velocity: Velocity.t()}
  def run(inputs) do
    dt = Nx.reshape(inputs.delta_time, {:auto, 1})
    scaled_vel = Nx.multiply(inputs.velocity, dt)

    presence = Lunity.ComponentStore.get_presence_mask(Lunity.Physics.Components.BoxCollider)
    active = active_indices(presence)

    if active == [] do
      %{position: inputs.position, velocity: inputs.velocity}
    else
      compact = gather_rows(inputs, active, scaled_vel)
      m = length(active)

      compact_inputs = %{
        position: compact.position,
        velocity: compact.velocity,
        box_collider: compact.box_collider,
        collision_layer: compact.collision_layer,
        collision_mask: compact.collision_mask,
        restitution: compact.restitution,
        static: compact.static,
        presence: Nx.broadcast(Nx.tensor(1, type: :u8), {m})
      }

      contacts = Lunity.Physics.Collision.SweptAABB.detect(compact_inputs)
      result = Lunity.Physics.Collision.SweptAABB.resolve_reflect(compact_inputs, contacts)

      compact_dt = Nx.take(dt, Nx.tensor(active))
      safe_dt = Nx.max(compact_dt, Nx.tensor(1.0e-6, type: :f32))
      vel_per_s = Nx.divide(result.velocity, safe_dt)

      scatter_back(inputs.position, inputs.velocity, result.position, vel_per_s, active)
    end
  end

  defp active_indices(presence) do
    presence
    |> Nx.to_flat_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} -> if v == 1, do: [i], else: [] end)
  end

  defp gather_rows(inputs, indices, scaled_vel) do
    idx = Nx.tensor(indices)

    %{
      position: Nx.take(inputs.position, idx),
      velocity: Nx.take(scaled_vel, idx),
      box_collider: Nx.take(inputs.box_collider, idx),
      collision_layer: Nx.take(inputs.collision_layer, idx),
      collision_mask: Nx.take(inputs.collision_mask, idx),
      restitution: Nx.take(inputs.restitution, idx),
      static: Nx.take(inputs.static, idx)
    }
  end

  defp scatter_back(full_pos, full_vel, compact_pos, compact_vel, indices) do
    {new_pos, new_vel} =
      indices
      |> Enum.with_index()
      |> Enum.reduce({full_pos, full_vel}, fn {orig_idx, compact_idx}, {p, v} ->
        idx = Nx.tensor([[orig_idx]])
        p = Nx.indexed_put(p, idx, Nx.reshape(compact_pos[compact_idx], {1, 3}))
        v = Nx.indexed_put(v, idx, Nx.reshape(compact_vel[compact_idx], {1, 3}))
        {p, v}
      end)

    %{position: new_pos, velocity: new_vel}
  end
end
