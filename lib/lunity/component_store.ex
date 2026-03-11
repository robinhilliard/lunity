defmodule Lunity.ComponentStore do
  @moduledoc """
  Manages component storage for the Lunity ECS.

  Each game instance gets its own ComponentStore with isolated ETS tables.
  The current store is resolved via the process dictionary, allowing
  game code (entity init, systems) to use the same API regardless of
  which instance is active.

  ## Store context

  Set the active store before accessing components:

      ComponentStore.with_store("pong_1", fn ->
        Position.put(:ball, {0, 0, 0})
      end)

  The `with_store/2` helper manages the process dictionary automatically.
  Systems and entity init code don't need to know about stores -- the
  Instance GenServer sets the context before ticking.

  ## Tensor storage

  Each tensor component gets a row per entity, indexed by integer position.
  Nx tensors stored in ETS copy only the small struct, not the underlying
  native memory buffer.

  ## Structured storage

  Each structured component gets its own ETS `:set` table keyed by entity_id.
  Optional index tables (`:bag`) enable fast value-based lookup.
  """

  use GenServer

  @default_capacity 128

  # -- Store context ------------------------------------------------------------

  @doc "Returns the current store_id from the process dictionary, or raises."
  def current_store! do
    case Process.get(:lunity_store) do
      nil -> raise "No ComponentStore context set. Use ComponentStore.with_store/2."
      store_id -> store_id
    end
  end

  @doc "Returns the current store_id, or nil."
  def current_store do
    Process.get(:lunity_store)
  end

  @doc "Executes `fun` with the given store as the active context."
  def with_store(store_id, fun) when is_function(fun, 0) do
    old = Process.get(:lunity_store)
    Process.put(:lunity_store, store_id)

    try do
      fun.()
    after
      if old, do: Process.put(:lunity_store, old), else: Process.delete(:lunity_store)
    end
  end

  # -- ETS table names (per-store) ----------------------------------------------

  defp tensor_table(store_id), do: :"lunity_tensors_#{store_id}"
  defp registry_table(store_id), do: :"lunity_registry_#{store_id}"
  defp reverse_registry(store_id), do: :"lunity_reverse_#{store_id}"
  defp component_meta(store_id), do: :"lunity_meta_#{store_id}"
  defp table_name(store_id, module), do: :"#{Module.concat(module, "Store")}_#{store_id}"
  defp index_table_name(store_id, module), do: :"#{Module.concat(module, "Index")}_#{store_id}"

  # -- Public API ----------------------------------------------------------------

  @doc "Starts a ComponentStore for the given store_id."
  def start_link(store_id, opts \\ []) do
    GenServer.start_link(__MODULE__, [{:store_id, store_id} | opts], name: via(store_id))
  end

  @doc "Stops a ComponentStore."
  def stop(store_id) do
    case Registry.lookup(Lunity.ComponentStore.Registry, store_id) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> :ok
    end
  end

  @doc "Registers a component module in the given store (or current store)."
  def register(component_module, store_id \\ nil) do
    sid = store_id || current_store!()
    GenServer.call(via(sid), {:register, component_module})
  end

  @doc "Allocates a tensor index for an entity ID. Returns the integer index."
  def allocate(entity_id, store_id \\ nil) do
    sid = store_id || current_store!()

    case :ets.lookup(registry_table(sid), entity_id) do
      [{_, index}] ->
        index

      [] ->
        GenServer.call(via(sid), {:allocate, entity_id})
    end
  end

  @doc "Deallocates an entity's tensor index."
  def deallocate(entity_id, store_id \\ nil) do
    sid = store_id || current_store!()
    GenServer.call(via(sid), {:deallocate, entity_id})
  end

  @doc "Returns the tensor index for an entity ID, or nil."
  def index_of(entity_id, store_id \\ nil) do
    sid = store_id || current_store!()

    case :ets.lookup(registry_table(sid), entity_id) do
      [{_, index}] -> index
      [] -> nil
    end
  end

  @doc "Returns the entity ID at a tensor index, or nil."
  def entity_at(index, store_id \\ nil) do
    sid = store_id || current_store!()

    case :ets.lookup(reverse_registry(sid), index) do
      [{_, entity_id}] -> entity_id
      [] -> nil
    end
  end

  @doc "Gets a component value for an entity."
  def get(component_module, entity_id, store_id \\ nil) do
    sid = store_id || current_store!()
    opts = component_opts(component_module, sid)

    case opts.storage do
      :tensor -> get_tensor_value(component_module, entity_id, opts, sid)
      :structured -> get_structured_value(component_module, entity_id, sid)
    end
  end

  @doc "Sets a component value for an entity."
  def put(component_module, entity_id, value, store_id \\ nil) do
    sid = store_id || current_store!()
    opts = component_opts(component_module, sid)

    case opts.storage do
      :tensor -> put_tensor_value(component_module, entity_id, value, opts, sid)
      :structured -> put_structured_value(component_module, entity_id, value, opts, sid)
    end
  end

  @doc "Removes a component from an entity."
  def remove(component_module, entity_id, store_id \\ nil) do
    sid = store_id || current_store!()
    opts = component_opts(component_module, sid)

    case opts.storage do
      :tensor -> remove_tensor_value(component_module, entity_id, opts, sid)
      :structured -> remove_structured_value(component_module, entity_id, opts, sid)
    end
  end

  @doc "Checks if an entity has this component."
  def exists?(component_module, entity_id, store_id \\ nil) do
    sid = store_id || current_store!()
    opts = component_opts(component_module, sid)

    case opts.storage do
      :tensor ->
        case index_of(entity_id, sid) do
          nil -> false
          index -> get_presence(component_module, index, sid)
        end

      :structured ->
        :ets.member(table_name(sid, component_module), entity_id)
    end
  end

  @doc "Returns the raw Nx tensor for a tensor component."
  def get_tensor(component_module, store_id \\ nil) do
    sid = store_id || current_store!()

    case :ets.lookup(tensor_table(sid), component_module) do
      [{_, tensor}] -> tensor
      [] -> nil
    end
  end

  @doc "Replaces a tensor component's tensor."
  def put_tensor(component_module, tensor, store_id \\ nil) do
    sid = store_id || current_store!()
    :ets.insert(tensor_table(sid), {component_module, tensor})
    :ok
  end

  @doc "Returns all {entity_id, value} pairs for a structured component."
  def all(component_module, store_id \\ nil) do
    sid = store_id || current_store!()
    table = table_name(sid, component_module)
    :ets.tab2list(table) |> Enum.map(fn {id, val} -> {id, val} end)
  end

  @doc "Search for entity IDs by value (structured components with index: true)."
  def search(component_module, value, store_id \\ nil) do
    sid = store_id || current_store!()
    idx_table = index_table_name(sid, component_module)

    :ets.lookup(idx_table, value)
    |> Enum.map(fn {_value, entity_id} -> entity_id end)
  end

  @doc "Returns entity IDs that have presence for a tensor component."
  def entity_ids_with(component_module, store_id \\ nil) do
    sid = store_id || current_store!()

    case get_presence_mask(component_module, sid) do
      nil ->
        []

      mask ->
        mask
        |> Nx.to_flat_list()
        |> Enum.with_index()
        |> Enum.filter(fn {val, _idx} -> val == 1 end)
        |> Enum.map(fn {_, idx} -> entity_at(idx, sid) end)
        |> Enum.reject(&is_nil/1)
    end
  end

  @doc "Returns the presence mask tensor for a tensor component."
  def get_presence_mask(component_module, store_id \\ nil) do
    sid = store_id || current_store!()

    case :ets.lookup(tensor_table(sid), {component_module, :presence}) do
      [{_, mask}] -> mask
      [] -> nil
    end
  end

  # -- GenServer callbacks -------------------------------------------------------

  defp via(store_id), do: {:via, Registry, {Lunity.ComponentStore.Registry, store_id}}

  @impl true
  def init(opts) do
    store_id = Keyword.fetch!(opts, :store_id)
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    :ets.new(tensor_table(store_id), [:named_table, :set, :public, read_concurrency: true])
    :ets.new(registry_table(store_id), [:named_table, :set, :public, read_concurrency: true])
    :ets.new(reverse_registry(store_id), [:named_table, :set, :public, read_concurrency: true])
    :ets.new(component_meta(store_id), [:named_table, :set, :public, read_concurrency: true])

    {:ok, %{store_id: store_id, capacity: capacity, next_index: 0, free_indices: []}}
  end

  @impl true
  def handle_call({:register, component_module}, _from, state) do
    sid = state.store_id
    opts = component_module.__component_opts__()
    :ets.insert(component_meta(sid), {component_module, opts})

    case opts.storage do
      :tensor ->
        init_tensor_component(component_module, opts, state.capacity, sid)

      :structured ->
        init_structured_component(component_module, opts, sid)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:allocate, entity_id}, _from, state) do
    sid = state.store_id

    {index, state} =
      case state.free_indices do
        [idx | rest] ->
          {idx, %{state | free_indices: rest}}

        [] ->
          idx = state.next_index

          if idx >= state.capacity do
            grow_all_tensors(state.capacity, state.capacity * 2, sid)
            {idx, %{state | next_index: idx + 1, capacity: state.capacity * 2}}
          else
            {idx, %{state | next_index: idx + 1}}
          end
      end

    :ets.insert(registry_table(sid), {entity_id, index})
    :ets.insert(reverse_registry(sid), {index, entity_id})
    {:reply, index, state}
  end

  @impl true
  def handle_call({:deallocate, entity_id}, _from, state) do
    sid = state.store_id

    case :ets.lookup(registry_table(sid), entity_id) do
      [{_, index}] ->
        :ets.delete(registry_table(sid), entity_id)
        :ets.delete(reverse_registry(sid), index)
        zero_tensor_index(index, sid)
        {:reply, :ok, %{state | free_indices: [index | state.free_indices]}}

      [] ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    sid = state.store_id

    for table <- [
          tensor_table(sid),
          registry_table(sid),
          reverse_registry(sid),
          component_meta(sid)
        ] do
      try do
        :ets.delete(table)
      rescue
        _ -> :ok
      end
    end

    for {mod, opts} <- list_components(sid) do
      try do
        :ets.delete(table_name(sid, mod))
      rescue
        _ -> :ok
      end

      if opts.storage == :structured && Map.get(opts, :index, false) do
        try do
          :ets.delete(index_table_name(sid, mod))
        rescue
          _ -> :ok
        end
      end
    end

    :ok
  end

  # -- Private: Component listing -----------------------------------------------

  defp list_components(store_id) do
    try do
      :ets.tab2list(component_meta(store_id))
    rescue
      _ -> []
    end
  end

  # -- Private: Tensor operations ------------------------------------------------

  defp init_tensor_component(component_module, opts, capacity, store_id) do
    shape = opts.shape
    dtype = opts.dtype
    full_shape = tensor_shape(shape, capacity)
    tensor = Nx.broadcast(Nx.tensor(0, type: dtype), full_shape)
    :ets.insert(tensor_table(store_id), {component_module, tensor})

    presence = Nx.broadcast(Nx.tensor(0, type: :u8), {capacity})
    :ets.insert(tensor_table(store_id), {{component_module, :presence}, presence})
  end

  defp init_structured_component(component_module, opts, store_id) do
    table = table_name(store_id, component_module)
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])

    if Map.get(opts, :index, false) do
      idx_table = index_table_name(store_id, component_module)
      :ets.new(idx_table, [:named_table, :bag, :public])
    end
  end

  defp tensor_shape(shape, capacity) when is_tuple(shape) do
    dims = Tuple.to_list(shape)

    case dims do
      [] -> {capacity}
      _ -> List.to_tuple([capacity | dims])
    end
  end

  defp get_tensor_value(component_module, entity_id, opts, store_id) do
    case index_of(entity_id, store_id) do
      nil ->
        nil

      index ->
        unless get_presence(component_module, index, store_id), do: nil

        tensor = get_tensor(component_module, store_id)

        case opts.shape do
          {} ->
            Nx.to_number(tensor[index])

          shape ->
            size = Tuple.to_list(shape)
            start = [index | List.duplicate(0, length(size))]
            lengths = [1 | size]

            Nx.slice(tensor, start, lengths)
            |> Nx.reshape(shape)
            |> Nx.to_flat_list()
            |> List.to_tuple()
        end
    end
  end

  defp put_tensor_value(component_module, entity_id, value, opts, store_id) do
    index = allocate(entity_id, store_id)
    tensor = get_tensor(component_module, store_id)

    new_tensor =
      case opts.shape do
        {} ->
          Nx.indexed_put(tensor, Nx.tensor([index]), Nx.tensor(value, type: opts.dtype))

        shape ->
          vals =
            case value do
              t when is_tuple(t) -> Tuple.to_list(t)
              l when is_list(l) -> l
              _ -> [value]
            end

          update =
            Nx.tensor(vals, type: opts.dtype)
            |> Nx.reshape(List.to_tuple([1 | Tuple.to_list(shape)]))

          indices = Nx.tensor([[index]])
          Nx.indexed_put(tensor, indices, update)
      end

    put_tensor(component_module, new_tensor, store_id)
    set_presence(component_module, index, true, store_id)
    :ok
  end

  defp remove_tensor_value(component_module, entity_id, opts, store_id) do
    case index_of(entity_id, store_id) do
      nil ->
        :ok

      index ->
        tensor = get_tensor(component_module, store_id)

        new_tensor =
          case opts.shape do
            {} ->
              Nx.indexed_put(tensor, Nx.tensor([index]), Nx.tensor(0, type: opts.dtype))

            shape ->
              zeros =
                Nx.broadcast(
                  Nx.tensor(0, type: opts.dtype),
                  List.to_tuple([1 | Tuple.to_list(shape)])
                )

              Nx.indexed_put(tensor, Nx.tensor([[index]]), zeros)
          end

        put_tensor(component_module, new_tensor, store_id)
        set_presence(component_module, index, false, store_id)
        :ok
    end
  end

  defp get_presence(component_module, index, store_id) do
    case :ets.lookup(tensor_table(store_id), {component_module, :presence}) do
      [{_, mask}] -> Nx.to_number(mask[index]) == 1
      [] -> false
    end
  end

  defp set_presence(component_module, index, present, store_id) do
    case :ets.lookup(tensor_table(store_id), {component_module, :presence}) do
      [{_, mask}] ->
        val = if present, do: 1, else: 0
        new_mask = Nx.indexed_put(mask, Nx.tensor([index]), Nx.tensor(val, type: :u8))
        :ets.insert(tensor_table(store_id), {{component_module, :presence}, new_mask})

      [] ->
        :ok
    end
  end

  defp zero_tensor_index(index, store_id) do
    tensors = :ets.tab2list(tensor_table(store_id))

    for {key, _tensor} <- tensors do
      case key do
        module when is_atom(module) ->
          opts = component_opts(module, store_id)
          if opts && opts.storage == :tensor, do: remove_tensor_value(module, nil, opts, store_id)

        _ ->
          :ok
      end
    end

    _ = index
    :ok
  end

  defp grow_all_tensors(old_capacity, new_capacity, store_id) do
    tensors = :ets.tab2list(tensor_table(store_id))

    for {key, tensor} <- tensors do
      case key do
        {_module, :presence} ->
          padding = Nx.broadcast(Nx.tensor(0, type: :u8), {new_capacity - old_capacity})
          :ets.insert(tensor_table(store_id), {key, Nx.concatenate([tensor, padding])})

        module when is_atom(module) ->
          opts = component_opts(module, store_id)

          if opts && opts.storage == :tensor do
            current_shape = Nx.shape(tensor) |> Tuple.to_list()
            [_ | rest] = current_shape
            pad_shape = List.to_tuple([new_capacity - old_capacity | rest])
            padding = Nx.broadcast(Nx.tensor(0, type: opts.dtype), pad_shape)
            :ets.insert(tensor_table(store_id), {key, Nx.concatenate([tensor, padding])})
          end

        _ ->
          :ok
      end
    end
  end

  # -- Private: Structured operations -------------------------------------------

  defp get_structured_value(component_module, entity_id, store_id) do
    table = table_name(store_id, component_module)

    case :ets.lookup(table, entity_id) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  defp put_structured_value(component_module, entity_id, value, opts, store_id) do
    table = table_name(store_id, component_module)

    if Map.get(opts, :index, false) do
      idx_table = index_table_name(store_id, component_module)

      case :ets.lookup(table, entity_id) do
        [{_, old_value}] -> :ets.delete_object(idx_table, {old_value, entity_id})
        [] -> :ok
      end

      :ets.insert(idx_table, {value, entity_id})
    end

    :ets.insert(table, {entity_id, value})
    :ok
  end

  defp remove_structured_value(component_module, entity_id, opts, store_id) do
    table = table_name(store_id, component_module)

    if Map.get(opts, :index, false) do
      idx_table = index_table_name(store_id, component_module)

      case :ets.lookup(table, entity_id) do
        [{_, old_value}] -> :ets.delete_object(idx_table, {old_value, entity_id})
        [] -> :ok
      end
    end

    :ets.delete(table, entity_id)
    :ok
  end

  # -- Private: Helpers ----------------------------------------------------------

  defp component_opts(component_module, store_id) do
    case :ets.lookup(component_meta(store_id), component_module) do
      [{_, opts}] -> opts
      [] -> component_module.__component_opts__()
    end
  end
end
