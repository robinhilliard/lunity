defmodule Lunity.HotReloadTest.Manager do
  @moduledoc false
  @behaviour Lunity.Manager

  @impl true
  def components do
    [Lunity.Components.DeltaTime, Lunity.Components.Position]
  end

  @impl true
  def systems do
    [Lunity.HotReloadTest.System]
  end

  @impl true
  def tick_rate, do: 60

  def __lunity_manager__, do: true
end
