defmodule Lunity.Editor.SourcePatcherTest do
  use ExUnit.Case, async: true

  alias Lunity.Editor.SourcePatcher

  @sample_scene ~S'''
  defmodule MyGame.Scenes.Arena do
    use Lunity.Scene

    scene do
      node(:floor, prefab: MyGame.Prefabs.Box, position: {0, -1, 0}, scale: {12, 0.3, 6})

      node(:ball,
        prefab: MyGame.Prefabs.Box,
        entity: MyGame.Entities.Ball,
        position: {0, 0.5, 0},
        scale: {0.4, 0.4, 0.4}
      )

      node(:paddle,
        prefab: MyGame.Prefabs.Box,
        position: {-18, 0.5, 0},
        scale: {0.3, 0.3, 1.5}
      )
    end
  end
  '''

  describe "patch_source/4" do
    test "patches position on a single-line node" do
      assert {:ok, patched} =
               SourcePatcher.patch_source(@sample_scene, :floor, :position, {1, -2, 3})

      assert patched =~ "position: {1, -2, 3}"
      # scale unchanged
      assert patched =~ "scale: {12, 0.3, 6}"
    end

    test "patches scale on a single-line node" do
      assert {:ok, patched} =
               SourcePatcher.patch_source(@sample_scene, :floor, :scale, {20, 1, 10})

      assert patched =~ "scale: {20, 1, 10}"
      # position unchanged
      assert patched =~ "position: {0, -1, 0}"
    end

    test "patches position on a multi-line node" do
      assert {:ok, patched} =
               SourcePatcher.patch_source(@sample_scene, :ball, :position, {5.0, 1.0, -3.0})

      assert patched =~ "position: {5.0, 1.0, -3.0}"
      # scale unchanged
      assert patched =~ "scale: {0.4, 0.4, 0.4}"
    end

    test "patches scale on a multi-line node" do
      assert {:ok, patched} =
               SourcePatcher.patch_source(@sample_scene, :ball, :scale, {1.0, 1.0, 1.0})

      assert patched =~ "scale: {1.0, 1.0, 1.0}"
      # position unchanged
      assert patched =~ "position: {0, 0.5, 0}"
    end

    test "only changes the targeted node" do
      assert {:ok, patched} =
               SourcePatcher.patch_source(@sample_scene, :paddle, :position, {18, 0.5, 0})

      # paddle changed
      assert patched =~ "position: {18, 0.5, 0}"
      refute patched =~ "position: {-18, 0.5, 0}"
      # ball untouched
      assert patched =~ "position: {0, 0.5, 0}"
      # floor untouched
      assert patched =~ "position: {0, -1, 0}"
    end

    test "returns error for unknown node name" do
      assert {:error, :node_not_found} =
               SourcePatcher.patch_source(@sample_scene, :nonexistent, :position, {0, 0, 0})
    end

    test "returns error for missing key on existing node" do
      assert {:error, :key_not_found} =
               SourcePatcher.patch_source(@sample_scene, :floor, :rotation, {0, 0, 0, 1})
    end

    test "returns error for unsupported key" do
      assert {:error, {:unsupported_key, :prefab}} =
               SourcePatcher.patch_node("/nonexistent", :floor, :prefab, "box")
    end

    test "rejects non-literal values (function calls)" do
      source = ~S'''
      defmodule MyGame.Scenes.Test do
        use Lunity.Scene

        scene do
          node(:thing, position: compute_pos(), scale: {1, 1, 1})
        end
      end
      '''

      assert {:error, :not_a_literal} =
               SourcePatcher.patch_source(source, :thing, :position, {0, 0, 0})
    end

    test "preserves surrounding formatting and comments" do
      source = ~S'''
      defmodule MyGame.Scenes.Test do
        use Lunity.Scene

        # The arena layout
        scene do
          node(:obj, prefab: "box", position: {0, 0, 0}, scale: {1, 1, 1})
        end
      end
      '''

      assert {:ok, patched} = SourcePatcher.patch_source(source, :obj, :position, {5, 5, 5})
      assert patched =~ "# The arena layout"
      assert patched =~ "position: {5, 5, 5}"
    end
  end

  describe "patch_node/4 with file I/O" do
    @tag :tmp_dir
    test "writes patched content back to file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "scene.ex")

      File.write!(path, ~S'''
      defmodule Test.Scene do
        use Lunity.Scene

        scene do
          node(:item, position: {0, 0, 0}, scale: {1, 1, 1})
        end
      end
      ''')

      assert :ok = SourcePatcher.patch_node(path, :item, :position, {10, 20, 30})

      content = File.read!(path)
      assert content =~ "position: {10, 20, 30}"
      assert content =~ "scale: {1, 1, 1}"
    end
  end

  describe "light nodes" do
    test "patches position on a light node" do
      source = ~S'''
      defmodule MyGame.Scenes.Test do
        use Lunity.Scene

        scene do
          light(:sun, type: :directional, position: {0, 10, 0})
        end
      end
      '''

      assert {:ok, patched} = SourcePatcher.patch_source(source, :sun, :position, {0, 20, 0})
      assert patched =~ "position: {0, 20, 0}"
    end
  end
end
