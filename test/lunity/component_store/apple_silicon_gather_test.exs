defmodule Lunity.ComponentStore.AppleSiliconGatherTest do
  use Lunity.AppleSiliconCase, async: false

  alias Lunity.ComponentStore
  alias Lunity.ComponentStore.Gather
  alias Lunity.Nx.Host

  defmodule Position do
    use Lunity.Component, storage: :tensor, shape: {3}, dtype: :f32
  end

  defmodule Velocity do
    use Lunity.Component, storage: :tensor, shape: {3}, dtype: :f32
  end

  setup %{choice: choice} do
    store_id = "apple_silicon_gather_#{:erlang.unique_integer([:positive])}"

    unless Process.whereis(Lunity.ComponentStore.Registry) do
      Registry.start_link(keys: :unique, name: Lunity.ComponentStore.Registry)
    end

    {:ok, _pid} = ComponentStore.start_link(store_id, capacity: 16)

    ComponentStore.with_store(store_id, fn ->
      ComponentStore.register(Position)
      ComponentStore.register(Velocity)
    end)

    on_exit(fn ->
      try do
        ComponentStore.stop(store_id)
      catch
        :exit, _ -> :ok
      end
    end)

    {:ok, store_id: store_id, choice: choice}
  end

  test "active_index_set keeps index tensors on the MLX backend", %{store_id: sid} do
    populate(sid)

    set =
      ComponentStore.with_store(sid, fn ->
        Gather.active_index_set(Velocity)
      end)

    assert set.count == 2
    assert mlx_tensor?(set.indices)
    assert mlx_tensor?(set.put_indices)

    assert Host.to_list(set.indices) |> Enum.sort() ==
             [
               ComponentStore.index_of(:paddle, sid),
               ComponentStore.index_of(:ball, sid)
             ]
             |> Enum.sort()
  end

  test "gather/scatter round-trip on device tensors", %{store_id: sid} do
    populate(sid)

    {paddle, ball, floor_after, floor_before} =
      ComponentStore.with_store(sid, fn ->
        index_set = Gather.active_index_set(Velocity)

        inputs = %{
          position: ComponentStore.get_tensor(Position),
          velocity: ComponentStore.get_tensor(Velocity)
        }

        assert mlx_tensor?(inputs.position)
        assert mlx_tensor?(inputs.velocity)

        compact = Gather.gather(inputs, index_set)
        assert Nx.shape(compact.position) == {2, 3}
        assert mlx_tensor?(compact.position)

        new_vel = Nx.broadcast(Host.from_host(1.0, type: :f32), {2, 3})
        scattered = Gather.scatter(inputs, %{velocity: new_vel}, index_set)

        paddle_idx = ComponentStore.index_of(:paddle)
        ball_idx = ComponentStore.index_of(:ball)
        floor_idx = ComponentStore.index_of(:floor)

        {
          Host.to_list(scattered.velocity[paddle_idx]),
          Host.to_list(scattered.velocity[ball_idx]),
          Host.to_list(scattered.velocity[floor_idx]),
          Host.to_list(inputs.velocity[floor_idx])
        }
      end)

    assert paddle == [1.0, 1.0, 1.0]
    assert ball == [1.0, 1.0, 1.0]
    assert floor_after == floor_before
  end

  defp populate(store_id) do
    ComponentStore.with_store(store_id, fn ->
      ComponentStore.allocate(:floor)
      Position.put(:floor, {0.0, -0.5, 0.0})

      ComponentStore.allocate(:paddle)
      Position.put(:paddle, {-14.0, 1.5, 0.0})
      Velocity.put(:paddle, {0.0, 0.0, 0.0})

      ComponentStore.allocate(:ball)
      Position.put(:ball, {0.0, 1.5, 0.0})
      Velocity.put(:ball, {10.0, 0.0, -7.0})
    end)
  end

  defp mlx_tensor?(%Nx.Tensor{data: %struct{}}) do
    struct in [Emily.Backend, EMLX.Backend]
  end
end
