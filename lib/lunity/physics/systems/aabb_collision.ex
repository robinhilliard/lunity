defmodule Lunity.Physics.Systems.AABBCollision do
  @moduledoc """
  Engine-level AABB collision detection and response system.

  Reads positions, velocities, box colliders, and collision configuration.
  Writes corrected positions and velocities after resolving overlaps.

  Declares `filter: BoxCollider` so only collider-bearing entities are gathered
  into the `defn` kernel (presence is implicit / all-ones in the compact view).

  Games include this in their Manager's system list -- no wrapper needed.
  """
  use Lunity.System, type: :tensor, filter: Lunity.Physics.Components.BoxCollider

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
  defn run(inputs) do
    m = Nx.axis_size(inputs.position, 0)

    Lunity.Physics.Collision.AABB.check_and_respond(%{
      position: inputs.position,
      velocity: inputs.velocity,
      box_collider: inputs.box_collider,
      collision_layer: inputs.collision_layer,
      collision_mask: inputs.collision_mask,
      restitution: inputs.restitution,
      static: inputs.static,
      presence: Nx.broadcast(Nx.tensor(1, type: :u8), {m})
    })
  end
end
