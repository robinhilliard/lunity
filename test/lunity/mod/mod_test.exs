defmodule Lunity.ModTest do
  use ExUnit.Case, async: true

  alias Lunity.Mod

  @mods_dir Path.join([__DIR__, "..", "..", "support", "mods"]) |> Path.expand()

  describe "discover/1" do
    test "discovers mods in a directory" do
      {:ok, mods} = Mod.discover(@mods_dir)
      names = Enum.map(mods, & &1.name)
      assert "test_mod" in names
      assert "dep_mod" in names
    end

    test "returns empty list for nonexistent directory" do
      {:ok, mods} = Mod.discover("/nonexistent/dir")
      assert mods == []
    end

    test "parses mod metadata correctly" do
      {:ok, mods} = Mod.discover(@mods_dir)
      test_mod = Enum.find(mods, &(&1.name == "test_mod"))
      assert test_mod.version == "1.0.0"
      assert test_mod.title == "Test Mod"
      assert test_mod.dependencies == []
    end

    test "parses dependencies" do
      {:ok, mods} = Mod.discover(@mods_dir)
      dep_mod = Enum.find(mods, &(&1.name == "dep_mod"))
      assert dep_mod.dependencies == ["test_mod"]
    end
  end

  describe "topological_sort/1" do
    test "sorts mods in dependency order" do
      {:ok, mods} = Mod.discover(@mods_dir)
      {:ok, sorted} = Mod.topological_sort(mods)
      names = Enum.map(sorted, & &1.name)
      test_idx = Enum.find_index(names, &(&1 == "test_mod"))
      dep_idx = Enum.find_index(names, &(&1 == "dep_mod"))
      assert test_idx < dep_idx
    end

    test "detects missing dependencies" do
      mods = [
        %{
          name: "orphan",
          version: "1.0.0",
          title: "Orphan",
          dependencies: ["nonexistent"],
          dir: "/tmp"
        }
      ]

      assert {:error, {:missing_dependency, "nonexistent", "orphan"}} = Mod.topological_sort(mods)
    end

    test "detects circular dependencies" do
      mods = [
        %{name: "a", version: "1.0.0", title: "A", dependencies: ["b"], dir: "/tmp"},
        %{name: "b", version: "1.0.0", title: "B", dependencies: ["a"], dir: "/tmp"}
      ]

      assert {:error, {:dependency_cycle, _}} = Mod.topological_sort(mods)
    end
  end

  describe "discover_and_sort/1" do
    test "discovers and sorts in one call" do
      {:ok, sorted} = Mod.discover_and_sort(@mods_dir)
      names = Enum.map(sorted, & &1.name)
      assert "test_mod" in names
      assert "dep_mod" in names
      test_idx = Enum.find_index(names, &(&1 == "test_mod"))
      dep_idx = Enum.find_index(names, &(&1 == "dep_mod"))
      assert test_idx < dep_idx
    end
  end
end
