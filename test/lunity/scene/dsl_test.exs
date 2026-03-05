defmodule Lunity.Scene.DSLTest do
  use ExUnit.Case, async: true

  import Lunity.Scene.DSL
  alias Lunity.Scene.{Def, NodeDef}

  describe "scene/1" do
    test "returns a Scene.Def with nodes" do
      result =
        scene do
          node(:floor, prefab: "box", position: {0, 0, -1}, scale: {12, 6, 0.3})
          node(:ball, prefab: "box", position: {0, 0, 0.5}, scale: {0.4, 0.4, 0.4})
        end

      assert %Def{nodes: nodes} = result
      assert length(nodes) == 2
    end

    test "single node scene" do
      result =
        scene do
          node(:only, prefab: "box")
        end

      assert %Def{nodes: [%NodeDef{name: :only, prefab: "box"}]} = result
    end
  end

  describe "node/2" do
    test "creates a NodeDef with all options" do
      n =
        node(:paddle,
          prefab: "box",
          entity: SomeModule,
          config: "paddles/default",
          position: {1, 2, 3},
          scale: {4, 5, 6},
          properties: %{side: :left}
        )

      assert %NodeDef{} = n
      assert n.name == :paddle
      assert n.prefab == "box"
      assert n.entity == SomeModule
      assert n.config == "paddles/default"
      assert n.position == {1, 2, 3}
      assert n.scale == {4, 5, 6}
      assert n.properties == %{side: :left}
    end

    test "accepts list format for position and scale" do
      n = node(:item, position: [1, 2, 3], scale: [4, 5, 6])

      assert n.position == {1, 2, 3}
      assert n.scale == {4, 5, 6}
    end

    test "position and scale default to nil" do
      n = node(:empty, prefab: "box")

      assert n.position == nil
      assert n.scale == nil
    end

    test "accepts rotation as quaternion tuple" do
      n = node(:rotated, rotation: {0.0, 0.0, 0.707, 0.707})

      assert n.rotation == {0.0, 0.0, 0.707, 0.707}
    end

    test "accepts rotation as quaternion list" do
      n = node(:rotated, rotation: [0.0, 0.0, 0.707, 0.707])

      assert n.rotation == {0.0, 0.0, 0.707, 0.707}
    end

    test "raises on invalid position" do
      assert_raise ArgumentError, ~r/position must be/, fn ->
        node(:bad, position: {1, 2})
      end
    end

    test "raises on invalid scale" do
      assert_raise ArgumentError, ~r/scale must be/, fn ->
        node(:bad, scale: "big")
      end
    end

    test "children default to empty list" do
      n = node(:parent, prefab: "box")
      assert n.children == []
    end
  end

  describe "scene evaluated from .exs-style code" do
    test "Code.eval_string works with the DSL" do
      code = """
      import Lunity.Scene.DSL

      scene do
        node :test_node, prefab: "box", position: {1, 2, 3}
      end
      """

      {result, _bindings} = Code.eval_string(code)

      assert %Def{nodes: [%NodeDef{name: :test_node, prefab: "box", position: {1, 2, 3}}]} =
               result
    end
  end
end
