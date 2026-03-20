defmodule Lunity.SceneLoaderTest do
  use ExUnit.Case, async: true

  alias Lunity.SceneLoader

  describe "load_scene/2" do
    test "rejects path traversal" do
      assert {:error, :path_traversal} = SceneLoader.load_scene("../etc/passwd", [])
      assert {:error, :path_traversal} = SceneLoader.load_scene("scenes/../../secret", [])
    end

    test "rejects absolute path" do
      assert {:error, :path_traversal} = SceneLoader.load_scene("/etc/passwd", [])
    end

    test "returns file_not_found for nonexistent scene" do
      # No priv/scenes/nonexistent.glb
      assert {:error, :file_not_found} = SceneLoader.load_scene("nonexistent", [])
    end
  end
end
