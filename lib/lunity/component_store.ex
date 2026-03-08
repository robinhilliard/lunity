defmodule Lunity.ComponentStore do
  @moduledoc """
  Manages component storage for the Lunity ECS.

  Tensor components are stored as Nx tensors in an ETS table (`:lunity_tensors`).
  Structured components are stored directly in per-component ETS tables.
  An entity registry maps symbolic entity IDs to integer tensor indices.

  ## Tensor storage

  Each tensor component gets a row per entity, indexed by integer position.
  The entity registry maps `{instance_id, :ball}` -> integer index.
  Nx tensors stored in ETS copy only the small struct, not the underlying
  native memory buffer.

  ## Structured storage

  Each structured component gets its own ETS `:set` table keyed by entity_id.
  Optional index tables (`:bag`) enable fast value-based lookup.
  """

  use GenServer

  @tensor_table :lunity_tensors
  @registry_table :lunity_entity_registry
  @reverse_registry :lunity_entity_reverse
  @component_meta :lunity_component_meta
  @default_capacity 1024

  # -- Public API ----------------------------------------------------------------

  @doc "Starts the ComponentStore."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Registers a component module. Called during manager setup."
  def register(component_module) do
    GenServer.call(__MODULE__, {:register, component_module})
  end

  @doc "Allocates a tensor index for an entity ID. Returns the integer index."
  def allocate(entity_id) do
    case :ets.lookup(@registry_table, entity_id) do
      [{_, index}] ->
        index

      [] ->
        GenServer.call(__MODULE__, {:allocate, entity_id})
    end
  end

  @doc "Deallocates an entity's tensor index."
  def deallocate(entity_id) do
    GenServer.call(__MODULE__, {:deallocate, entity_id})
  end

  @doc "Returns the tensor index for an entity ID, or nil."
  def index_of(entity_id) do
    case :ets.lookup(@registry_table, entity_id) do
      [{_, index}] -> index
      [] -> nil
    end
  end

  @doc "Returns the entity ID at a tensor index, or nil."
  def entity_at(index) do
    case :ets.lookup(@reverse_registry, index) do
      [{_, entity_id}] -> entity_id
      [] -> nil
    end
  end

  @doc "Gets a component value for an entity."
  def get(component_module, entity_id) do
    opts = component_opts(component_module)

    case opts.storage do
      :tensor -> get_tensor_value(component_module, entity_id, opts)
      :structured -> get_structured_value(component_module, entity_id)
    end
  end

  @doc "Sets a component value for an entity."
  def put(component_module, entity_id, value) do
    opts = component_opts(component_module)

    case opts.storage do
      :tensor -> put_tensor_value(component_module, entity_id, value, opts)
      :structured -> put_structured_value(component_module, entity_id, value, opts)
    end
  end

  @doc "Removes a component from an entity."
  def remove(component_module, entity_id) do
    opts = component_opts(component_module)

    case opts.storage do
      :tensor -> remove_tensor_value(component_module, entity_id, opts)
      :structured -> remove_structured_value(component_module, entity_id, opts)
    end
  end

  @doc "Checks if an entity has this component."
  def exists?(component_module, entity_id) do
    opts = component_opts(component_module)

    case opts.storage do
      :tensor ->
        case index_of(entity_id) do
          nil -> false
          index -> get_presence(component_module, index)
        end

      :structured ->
        :ets.member(table_name(component_module), entity_id)
    end
  end

  @doc "Returns the raw Nx tensor for a tensor component."
  def get_tensor(component_module) do
    case :ets.lookup(@tensor_table, component_module) do
      [{_, tensor}] -> tensor
      [] -> nil
    end
  end

  @doc "Replaces a tensor component's tensor."
  def put_tensor(component_module, tensor) do
    :ets.insert(@tensor_table, {component_module, tensor})
    :ok
  end

  @doc "Returns all {entity_id, value} pairs for a structured component."
  def all(component_module) do
    table = table_name(component_module)
    :ets.tab2list(table) |> Enum.map(fn {id, val} -> {id, val} end)
  end

  @doc "Search for entity IDs by value (structured components with index: true)."
  def search(component_module, value) do
    index_table = index_table_name(component_module)

    :ets.lookup(index_table, value)
    |> Enum.map(fn {_value, entity_id} -> entity_id end)
  end

  @doc "Returns the presence mask tensor for a tensor component."
  def get_presence_mask(component_module) do
    case :ets.lookup(@tensor_table, {component_module, :presence}) do
      [{_, mask}] -> mask
      [] -> nil
    end
  end

  # -- GenServer callbacks -------------------------------------------------------

  @impl true
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)

    :ets.new(@tensor_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@registry_table, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@reverse_registry, [:named_table, :set, :public, read_concurrency: true])
    :ets.new(@component_meta, [:named_table, :set, :public, read_concurrency: true])

    {:ok, %{capacity: capacity, next_index: 0, free_indices: []}}
  end

  @impl true
  def handle_call({:register, component_module}, _from, state) do
    opts = component_module.__component_opts__()
    :ets.insert(@component_meta, {component_module, opts})

    case opts.storage do
      :tensor ->
        init_tensor_component(component_module, opts, state.capacity)

      :structured ->
        init_structured_component(component_module, opts)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:allocate, entity_id}, _from, state) do
    {index, state} =
      case state.free_indices do
        [idx | rest] ->
          {idx, %{state | free_indices: rest}}

        [] ->
          idx = state.next_index

          if idx >= state.capacity do
            grow_all_tensors(state.capacity, state.capacity * 2)
            {idx, %{state | next_index: idx + 1, capacity: state.capacity * 2}}
          else
            {idx, %{state | next_index: idx + 1}}
          end
      end

    :ets.insert(@registry_table, {entity_id, index})
    :ets.insert(@reverse_registry, {index, entity_id})
    {:reply, index, state}
  end

  @impl true
  def handle_call({:deallocate, entity_id}, _from, state) do
    case :ets.lookup(@registry_table, entity_id) do
      [{_, index}] ->
        :ets.delete(@registry_table, entity_id)
        :ets.delete(@reverse_registry, index)
        zero_tensor_index(index)
        {:reply, :ok, %{state | free_indices: [index | state.free_indices]}}

      [] ->
        {:reply, :ok, state}
    end
  end

  # -- Private: Tensor operations ------------------------------------------------

  defp init_tensor_component(component_module, opts, capacity) do
    shape = opts.shape
    dtype = opts.dtype
    full_shape = tensor_shape(shape, capacity)
    tensor = Nx.broadcast(Nx.tensor(0, type: dtype), full_shape)
    :ets.insert(@tensor_table, {component_module, tensor})

    presence = Nx.broadcast(Nx.tensor(0, type: :u8), {capacity})
    :ets.insert(@tensor_table, {{component_module, :presence}, presence})
  end

  defp init_structured_component(component_module, opts) do
    table = table_name(component_module)
    :ets.new(table, [:named_table, :set, :public, read_concurrency: true])

    if Map.get(opts, :index, false) do
      idx_table = index_table_name(component_module)
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

  defp get_tensor_value(component_module, entity_id, opts) do
    case index_of(entity_id) do
      nil ->
        nil

      index ->
        unless get_presence(component_module, index), do: nil

        tensor = get_tensor(component_module)

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

  defp put_tensor_value(component_module, entity_id, value, opts) do
    index = allocate(entity_id)
    tensor = get_tensor(component_module)

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

    put_tensor(component_module, new_tensor)
    set_presence(component_module, index, true)
    :ok
  end

  defp remove_tensor_value(component_module, entity_id, opts) do
    case index_of(entity_id) do
      nil ->
        :ok

      index ->
        tensor = get_tensor(component_module)

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

        put_tensor(component_module, new_tensor)
        set_presence(component_module, index, false)
        :ok
    end
  end

  defp get_presence(component_module, index) do
    case :ets.lookup(@tensor_table, {component_module, :presence}) do
      [{_, mask}] -> Nx.to_number(mask[index]) == 1
      [] -> false
    end
  end

  defp set_presence(component_module, index, present) do
    case :ets.lookup(@tensor_table, {component_module, :presence}) do
      [{_, mask}] ->
        val = if present, do: 1, else: 0
        new_mask = Nx.indexed_put(mask, Nx.tensor([index]), Nx.tensor(val, type: :u8))
        :ets.insert(@tensor_table, {{component_module, :presence}, new_mask})

      [] ->
        :ok
    end
  end

  defp zero_tensor_index(index) do
    tensors = :ets.tab2list(@tensor_table)

    for {key, _tensor} <- tensors do
      case key do
        module when is_atom(module) ->
          opts = component_opts(module)
          if opts && opts.storage == :tensor, do: remove_tensor_value(module, nil, opts)

        _ ->
          :ok
      end
    end

    _ = index
    :ok
  end

  defp grow_all_tensors(old_capacity, new_capacity) do
    tensors = :ets.tab2list(@tensor_table)

    for {key, tensor} <- tensors do
      case key do
        {_module, :presence} ->
          padding = Nx.broadcast(Nx.tensor(0, type: :u8), {new_capacity - old_capacity})
          :ets.insert(@tensor_table, {key, Nx.concatenate([tensor, padding])})

        module when is_atom(module) ->
          opts = component_opts(module)

          if opts && opts.storage == :tensor do
            current_shape = Nx.shape(tensor) |> Tuple.to_list()
            [_ | rest] = current_shape
            pad_shape = List.to_tuple([new_capacity - old_capacity | rest])
            padding = Nx.broadcast(Nx.tensor(0, type: opts.dtype), pad_shape)
            :ets.insert(@tensor_table, {key, Nx.concatenate([tensor, padding])})
          end

        _ ->
          :ok
      end
    end
  end

  # -- Private: Structured operations -------------------------------------------

  defp get_structured_value(component_module, entity_id) do
    table = table_name(component_module)

    case :ets.lookup(table, entity_id) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  defp put_structured_value(component_module, entity_id, value, opts) do
    table = table_name(component_module)

    if Map.get(opts, :index, false) do
      idx_table = index_table_name(component_module)

      case :ets.lookup(table, entity_id) do
        [{_, old_value}] -> :ets.delete_object(idx_table, {old_value, entity_id})
        [] -> :ok
      end

      :ets.insert(idx_table, {value, entity_id})
    end

    :ets.insert(table, {entity_id, value})
    :ok
  end

  defp remove_structured_value(component_module, entity_id, opts) do
    table = table_name(component_module)

    if Map.get(opts, :index, false) do
      idx_table = index_table_name(component_module)

      case :ets.lookup(table, entity_id) do
        [{_, old_value}] -> :ets.delete_object(idx_table, {old_value, entity_id})
        [] -> :ok
      end
    end

    :ets.delete(table, entity_id)
    :ok
  end

  # -- Private: Helpers ----------------------------------------------------------

  defp component_opts(component_module) do
    case :ets.lookup(@component_meta, component_module) do
      [{_, opts}] -> opts
      [] -> component_module.__component_opts__()
    end
  end

  defp table_name(module), do: Module.concat(module, "Store")
  defp index_table_name(module), do: Module.concat(module, "Index")
end
