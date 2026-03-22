defmodule Lunity.Physics.Systems.SweptAABBCollision do
  @moduledoc """
  Swept AABB collision detection and response with integrated velocity.

  Replaces the separate `ApplyVelocity` + `AABBCollision` pipeline with a
  single system that ray-casts movement paths to prevent tunneling at high
  velocities.

  Uses `SweptAABB.detect/1` for contact finding and `SweptAABB.resolve_reflect/2`
  for simple bounce response. A future rigid body system could call the same
  `detect/1` with a different resolver.

  Declares `filter: BoxCollider` so the TickRunner automatically gathers
  only entities with a box collider into compact tensors before calling
  `run/1`, and scatters the results back afterward.
  """
  use Lunity.System, type: :tensor, filter: Lunity.Physics.Components.BoxCollider

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
    m = Nx.axis_size(inputs.position, 0)
    dt = Nx.reshape(inputs.delta_time, {:auto, 1})
    scaled_vel = Nx.multiply(inputs.velocity, dt)

    compact_inputs = %{
      position: inputs.position,
      velocity: scaled_vel,
      box_collider: inputs.box_collider,
      collision_layer: inputs.collision_layer,
      collision_mask: inputs.collision_mask,
      restitution: inputs.restitution,
      static: inputs.static,
      presence: Nx.broadcast(Nx.tensor(1, type: :u8), {m})
    }

    contacts = Lunity.Physics.Collision.SweptAABB.detect(compact_inputs)
    result = Lunity.Physics.Collision.SweptAABB.resolve_reflect(compact_inputs, contacts)

    safe_dt = Nx.max(dt, Nx.tensor(1.0e-6, type: :f32))
    vel_per_s = Nx.divide(result.velocity, safe_dt)

    %{position: result.position, velocity: vel_per_s}
  end
end
