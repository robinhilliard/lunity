defmodule Lunity.TestEntity do
  @moduledoc "Test entity for get_blender_extras_script tests."
  use Lunity.Entity, config: "test/config"

  entity do
    property(:open_angle, :float, default: 90, min: 0, max: 360)
    property(:health, :integer, default: 100, min: 0)
  end

  @impl Lunity.Entity
  def init(_config, _entity_id), do: :ok
end
