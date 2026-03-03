defmodule Lunity.ConfigLoaderTest do
  use ExUnit.Case, async: true

  alias Lunity.ConfigLoader

  describe "load_config/2" do
    test "loads config from priv/config path" do
      assert {:ok, config} = ConfigLoader.load_config("scenes/doors/level1_door")
      assert config.health == 100
      assert config.open_angle == 90
      assert config.key_id == "default_key"
    end

    test "adds .exs suffix when not present" do
      assert {:ok, config} = ConfigLoader.load_config("scenes/doors/level1_door")
      assert is_map(config)
    end

    test "accepts path with .exs suffix" do
      assert {:ok, config} = ConfigLoader.load_config("scenes/doors/level1_door.exs")
      assert config.health == 100
    end

    test "returns error for nonexistent file" do
      assert {:error, :file_not_found} = ConfigLoader.load_config("nonexistent/path")
    end

    test "rejects path with .." do
      assert {:error, :path_traversal} = ConfigLoader.load_config("scenes/../etc/passwd")
      assert {:error, :path_traversal} = ConfigLoader.load_config("../config/secret")
    end

    test "rejects absolute path" do
      assert {:error, :path_traversal} = ConfigLoader.load_config("/etc/passwd")
    end

    test "loads with app option for dependency" do
      # When Lunity is a dep, caller can pass app: :my_game to load from game's priv
      assert {:ok, _} = ConfigLoader.load_config("scenes/doors/level1_door", app: :lunity)
    end
  end

  describe "merge_config/2" do
    test "merges properties over config" do
      config = %{health: 100, open_angle: 90}
      properties = %{"open_angle" => 45, "key_id" => "gold_key"}

      merged = ConfigLoader.merge_config(config, properties)

      assert merged.health == 100
      assert merged.open_angle == 45
      assert merged.key_id == "gold_key"
    end

    test "filters nil values from properties" do
      config = %{health: 100, open_angle: 90}
      properties = %{"health" => nil, "open_angle" => 45}

      merged = ConfigLoader.merge_config(config, properties)

      assert merged.health == 100
      assert merged.open_angle == 45
    end

    test "handles nil properties" do
      config = %{health: 100}
      assert ConfigLoader.merge_config(config, nil) == %{health: 100}
    end

    test "normalizes string keys to atoms" do
      config = %{health: 100}
      properties = %{"extra" => "value"}

      merged = ConfigLoader.merge_config(config, properties)
      assert merged.extra == "value"
      assert Map.has_key?(merged, :extra)
    end

    test "accepts keyword list as config" do
      config = [health: 100, open_angle: 90]
      properties = %{"open_angle" => 60}

      merged = ConfigLoader.merge_config(config, properties)
      assert merged.health == 100
      assert merged.open_angle == 60
    end
  end
end
