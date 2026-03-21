defmodule Lunity.Instance do
  @moduledoc """
  A running game instance.

  Each instance has a unique ID, its own ComponentStore, and manages the
  entities created for its scene. Entity IDs are simple names (`:ball`,
  `:left_paddle`) because store-level isolation replaces the old
  `{instance_id, name}` scoping.

  Instances are headless by default -- they own ECS state but have no
  rendering dependency. Viewers (editor, web, native) observe an
  instance by reading from its store.

  When an instance stops, its ComponentStore is shut down, dropping all
  ETS tables and component data.
  """

  use GenServer

  defstruct [:id, :scene_module, :entity_ids, :store_id, :status, :systems, :interval, :last_tick]

  alias Lunity.{ComponentStore, TickRunner}

  # -- Public API ----------------------------------------------------------------

  @doc """
  Starts a new game instance for the given scene module.

  Options:
  - `:id` - instance ID (default: auto-generated)
  - `:manager` - the Manager module to read components/systems/tick_rate from
  """
  def start(scene_module, opts \\ []) do
    id = Keyword.get(opts, :id, generate_id())

    DynamicSupervisor.start_child(
      Lunity.Instance.Supervisor,
      {__MODULE__, Keyword.merge(opts, id: id, scene_module: scene_module)}
    )
  end

  @doc "Stops a game instance and cleans up its store."
  def stop(instance_id) do
    case Registry.lookup(Lunity.Instance.Registry, instance_id) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Stops the instance and starts a fresh one with the same id and scene module.

  ECS state is recreated from the scene (same as a new `start/2`).
  Returns `:ok` or `{:error, reason}`.
  """
  def restart(instance_id) do
    case get(instance_id) do
      nil ->
        {:error, :not_found}

      %{scene_module: mod} ->
        case stop(instance_id) do
          :ok ->
            case start(mod, id: instance_id) do
              {:ok, _pid} -> :ok
              {:error, reason} -> {:error, reason}
            end

          {:error, :not_found} ->
            {:error, :not_found}
        end
    end
  end

  @doc "Lists all active instance IDs."
  def list do
    Registry.select(Lunity.Instance.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "Gets instance metadata."
  def get(instance_id) do
    case Registry.lookup(Lunity.Instance.Registry, instance_id) do
      [{pid, _}] ->
        try do
          GenServer.call(pid, :get, 15_000)
        catch
          :exit, _ -> nil
        end

      [] ->
        nil
    end
  end

  @doc "Pauses ticking for this instance."
  def pause(instance_id) do
    case Registry.lookup(Lunity.Instance.Registry, instance_id) do
      [{pid, _}] -> GenServer.call(pid, :pause)
      [] -> {:error, :not_found}
    end
  end

  @doc "Resumes ticking for this instance."
  def resume(instance_id) do
    case Registry.lookup(Lunity.Instance.Registry, instance_id) do
      [{pid, _}] -> GenServer.call(pid, :resume)
      [] -> {:error, :not_found}
    end
  end

  @doc "Steps one tick while paused."
  def step(instance_id) do
    case Registry.lookup(Lunity.Instance.Registry, instance_id) do
      [{pid, _}] -> GenServer.call(pid, :step)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Captures a snapshot of the instance's full ECS state.

  Returns a map that can be passed to `clone/2` or `Instance.start/2`
  with the `:snapshot` option to reproduce this exact state.
  """
  def snapshot(instance_id) do
    case Registry.lookup(Lunity.Instance.Registry, instance_id) do
      [{pid, _}] -> GenServer.call(pid, :snapshot, 30_000)
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Creates a new instance from a snapshot.

  Options:
  - `:id` - new instance ID (default: auto-generated)
  - `:manager` - manager module (inherited from snapshot if not given)
  - `:mutations` - `fn store_id -> ... end` called after restore, inside `with_store`,
    to tweak component values (e.g. re-seed RandomKey)

  Returns `{:ok, pid}` on success.
  """
  def clone(snap, opts \\ []) do
    id = Keyword.get(opts, :id, generate_id())
    scene_module = snap.scene_module

    merged_opts =
      Keyword.merge(opts,
        id: id,
        scene_module: scene_module,
        snapshot: snap,
        manager: Keyword.get(opts, :manager, snap[:manager])
      )

    DynamicSupervisor.start_child(
      Lunity.Instance.Supervisor,
      {__MODULE__, merged_opts}
    )
  end

  @doc """
  Runs ticks synchronously until `predicate` returns truthy or `max_ticks` is
  reached. The predicate is a zero-arity function executed inside `with_store`
  after each tick.

  Returns `{:halted, result, tick_count}` or `{:max_ticks, tick_count}`.
  """
  def run_until(instance_id, predicate, opts \\ []) do
    case Registry.lookup(Lunity.Instance.Registry, instance_id) do
      [{pid, _}] ->
        max = Keyword.get(opts, :max_ticks, 10_000)
        GenServer.call(pid, {:run_until, predicate, max}, :infinity)

      [] ->
        {:error, :not_found}
    end
  end

  @doc "Runs exactly `n` ticks synchronously. Sugar for `run_until` with no predicate."
  def run_ticks(instance_id, n) do
    run_until(instance_id, fn -> false end, max_ticks: n)
  end

  # -- GenServer callbacks -------------------------------------------------------

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    scene_module = Keyword.fetch!(opts, :scene_module)
    manager = Keyword.get(opts, :manager)
    snap = Keyword.get(opts, :snapshot)

    store_id = id
    {:ok, _pid} = ComponentStore.start_link(store_id, opts)

    {components, systems, tick_rate} = resolve_manager_config(manager)

    ComponentStore.with_store(store_id, fn ->
      Enum.each(components, &ComponentStore.register/1)
    end)

    {entity_ids, systems, interval} =
      if snap do
        ComponentStore.with_store(store_id, fn ->
          ComponentStore.restore(snap)
        end)

        if mutation = Keyword.get(opts, :mutations) do
          ComponentStore.with_store(store_id, fn -> mutation.(store_id) end)
        end

        {
          snap.entity_ids,
          snap.systems || systems,
          snap[:interval] || div(1000, tick_rate)
        }
      else
        eids =
          ComponentStore.with_store(store_id, fn ->
            init_scene_entities(scene_module)
          end)

        {eids, systems, div(1000, tick_rate)}
      end

    Process.send_after(self(), :tick, interval)

    {:ok,
     %__MODULE__{
       id: id,
       scene_module: scene_module,
       entity_ids: entity_ids,
       store_id: store_id,
       systems: systems,
       interval: interval,
       last_tick: System.monotonic_time(:millisecond),
       status: :running
     }}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    {:reply, :ok, %{state | status: :paused}}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    {:reply, :ok, %{state | status: :running}}
  end

  @impl true
  def handle_call(:step, _from, state) do
    {:reply, :ok, Map.put(%{state | status: :paused}, :step_pending, true)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snap =
      ComponentStore.with_store(state.store_id, fn ->
        ComponentStore.snapshot()
      end)

    snap =
      Map.merge(snap, %{
        scene_module: state.scene_module,
        entity_ids: state.entity_ids,
        systems: state.systems,
        interval: state.interval,
        manager: find_manager_module()
      })

    {:reply, snap, state}
  end

  @impl true
  def handle_call({:run_until, predicate, max_ticks}, _from, state) do
    {result, ticks_run, state} = do_run_until(state, predicate, max_ticks, 0)
    {:reply, Tuple.insert_at(result, tuple_size(result), ticks_run), %{state | status: :paused}}
  end

  @impl true
  def handle_info(:tick, state) do
    now = System.monotonic_time(:millisecond)
    dt_ms = now - state.last_tick
    dt_s = dt_ms / 1000.0

    ComponentStore.with_store(state.store_id, fn ->
      dt_tensor = ComponentStore.get_tensor(Lunity.Components.DeltaTime)

      if dt_tensor do
        ComponentStore.put_tensor(
          Lunity.Components.DeltaTime,
          Nx.broadcast(Nx.tensor(dt_s, type: :f32), Nx.shape(dt_tensor))
        )
      end

      cond do
        state.status == :running ->
          TickRunner.tick(state.systems)
          Lunity.Mod.GameInput.dispatch_tick(state.store_id, dt_s)

        state.status == :paused and Map.get(state, :step_pending, false) ->
          TickRunner.tick(state.systems)
          Lunity.Mod.GameInput.dispatch_tick(state.store_id, dt_s)

        true ->
          :ok
      end
    end)

    Process.send_after(self(), :tick, state.interval)
    state = %{state | last_tick: now}
    state = Map.delete(state, :step_pending)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    ComponentStore.stop(state.store_id)
    :ok
  end

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # -- Private -------------------------------------------------------------------

  defp via(id), do: {:via, Registry, {Lunity.Instance.Registry, id}}

  defp generate_id do
    counter = :persistent_term.get({__MODULE__, :id_counter}, 0) + 1
    :persistent_term.put({__MODULE__, :id_counter}, counter)
    String.pad_leading(Integer.to_string(counter), 4, "0")
  end

  @doc false
  def generate_id_external, do: generate_id()

  defp do_run_until(state, _predicate, max_ticks, count) when count >= max_ticks do
    {{:max_ticks}, count, state}
  end

  defp do_run_until(state, predicate, max_ticks, count) do
    ComponentStore.with_store(state.store_id, fn ->
      dt_tensor = ComponentStore.get_tensor(Lunity.Components.DeltaTime)

      dt_s =
        if dt_tensor do
          dt_s = state.interval / 1000.0

          ComponentStore.put_tensor(
            Lunity.Components.DeltaTime,
            Nx.broadcast(Nx.tensor(dt_s, type: :f32), Nx.shape(dt_tensor))
          )

          dt_s
        else
          state.interval / 1000.0
        end

      TickRunner.tick(state.systems)
      Lunity.Mod.GameInput.dispatch_tick(state.store_id, dt_s)
    end)

    new_count = count + 1

    result =
      ComponentStore.with_store(state.store_id, fn ->
        try do
          predicate.()
        rescue
          _ -> false
        end
      end)

    if result do
      {{:halted, result}, new_count, state}
    else
      do_run_until(state, predicate, max_ticks, new_count)
    end
  end

  defp resolve_manager_config(nil) do
    case find_manager_module() do
      nil ->
        {[], [], 20}

      mod ->
        components = [Lunity.Components.DeltaTime | mod.components()]
        systems = mod.systems()
        rate = if function_exported?(mod, :tick_rate, 0), do: mod.tick_rate(), else: 20
        {components, systems, rate}
    end
  end

  defp resolve_manager_config(manager_module) do
    components = [Lunity.Components.DeltaTime | manager_module.components()]
    systems = manager_module.systems()

    rate =
      if function_exported?(manager_module, :tick_rate, 0),
        do: manager_module.tick_rate(),
        else: 20

    {components, systems, rate}
  end

  defp find_manager_module do
    :code.all_loaded()
    |> Enum.find_value(fn {mod, _} ->
      if is_atom(mod) && function_exported?(mod, :__lunity_manager__, 0) do
        mod
      end
    end)
  end

  defp init_scene_entities(scene_module) do
    case Code.ensure_loaded(scene_module) do
      {:module, _} ->
        if function_exported?(scene_module, :__scene_def__, 0) do
          scene_def = scene_module.__scene_def__()
          init_entities_from_def(scene_def)
        else
          []
        end

      _ ->
        []
    end
  end

  defp init_entities_from_def(%Lunity.Scene.Def{nodes: nodes}) do
    Enum.flat_map(nodes, fn node_def ->
      init_entity_from_node(node_def)
    end)
  end

  defp init_entity_from_node(%Lunity.Scene.NodeDef{} = node_def) do
    entity_ids =
      if node_def.entity do
        entity_id = node_def.name
        _index = ComponentStore.allocate(entity_id)

        config = build_entity_config(node_def)

        try do
          node_def.entity.init(config, entity_id)
        rescue
          _ -> :ok
        end

        [entity_id]
      else
        []
      end

    child_ids =
      Enum.flat_map(node_def.children || [], fn child ->
        init_entity_from_node(child)
      end)

    entity_ids ++ child_ids
  end

  defp build_entity_config(%Lunity.Scene.NodeDef{} = node_def) do
    base = node_def.properties || %{}

    config =
      if node_def.entity && function_exported?(node_def.entity, :__property_spec__, 0) do
        try do
          result = Lunity.Entity.from_config(node_def.entity, base)
          if is_struct(result), do: Map.from_struct(result), else: result
        rescue
          _ -> base
        end
      else
        base
      end

    config =
      if node_def.position do
        Map.put(config, :position, node_def.position)
      else
        config
      end

    if node_def.scale do
      Map.put(config, :scale, node_def.scale)
    else
      config
    end
  end
end
