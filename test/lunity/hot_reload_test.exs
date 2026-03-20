defmodule Lunity.HotReloadTest do
  @moduledoc """
  Tests that code hot-reload works for running game instances.

  When a system module is recompiled (e.g. via FileWatcher on save), the BEAM
  loads the new code. On the next tick, the instance uses the updated system
  without needing a scene reload or instance restart.
  """
  use ExUnit.Case, async: false

  @instance_id "hot_reload_test"

  alias Lunity.{ComponentStore, Instance}
  alias Lunity.Components.Position

  setup do
    on_exit(fn ->
      if @instance_id in Instance.list(), do: Instance.stop(@instance_id)
    end)
    :ok
  end

  @system_v1 """
  defmodule Lunity.HotReloadTest.System do
    use Lunity.System, type: :tensor
    alias Lunity.Components.Position
    alias Lunity.Components.DeltaTime

    @spec run(%{position: Position.t(), delta_time: DeltaTime.t()}) :: %{position: Position.t()}
    defn run(%{position: pos, delta_time: _dt}) do
      add = Nx.tensor([0.1, 0.0, 0.0], type: :f32)
      %{position: Nx.add(pos, Nx.broadcast(add, Nx.shape(pos)))}
    end
  end
  """

  @system_v2 """
  defmodule Lunity.HotReloadTest.System do
    use Lunity.System, type: :tensor
    alias Lunity.Components.Position
    alias Lunity.Components.DeltaTime

    @spec run(%{position: Position.t(), delta_time: DeltaTime.t()}) :: %{position: Position.t()}
    defn run(%{position: pos, delta_time: _dt}) do
      add = Nx.tensor([0.5, 0.0, 0.0], type: :f32)
      %{position: Nx.add(pos, Nx.broadcast(add, Nx.shape(pos)))}
    end
  end
  """

  test "instance picks up recompiled system code on subsequent ticks" do
    # Compile system v1 (adds 0.1 to x per tick)
    [{_mod, _bin}] = Code.compile_string(@system_v1, "hot_reload_system.ex")

    # Start instance with our test scene and manager
    {:ok, _pid} = Instance.start(Lunity.HotReloadTest.Scene, id: @instance_id, manager: Lunity.HotReloadTest.Manager)
    store_id = Instance.get(@instance_id).store_id

    # Run 5 ticks with v1: position should go from 0 to 0.5 on x
    {:max_ticks, 5} = Instance.run_ticks(@instance_id, 5)

    pos_after_v1 =
      ComponentStore.with_store(store_id, fn ->
        Position.get(:marker)
      end)

    assert {x1, _y, _z} = pos_after_v1
    assert_in_delta x1, 0.5, 0.01

    # Recompile system v2 (adds 0.5 to x per tick) - simulates hot reload on save
    [{_mod, _bin}] = Code.compile_string(@system_v2, "hot_reload_system.ex")

    # Run 5 more ticks with v2: position should increase by 2.5 more on x
    {:max_ticks, 5} = Instance.run_ticks(@instance_id, 5)

    pos_after_v2 =
      ComponentStore.with_store(store_id, fn ->
        Position.get(:marker)
      end)

    assert {x2, _y, _z} = pos_after_v2
    # 0.5 (after v1) + 5 * 0.5 (v2) = 3.0
    assert_in_delta x2, 3.0, 0.01

    Instance.stop(@instance_id)
  end

  test "paused instance uses new system code after resume" do
    [{_mod, _bin}] = Code.compile_string(@system_v1, "hot_reload_system.ex")

    {:ok, _pid} = Instance.start(Lunity.HotReloadTest.Scene, id: @instance_id, manager: Lunity.HotReloadTest.Manager)
    store_id = Instance.get(@instance_id).store_id

    # Run 3 ticks, then pause
    {:max_ticks, 3} = Instance.run_ticks(@instance_id, 3)
    :ok = Instance.pause(@instance_id)

    # While paused: recompile to v2
    [{_mod, _bin}] = Code.compile_string(@system_v2, "hot_reload_system.ex")

    # Resume and run 3 more ticks - should use v2 (0.5 per tick)
    :ok = Instance.resume(@instance_id)
    {:max_ticks, 3} = Instance.run_ticks(@instance_id, 3)

    pos_final =
      ComponentStore.with_store(store_id, fn ->
        Position.get(:marker)
      end)

    assert {x, _y, _z} = pos_final
    # 3 * 0.1 (v1) + 3 * 0.5 (v2) = 0.3 + 1.5 = 1.8
    assert_in_delta x, 1.8, 0.01

    Instance.stop(@instance_id)
  end
end
