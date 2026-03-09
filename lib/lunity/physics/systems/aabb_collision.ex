defmodule Lunity.Physics.Systems.AABBCollision do
  @moduledoc """
  Engine-level AABB collision detection and response system.

  Reads positions, velocities, box colliders, and collision configuration.
  Writes corrected positions and velocities after resolving overlaps.

  Games include this in their Manager's system list -- no wrapper needed.
  """
  use Lunity.System, type: :tensor

  alias Lunity.Components.Position
  alias Lunity.Physics.Components.{Velocity, BoxCollider, CollisionLayer, CollisionMask, Restitution, Static}

  @spec run(%{
          position: Position.t(),
          velocity: Velocity.t(),
          box_collider: BoxCollider.t(),
          collision_layer: CollisionLayer.t(),
          collision_mask: CollisionMask.t(),
          restitution: Restitution.t(),
          static: Static.t()
        }) :: %{position: Position.t(), velocity: Velocity.t()}
  def run(inputs) do
    presence = Lunity.ComponentStore.get_presence_mask(Lunity.Physics.Components.BoxCollider)
    Lunity.Physics.Collision.AABB.check_and_respond(Map.put(inputs, :presence, presence))
  end
end
