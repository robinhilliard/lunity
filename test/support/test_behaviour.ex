defmodule Lunity.TestBehaviour do
  @moduledoc "Test behaviour for get_blender_extras_script tests."
  use Lunity.NodeBehaviour

  behaviour_properties(
    behaviour: [type: :string, default: "Lunity.TestBehaviour"],
    config: [type: :string, default: "test/config"],
    open_angle: [type: :float, default: 90, min: 0, max: 360],
    health: [type: :integer, default: 100, min: 0]
  )

  @impl Lunity.NodeBehaviour
  def init(_config, _entity_id), do: :ok
end
