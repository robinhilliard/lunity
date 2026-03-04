defmodule Lunity.NodeBehaviourTest do
  use ExUnit.Case, async: true

  alias Lunity.NodeBehaviour

  defmodule SampleBehaviour do
    use Lunity.NodeBehaviour

    behaviour_properties(
      health: [type: :integer, default: 100, min: 0, max: 200],
      open_angle: [type: :float, default: 90, min: 0, max: 360],
      key_id: [type: :string]
    )

    @impl Lunity.NodeBehaviour
    def init(_config, _entity_id), do: :ok
  end

  describe "extras_spec/1" do
    test "returns the extras spec for a behaviour module" do
      spec = NodeBehaviour.extras_spec(SampleBehaviour)
      assert is_map(spec)
      assert Map.has_key?(spec, :health)
      assert spec.health[:type] == :integer
      assert spec.health[:default] == 100
      assert spec.health[:min] == 0
      assert spec.health[:max] == 200
    end
  end

  describe "validate_extras/2" do
    test "returns :ok for valid extras" do
      assert :ok = NodeBehaviour.validate_extras(SampleBehaviour, %{"health" => 50})
      assert :ok = NodeBehaviour.validate_extras(SampleBehaviour, %{health: 150})
    end

    test "returns error for value below min" do
      assert {:error, [{:health, "must be >= 0"}]} =
               NodeBehaviour.validate_extras(SampleBehaviour, %{health: -1})
    end

    test "returns error for value above max" do
      assert {:error, [{:health, "must be <= 200"}]} =
               NodeBehaviour.validate_extras(SampleBehaviour, %{health: 250})
    end

    test "returns error for wrong type" do
      assert {:error, [{:health, "must be integer"}]} =
               NodeBehaviour.validate_extras(SampleBehaviour, %{health: "not a number"})
    end

    test "returns error when extras is not a map" do
      assert {:error, :extras_must_be_map} =
               NodeBehaviour.validate_extras(SampleBehaviour, "invalid")
    end
  end

  describe "from_config/2" do
    test "builds struct from merged config" do
      config = %{health: 75, open_angle: 45}
      struct = NodeBehaviour.from_config(SampleBehaviour, config)
      assert struct.health == 75
      assert struct.open_angle == 45
      assert struct.key_id == nil
    end

    test "uses defaults for missing keys" do
      config = %{}
      struct = NodeBehaviour.from_config(SampleBehaviour, config)
      assert struct.health == 100
      assert struct.open_angle == 90
    end
  end

  describe "resolve_module/1" do
    test "resolves behaviour name to module" do
      assert NodeBehaviour.resolve_module("Lunity.NodeBehaviourTest.SampleBehaviour") ==
               Lunity.NodeBehaviourTest.SampleBehaviour
    end
  end
end
