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

  alias Lunity.Components.Position

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
          static: Static.t()
        }) :: %{position: Position.t(), velocity: Velocity.t()}
  def run(inputs) do
    presence = Lunity.ComponentStore.get_presence_mask(Lunity.Physics.Components.BoxCollider)
    all_inputs = Map.put(inputs, :presence, presence)

    contacts = Lunity.Physics.Collision.SweptAABB.detect(all_inputs)
    Lunity.Physics.Collision.SweptAABB.resolve_reflect(all_inputs, contacts)
  end
end
