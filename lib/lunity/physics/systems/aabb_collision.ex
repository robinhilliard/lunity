defmodule Lunity.Physics.Systems.AABBCollision do
  @moduledoc """
  Engine-level AABB collision detection and response system.

  Reads positions, velocities, box colliders, and collision configuration.
  Writes corrected positions and velocities after resolving overlaps.

  Games include this in their Manager's system list -- no wrapper needed.
  """
  use Lunity.System,
    type: :tensor,
    reads: [
      Lunity.Components.Position,
      Lunity.Physics.Components.Velocity,
      Lunity.Physics.Components.BoxCollider,
      Lunity.Physics.Components.CollisionLayer,
      Lunity.Physics.Components.CollisionMask,
      Lunity.Physics.Components.Restitution,
      Lunity.Physics.Components.Static
    ],
    writes: [Lunity.Components.Position, Lunity.Physics.Components.Velocity]

  def run(inputs) do
    presence = Lunity.ComponentStore.get_presence_mask(Lunity.Physics.Components.BoxCollider)
    result = Lunity.Physics.Collision.AABB.check_and_respond(Map.put(inputs, :presence, presence))

    pos_diff = Nx.subtract(result.position, inputs.position)
    max_change = Nx.reduce_max(Nx.abs(pos_diff)) |> Nx.to_number()
    if max_change > 0.001, do: IO.puts("[AABB] collision push: #{max_change}")

    vel_diff = Nx.subtract(result.velocity, inputs.velocity)
    max_vel_change = Nx.reduce_max(Nx.abs(vel_diff)) |> Nx.to_number()
    if max_vel_change > 0.001, do: IO.puts("[AABB] velocity change: #{max_vel_change}")

    result
  end
end
