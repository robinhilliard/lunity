defmodule Lunity.Physics.Systems.ApplyVelocity do
  @moduledoc "Integrates velocity into position each tick, scaled by delta time."
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
