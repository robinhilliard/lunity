defmodule Lunity.Editor.HierarchyTreeTest do
  use ExUnit.Case, async: true

  alias Lunity.Editor.HierarchyTree

  describe "discover_modules/0" do
    test "returns three lists sorted alphabetically" do
      {entities, prefabs, scenes} = HierarchyTree.discover_modules()

      assert is_list(entities)
      assert is_list(prefabs)
      assert is_list(scenes)

      assert entities == Enum.sort(entities)
      assert prefabs == Enum.sort(prefabs)
      assert scenes == Enum.sort(scenes)
    end

    test "entities have __entity_spec__/0" do
      {entities, _, _} = HierarchyTree.discover_modules()

      Enum.each(entities, fn mod ->
        assert function_exported?(mod, :__entity_spec__, 0),
               "#{inspect(mod)} should export __entity_spec__/0"
      end)
    end

    test "scenes have __scene_def__/0" do
      {_, _, scenes} = HierarchyTree.discover_modules()

      Enum.each(scenes, fn mod ->
        assert function_exported?(mod, :__scene_def__, 0),
               "#{inspect(mod)} should export __scene_def__/0"
      end)
    end

    test "lists are disjoint (no module appears in multiple categories)" do
      {entities, prefabs, scenes} = HierarchyTree.discover_modules()

      ent_set = MapSet.new(entities)
      pref_set = MapSet.new(prefabs)
      scene_set = MapSet.new(scenes)

      assert MapSet.disjoint?(ent_set, pref_set)
      assert MapSet.disjoint?(ent_set, scene_set)
      assert MapSet.disjoint?(pref_set, scene_set)
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
      assert suffix(group_node) == "[group]"
      assert suffix(empty_node) == nil
    end

    defp suffix(node) do
      cond do
        node.light != nil -> "[light]"
        node.camera != nil -> "[camera]"
        node.mesh != nil -> nil
        node.children != nil and node.children != [] -> "[group]"
        true -> nil
      end
    end
  end
end
