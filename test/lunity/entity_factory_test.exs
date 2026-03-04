defmodule Lunity.EntityFactoryTest do
  use ExUnit.Case, async: false

  alias Lunity.EntityFactory
  alias Lunity.Test.Support.MockComponent

  setup do
    Process.put(:entity_factory_adds, [])
    :ok
  end

  describe "create_from_config/3" do
    test "creates entity from config returning component struct list" do
      assert {:ok, entity_id} = EntityFactory.create_from_config("entity_factory_test")
      assert is_integer(entity_id) or is_bitstring(entity_id)

      adds = Process.get(:entity_factory_adds, [])
      assert length(adds) == 1
      [{id, struct}] = adds
      assert id == entity_id
      assert struct.__struct__ == MockComponent
      assert struct.value == 100
    end

    test "merges list overrides by struct type" do
      assert {:ok, entity_id} =
               EntityFactory.create_from_config("entity_factory_test", [
                 %MockComponent{value: 80}
               ])

      adds = Process.get(:entity_factory_adds, [])
      assert length(adds) == 1
      [{^entity_id, struct}] = adds
      assert struct.value == 80
    end

    test "merges map overrides into struct fields" do
      assert {:ok, _entity_id} =
               EntityFactory.create_from_config("entity_factory_test", %{value: 50})

      adds = Process.get(:entity_factory_adds, [])
      assert length(adds) == 1
      [{_, struct}] = adds
      assert struct.value == 50
    end

    test "returns error for nonexistent path" do
      assert {:error, :file_not_found} =
               EntityFactory.create_from_config("nonexistent/entity_config")
    end

    test "rejects path traversal" do
      assert {:error, :path_traversal} =
               EntityFactory.create_from_config("../etc/passwd")
    end
  end
end
