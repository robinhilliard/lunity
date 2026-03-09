defmodule Lunity.Physics.Systems.ApplyVelocity do
  @moduledoc "Integrates velocity into position each tick."
  use Lunity.System, type: :tensor

  alias Lunity.Components.Position
  alias Lunity.Physics.Components.Velocity

  @spec run(%{position: Position.t(), velocity: Velocity.t()}) :: %{position: Position.t()}
  defn run(%{position: pos, velocity: vel}) do
    %{position: Nx.add(pos, vel)}
  end
end
