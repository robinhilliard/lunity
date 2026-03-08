defmodule Lunity.Physics.Systems.ApplyVelocity do
  @moduledoc "Integrates velocity into position each tick."
  use Lunity.System,
    type: :tensor,
    reads: [Lunity.Components.Position, Lunity.Physics.Components.Velocity],
    writes: [Lunity.Components.Position]

  import Nx.Defn

  defn run(%{position: pos, velocity: vel}) do
    %{position: Nx.add(pos, vel)}
  end
end
