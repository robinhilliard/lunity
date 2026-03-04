defmodule Lunity.MCP.HierarchyTest do
  use ExUnit.Case, async: true

  alias EAGL.{Node, Scene}
  alias Lunity.MCP.Hierarchy

  test "from_scene returns hierarchy with name, properties, children" do
    child = Node.new(name: "Child", properties: %{"key" => "value"})
    root = Node.new(name: "Root") |> Node.add_child(child)
    scene = Scene.new() |> Scene.add_root_node(root)

    hierarchy = Hierarchy.from_scene(scene)

    assert [root_map] = hierarchy
    assert root_map["name"] == "Root"
    assert root_map["properties"] == %{}
    assert [child_map] = root_map["children"]
    assert child_map["name"] == "Child"
    assert child_map["properties"] == %{"key" => "value"}
    assert child_map["children"] == []
  end

  test "from_scene handles empty scene" do
    scene = Scene.new()
    assert Hierarchy.from_scene(scene) == []
  end
end
