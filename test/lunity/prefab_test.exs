defmodule Lunity.PrefabTest do
  use ExUnit.Case, async: true

  alias Lunity.Prefab

  defmodule SimplePrefab do
    use Lunity.Prefab, glb: "box"

    prefab do
      property(:color, :atom, values: [:grey, :red, :blue], default: :grey)
      property(:shininess, :float, default: 0.5, min: 0.0, max: 1.0)
    end
  end

  defmodule DoorPrefab do
    use Lunity.Prefab, glb: "door"

    prefab do
      property(:open_angle, :float,
        default: 90.0,
        min: 0.0,
        max: 180.0,
        soft_min: 15.0,
        soft_max: 120.0,
        step: 5,
        precision: 1,
        subtype: :angle,
        description: "Maximum angle the door opens to"
      )

      property(:tint, :float_array,
        length: 4,
        default: [0.5, 0.5, 0.5, 1.0],
        subtype: :gamma_color,
        description: "Door tint color (RGBA)"
      )

      property(:locked, :boolean, default: false, description: "Whether the door starts locked")
    end
  end

  describe "glb_id/1" do
    test "returns the GLB file ID" do
      assert Prefab.glb_id(SimplePrefab) == "box"
      assert Prefab.glb_id(DoorPrefab) == "door"
    end
  end

  describe "extras_spec/1" do
    test "returns the extras spec" do
      spec = Prefab.extras_spec(SimplePrefab)
      assert is_map(spec)
      assert spec.color[:type] == :atom
      assert spec.color[:default] == :grey
      assert spec.shininess[:type] == :float
    end

    test "includes Blender metadata" do
      spec = Prefab.extras_spec(DoorPrefab)
      angle = spec.open_angle
      assert angle[:subtype] == :angle
      assert angle[:soft_min] == 15.0
      assert angle[:soft_max] == 120.0
      assert angle[:step] == 5
      assert angle[:precision] == 1
      assert angle[:description] == "Maximum angle the door opens to"
    end

    test "includes array type with length" do
      spec = Prefab.extras_spec(DoorPrefab)
      tint = spec.tint
      assert tint[:type] == :float_array
      assert tint[:length] == 4
      assert tint[:subtype] == :gamma_color
    end
  end

  describe "validate_extras/2" do
    test "validates valid extras" do
      assert :ok = Prefab.validate_extras(SimplePrefab, %{color: :red, shininess: 0.8})
    end

    test "validates atom values constraint" do
      assert {:error, [{:color, "must be one of [:grey, :red, :blue]"}]} =
               Prefab.validate_extras(SimplePrefab, %{color: :green})
    end

    test "validates float range" do
      assert {:error, [{:shininess, "must be <= 1.0"}]} =
               Prefab.validate_extras(SimplePrefab, %{shininess: 1.5})
    end

    test "validates float_array type" do
      assert :ok = Prefab.validate_extras(DoorPrefab, %{tint: [1.0, 0.0, 0.0, 1.0]})

      assert {:error, [{:tint, "all elements must be numbers"}]} =
               Prefab.validate_extras(DoorPrefab, %{tint: ["red", 0, 0, 1]})
    end

    test "validates array length" do
      assert {:error, [{:tint, "array must have 4 elements"}]} =
               Prefab.validate_extras(DoorPrefab, %{tint: [1.0, 0.0, 0.0]})
    end
  end

  describe "from_config/2" do
    test "builds struct with defaults" do
      s = Prefab.from_config(SimplePrefab, %{})
      assert s.color == :grey
      assert s.shininess == 0.5
    end

    test "overrides defaults with provided values" do
      s = Prefab.from_config(SimplePrefab, %{color: :red})
      assert s.color == :red
      assert s.shininess == 0.5
    end
  end

  describe "struct generation" do
    test "prefab module generates a struct" do
      s = %SimplePrefab{}
      assert s.color == :grey
      assert s.shininess == 0.5
    end

    test "door prefab struct has defaults" do
      d = %DoorPrefab{}
      assert d.open_angle == 90.0
      assert d.tint == [0.5, 0.5, 0.5, 1.0]
      assert d.locked == false
    end
  end
end
