defmodule Lunity.PrefabLoaderTest do
  use ExUnit.Case, async: true

  alias EAGL.{Node, Scene}
  alias Lunity.PrefabLoader

  describe "load_prefab/2" do
    test "rejects path traversal in id" do
      assert {:error, :path_traversal} = PrefabLoader.load_prefab("..")
      assert {:error, :path_traversal} = PrefabLoader.load_prefab("../etc/passwd")
      assert {:error, :path_traversal} = PrefabLoader.load_prefab("crate/../../secret")
    end

    test "rejects absolute path" do
      assert {:error, :path_traversal} = PrefabLoader.load_prefab("/etc/passwd")
    end

    test "returns file_not_found for nonexistent prefab" do
      # Fails before GL context needed (no shader creation)
      assert {:error, :file_not_found} = PrefabLoader.load_prefab("nonexistent_prefab_xyz")
    end
  end

  describe "instantiate_prefab_from_loaded/4" do
    test "clones scene roots and attaches to parent" do
      # Create a minimal scene with one root node
      root = Node.new(name: "crate_root", position: {1.0, 2.0, 3.0})
      scene = %Scene{root_nodes: [root], name: nil}
      config = %{health: 100, durability: 50}
      parent = Node.new(name: "parent")

      {:ok, updated_parent, merged_config} =
        PrefabLoader.instantiate_prefab_from_loaded(scene, config, parent, %{})

      assert length(updated_parent.children) == 1
      [cloned] = updated_parent.children
      assert cloned.name == "crate_root"
      assert cloned.position == {1.0, 2.0, 3.0}
      assert cloned.parent != nil
      assert merged_config.health == 100
      assert merged_config.durability == 50
    end

    test "merges overrides into config" do
      scene = %Scene{root_nodes: [Node.new(name: "root")], name: nil}
      config = %{health: 100, durability: 50}
      parent = Node.new(name: "parent")

      {:ok, _parent, merged} =
        PrefabLoader.instantiate_prefab_from_loaded(scene, config, parent, %{
          "health" => 75,
          "extra" => "value"
        })

      assert merged.health == 75
      assert merged.durability == 50
      assert merged.extra == "value"
    end

    test "clones hierarchy with children" do
      child = Node.new(name: "child", position: {0.5, 0.5, 0.5})
      root = Node.new(name: "root") |> Node.add_child(child)
      scene = %Scene{root_nodes: [root], name: nil}
      parent = Node.new(name: "parent")

      {:ok, updated_parent, _} =
        PrefabLoader.instantiate_prefab_from_loaded(scene, %{}, parent, nil)

      assert length(updated_parent.children) == 1
      [cloned_root] = updated_parent.children
      assert cloned_root.name == "root"
      assert length(cloned_root.children) == 1
      [cloned_child] = cloned_root.children
      assert cloned_child.name == "child"
      assert cloned_child.parent != nil
    end

    test "handles multiple root nodes" do
      root1 = Node.new(name: "root1")
      root2 = Node.new(name: "root2")
      scene = %Scene{root_nodes: [root1, root2], name: nil}
      parent = Node.new(name: "parent")

      {:ok, updated_parent, _} =
        PrefabLoader.instantiate_prefab_from_loaded(scene, %{}, parent, %{})

      assert length(updated_parent.children) == 2
      names = Enum.map(updated_parent.children, & &1.name) |> Enum.sort()
      assert names == ["root1", "root2"]
    end
  end
end
