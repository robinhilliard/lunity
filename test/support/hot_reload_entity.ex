defmodule Lunity.HotReloadTest.Entity do
  @moduledoc false
  use Lunity.Entity

  entity do
    component(Lunity.Components.Position)
  end

  @impl Lunity.Entity
  def init(config, entity_id) do
    pos = Map.get(config, :position, {0.0, 0.0, 0.0})
    Lunity.Components.Position.put(entity_id, pos)
    :ok
  end
end
