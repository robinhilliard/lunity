defmodule Lunity.Mod.DataStageTest do
  use ExUnit.Case, async: true

  alias Lunity.Mod
  alias Lunity.Mod.DataStage
  alias Lunity.Scene.{Def, NodeDef}

  @mods_dir Path.join([__DIR__, "..", "..", "support", "mods"]) |> Path.expand()

  describe "run/1" do
    test "loads scenes from data.lua" do
      {:ok, mods} = Mod.discover_and_sort(@mods_dir)
      {:ok, data} = DataStage.run(mods)

      assert %Def{nodes: nodes} = data.scenes["test_scene"]
      assert length(nodes) >= 2

      box1 = Enum.find(nodes, &(&1.name == :box1))
      assert %NodeDef{} = box1
      assert box1.prefab == "box"
      assert box1.position == {1.0, 2.0, 3.0}
      assert box1.scale == {1.0, 1.0, 1.0}
    end

    test "loads prefabs from data.lua" do
      {:ok, mods} = Mod.discover_and_sort(@mods_dir)
      {:ok, data} = DataStage.run(mods)

      assert %{name: "box", glb: "box"} = data.prefabs["box"]
    end

    test "loads entities from data.lua" do
      {:ok, mods} = Mod.discover_and_sort(@mods_dir)
      {:ok, data} = DataStage.run(mods)

      assert %{name: "player", components: ["health", "movement"]} = data.entities["player"]
    end

    test "data-updates.lua patches existing data" do
      {:ok, mods} = Mod.discover_and_sort(@mods_dir)
      {:ok, data} = DataStage.run(mods)

      player = data.entities["player"]
      assert player.properties["speed"]["default"] == 10.0

      scene = data.scenes["test_scene"]
      powerup = Enum.find(scene.nodes, &(&1.name == :powerup))
      assert %NodeDef{} = powerup
      assert powerup.position == {7.0, 8.0, 9.0}
    end
  end
end
