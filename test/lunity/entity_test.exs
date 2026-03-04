defmodule Lunity.EntityTest do
  use ExUnit.Case, async: true

  alias Lunity.Entity

  defmodule SampleEntity do
    use Lunity.Entity

    entity do
      property :health, :integer, default: 100, min: 0, max: 200
      property :open_angle, :float, default: 90, min: 0, max: 360
      property :key_id, :string
    end

    @impl Lunity.Entity
    def init(_config, _entity_id), do: :ok
  end

  defmodule EntityWithComponents do
    use Lunity.Entity, config: "test/defaults"

    entity do
      property :speed, :float, default: 5.0
      property :side, :atom, values: [:left, :right]

      component FakeVelocity
      component FakePaddleInput
    end

    @impl Lunity.Entity
    def init(_config, _entity_id), do: :ok
  end

  describe "extras_spec/1" do
    test "returns the extras spec for an entity module" do
      spec = Entity.extras_spec(SampleEntity)
      assert is_map(spec)
      assert Map.has_key?(spec, :health)
      assert spec.health[:type] == :integer
      assert spec.health[:default] == 100
      assert spec.health[:min] == 0
      assert spec.health[:max] == 200
    end
  end

  describe "components/1" do
    test "returns declared components" do
      assert Entity.components(EntityWithComponents) == [FakeVelocity, FakePaddleInput]
    end

    test "returns empty list for entity with no components" do
      assert Entity.components(SampleEntity) == []
    end
  end

  describe "config_path/1" do
    test "returns config path from use options" do
      assert Entity.config_path(EntityWithComponents) == "test/defaults"
    end

    test "returns nil when no config path specified" do
      assert Entity.config_path(SampleEntity) == nil
    end
  end

  describe "validate_extras/2" do
    test "returns :ok for valid extras" do
      assert :ok = Entity.validate_extras(SampleEntity, %{"health" => 50})
      assert :ok = Entity.validate_extras(SampleEntity, %{health: 150})
    end

    test "returns error for value below min" do
      assert {:error, [{:health, "must be >= 0"}]} =
               Entity.validate_extras(SampleEntity, %{health: -1})
    end

    test "returns error for value above max" do
      assert {:error, [{:health, "must be <= 200"}]} =
               Entity.validate_extras(SampleEntity, %{health: 250})
    end

    test "returns error for wrong type" do
      assert {:error, [{:health, "must be integer"}]} =
               Entity.validate_extras(SampleEntity, %{health: "not a number"})
    end

    test "returns error when extras is not a map" do
      assert {:error, :extras_must_be_map} =
               Entity.validate_extras(SampleEntity, "invalid")
    end

    test "validates atom values constraint" do
      assert :ok = Entity.validate_extras(EntityWithComponents, %{side: :left})

      assert {:error, [{:side, "must be one of [:left, :right]"}]} =
               Entity.validate_extras(EntityWithComponents, %{side: :top})
    end
  end

  describe "from_config/2" do
    test "builds struct from merged config" do
      config = %{health: 75, open_angle: 45}
      struct = Entity.from_config(SampleEntity, config)
      assert struct.health == 75
      assert struct.open_angle == 45
      assert struct.key_id == nil
    end

    test "uses defaults for missing keys" do
      config = %{}
      struct = Entity.from_config(SampleEntity, config)
      assert struct.health == 100
      assert struct.open_angle == 90
    end
  end

  describe "resolve_module/1" do
    test "resolves entity name to module" do
      assert Entity.resolve_module("Lunity.EntityTest.SampleEntity") ==
               Lunity.EntityTest.SampleEntity
    end
  end
end
