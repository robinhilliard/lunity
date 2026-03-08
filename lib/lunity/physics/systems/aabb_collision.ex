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
    Lunity.Physics.Collision.AABB.check_and_respond(Map.put(inputs, :presence, presence))
  end
end
