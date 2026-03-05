defmodule Lunity.TestPrefab do
  @moduledoc "Test prefab for get_blender_extras_script tests."
  use Lunity.Prefab, glb: "test_box"

  prefab do
    property(:open_angle, :float, default: 90, min: 0, max: 360, subtype: :angle)
    property(:health, :integer, default: 100, min: 0)
  end
end
