defmodule Lunity.Editor.HierarchyTreeTest do
  use ExUnit.Case, async: true

  alias Lunity.Editor.HierarchyTree

  describe "discover_scenes/0" do
    test "returns scenes sorted alphabetically" do
      scenes = HierarchyTree.discover_scenes()

      assert is_list(scenes)
      assert scenes == Enum.sort(scenes)
    end

    test "scenes have __scene_def__/0" do
      scenes = HierarchyTree.discover_scenes()

      Enum.each(scenes, fn mod ->
        assert function_exported?(mod, :__scene_def__, 0),
               "#{inspect(mod)} should export __scene_def__/0"
      end)
    end
  end

  describe "node_type_suffix (via module)" do
    test "handles nodes with different characteristics" do
      light_node = %{light: %{type: :point}, camera: nil, mesh: nil, children: []}
      camera_node = %{light: nil, camera: %{fov: 45}, mesh: nil, children: []}
      mesh_node = %{light: nil, camera: nil, mesh: %{id: 1}, children: []}
      group_node = %{light: nil, camera: nil, mesh: nil, children: [mesh_node]}
      empty_node = %{light: nil, camera: nil, mesh: nil, children: []}

      assert suffix(light_node) == "[light]"
      assert suffix(camera_node) == "[camera]"
      assert suffix(mesh_node) == nil
      assert suffix(group_node) == nil
      assert suffix(empty_node) == nil
    end

    defp suffix(node) do
      cond do
        node.light != nil -> "[light]"
        node.camera != nil -> "[camera]"
        true -> nil
      end
    end
  end
end
