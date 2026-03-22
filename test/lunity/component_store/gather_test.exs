defmodule Lunity.ComponentStore.GatherTest do
  use ExUnit.Case, async: false

  alias Lunity.ComponentStore
  alias Lunity.ComponentStore.Gather

  defmodule Position do
    use Lunity.Component, storage: :tensor, shape: {3}, dtype: :f32
  end

  defmodule Velocity do
    use Lunity.Component, storage: :tensor, shape: {3}, dtype: :f32
  end

  defmodule Speed do
    use Lunity.Component, storage: :tensor, shape: {}, dtype: :f32
  end

  defmodule Health do
    use Lunity.Component, storage: :tensor, shape: {}, dtype: :f32
  end

  setup do
    store_id = "gather_test_#{:erlang.unique_integer([:positive])}"

    unless Process.whereis(Lunity.ComponentStore.Registry) do
      Registry.start_link(keys: :unique, name: Lunity.ComponentStore.Registry)
    end

    {:ok, _pid} = ComponentStore.start_link(store_id, capacity: 16)

    ComponentStore.with_store(store_id, fn ->
      ComponentStore.register(Position)
      ComponentStore.register(Velocity)
      ComponentStore.register(Speed)
      ComponentStore.register(Health)
    end)

    on_exit(fn ->
      try do
        ComponentStore.stop(store_id)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, store_id: store_id}
  end

  defp populate_entities(store_id) do
    ComponentStore.with_store(store_id, fn ->
      ComponentStore.allocate(:floor)
      Position.put(:floor, {0.0, -0.5, 0.0})

      ComponentStore.allocate(:paddle)
      Position.put(:paddle, {-14.0, 1.5, 0.0})
      Velocity.put(:paddle, {0.0, 0.0, 0.0})
      Speed.put(:paddle, 8.0)

      ComponentStore.allocate(:ball)
      Position.put(:ball, {0.0, 1.5, 0.0})
      Velocity.put(:ball, {10.0, 0.0, -7.0})
      Speed.put(:ball, 10.0)
    end)
  end

  describe "active_indices/2" do
    test "returns indices where presence is set for a single component", %{store_id: sid} do
      populate_entities(sid)

      indices =
        ComponentStore.with_store(sid, fn ->
          Gather.active_indices(Velocity)
        end)

      assert length(indices) == 2
      assert Enum.sort(indices) == Enum.sort(indices)

      paddle_idx = ComponentStore.index_of(:paddle, sid)
      ball_idx = ComponentStore.index_of(:ball, sid)
      assert paddle_idx in indices
      assert ball_idx in indices
      refute ComponentStore.index_of(:floor, sid) in indices
    end

    test "ANDs presence masks for multiple components", %{store_id: sid} do
      ComponentStore.with_store(sid, fn ->
        ComponentStore.allocate(:a)
        Position.put(:a, {1, 0, 0})
        Velocity.put(:a, {1, 0, 0})
        Health.put(:a, 100.0)

        ComponentStore.allocate(:b)
        Position.put(:b, {2, 0, 0})
        Health.put(:b, 50.0)

        ComponentStore.allocate(:c)
        Position.put(:c, {3, 0, 0})
        Velocity.put(:c, {2, 0, 0})
      end)

      both =
        ComponentStore.with_store(sid, fn ->
          Gather.active_indices([Velocity, Health])
        end)

      a_idx = ComponentStore.index_of(:a, sid)
      assert both == [a_idx]
    end

    test "returns empty list when no entities have presence", %{store_id: sid} do
      indices =
        ComponentStore.with_store(sid, fn ->
          Gather.active_indices(Velocity)
        end)

      assert indices == []
    end

    test "caches results across calls", %{store_id: sid} do
      populate_entities(sid)

      result1 =
        ComponentStore.with_store(sid, fn ->
          Gather.active_indices(Velocity)
        end)

      result2 =
        ComponentStore.with_store(sid, fn ->
          Gather.active_indices(Velocity)
        end)

      assert result1 == result2
    end

    test "cache is invalidated when entity is allocated", %{store_id: sid} do
      populate_entities(sid)

      initial =
        ComponentStore.with_store(sid, fn ->
          Gather.active_indices(Velocity)
        end)

      ComponentStore.with_store(sid, fn ->
        ComponentStore.allocate(:new_entity)
        Velocity.put(:new_entity, {5.0, 0.0, 0.0})
      end)

      updated =
        ComponentStore.with_store(sid, fn ->
          Gather.active_indices(Velocity)
        end)

      assert length(updated) == length(initial) + 1
    end

    test "cache is invalidated when entity is deallocated", %{store_id: sid} do
      populate_entities(sid)

      ComponentStore.with_store(sid, fn ->
        Gather.active_indices(Velocity)
      end)

      tensor_table = :"lunity_tensors_#{sid}"
      cached_before = :ets.match(tensor_table, {{:_, :cached_indices}, :_})
      assert length(cached_before) > 0

      ComponentStore.deallocate(:ball, sid)

      cached_after = :ets.match(tensor_table, {{:_, :cached_indices}, :_})
      assert cached_after == []
    end
  end

  describe "gather/2" do
    test "compacts tensor values to only the given indices", %{store_id: sid} do
      populate_entities(sid)

      result =
        ComponentStore.with_store(sid, fn ->
          indices = Gather.active_indices(Velocity)

          inputs = %{
            position: ComponentStore.get_tensor(Position),
            velocity: ComponentStore.get_tensor(Velocity)
          }

          Gather.gather(inputs, indices)
        end)

      assert Nx.shape(result.position) == {2, 3}
      assert Nx.shape(result.velocity) == {2, 3}
    end

    test "passes through scalar (non-gatherable) values", %{store_id: sid} do
      populate_entities(sid)

      result =
        ComponentStore.with_store(sid, fn ->
          indices = Gather.active_indices(Velocity)
          ball_idx = Nx.tensor(2, type: :s32)

          inputs = %{
            position: ComponentStore.get_tensor(Position),
            ball_idx: ball_idx
          }

          Gather.gather(inputs, indices)
        end)

      assert Nx.shape(result.ball_idx) == {}
    end

    test "preserves data values at gathered rows", %{store_id: sid} do
      populate_entities(sid)

      result =
        ComponentStore.with_store(sid, fn ->
          paddle_idx = ComponentStore.index_of(:paddle)
          ball_idx = ComponentStore.index_of(:ball)
          indices = Enum.sort([paddle_idx, ball_idx])

          inputs = %{
            speed: ComponentStore.get_tensor(Speed)
          }

          compact = Gather.gather(inputs, indices)
          Nx.to_flat_list(compact.speed)
        end)

      assert Enum.sort(result) == Enum.sort([8.0, 10.0])
    end
  end

  describe "scatter/3" do
    test "writes compact rows back into full tensors at correct indices", %{store_id: sid} do
      populate_entities(sid)

      result =
        ComponentStore.with_store(sid, fn ->
          paddle_idx = ComponentStore.index_of(:paddle)
          ball_idx = ComponentStore.index_of(:ball)
          indices = Enum.sort([paddle_idx, ball_idx])

          full_inputs = %{
            position: ComponentStore.get_tensor(Position)
          }

          new_positions = Nx.tensor([[1.0, 2.0, 3.0], [4.0, 5.0, 6.0]], type: :f32)
          compact_outputs = %{position: new_positions}

          scattered = Gather.scatter(full_inputs, compact_outputs, indices)

          first_idx = Enum.at(indices, 0)
          second_idx = Enum.at(indices, 1)

          {
            Nx.to_flat_list(scattered.position[first_idx]),
            Nx.to_flat_list(scattered.position[second_idx])
          }
        end)

      {first, second} = result
      assert first == [1.0, 2.0, 3.0]
      assert second == [4.0, 5.0, 6.0]
    end

    test "leaves non-scattered rows unchanged", %{store_id: sid} do
      populate_entities(sid)

      result =
        ComponentStore.with_store(sid, fn ->
          floor_idx = ComponentStore.index_of(:floor)
          ball_idx = ComponentStore.index_of(:ball)

          full_inputs = %{
            position: ComponentStore.get_tensor(Position)
          }

          original_floor = Nx.to_flat_list(full_inputs.position[floor_idx])

          compact_outputs = %{
            position: Nx.tensor([[99.0, 99.0, 99.0]], type: :f32)
          }

          scattered = Gather.scatter(full_inputs, compact_outputs, [ball_idx])

          {original_floor, Nx.to_flat_list(scattered.position[floor_idx])}
        end)

      {original, after_scatter} = result
      assert original == after_scatter
    end

    test "only scatters keys present in compact_outputs", %{store_id: sid} do
      populate_entities(sid)

      result =
        ComponentStore.with_store(sid, fn ->
          indices = Gather.active_indices(Velocity)

          full_inputs = %{
            position: ComponentStore.get_tensor(Position),
            velocity: ComponentStore.get_tensor(Velocity)
          }

          compact_outputs = %{
            position: Nx.broadcast(Nx.tensor(0.0, type: :f32), {length(indices), 3})
          }

          scattered = Gather.scatter(full_inputs, compact_outputs, indices)
          Map.keys(scattered)
        end)

      assert result == [:position]
    end
  end

  describe "invalidate_cache/1" do
    test "clears cached indices", %{store_id: sid} do
      populate_entities(sid)

      ComponentStore.with_store(sid, fn ->
        _first = Gather.active_indices(Velocity)
      end)

      Gather.invalidate_cache(sid)

      tensor_table = :"lunity_tensors_#{sid}"
      cached = :ets.match(tensor_table, {{:_, :cached_indices}, :_})
      assert cached == []
    end
  end
end
