defmodule Lunity.ComponentStore.Gather do
  @moduledoc """
  Gather/scatter helpers for tensor systems that operate on a subset of entities.

  When a tensor system declares `filter: SomeComponent` (or a list of
  components), the TickRunner uses these helpers to compact the input
  tensors down to only the active entities, run the system on smaller
  tensors, and scatter the results back into the full-capacity originals.

  Active indices are cached per-store as **device tensors** (plus an integer
  count) and invalidated only when entity lifecycle events occur. The hot
  path therefore avoids per-tick `Nx.to_flat_list/1` host syncs.
  """

  alias Lunity.ComponentStore
  alias Lunity.Nx.Host

  @doc """
  Returns cached active-index metadata for one or more components.

  ## Return value

      %{count: non_neg_integer(), indices: Nx.Tensor.t(), put_indices: Nx.Tensor.t()}

  * `indices` — `{count}` `:s32` row indices (for `Nx.take`)
  * `put_indices` — `{count, 1}` `:s32` indices (for `Nx.indexed_put`)

  Accepts a single component module or a list. When given a list, presence
  masks are ANDed — only entities present in ALL listed components are included.
  """
  @spec active_index_set(module() | [module()], term()) :: %{
          count: non_neg_integer(),
          indices: Nx.Tensor.t() | nil,
          put_indices: Nx.Tensor.t() | nil
        }
  def active_index_set(component_or_list, store_id \\ nil) do
    sid = store_id || ComponentStore.current_store!()
    components = List.wrap(component_or_list) |> Enum.sort()
    cache_key = {components, :cached_active}
    tensor_table = :"lunity_tensors_#{sid}"

    case :ets.lookup(tensor_table, cache_key) do
      [{_, cached}] ->
        cached

      [] ->
        cached = compute_active_index_set(components, sid)
        :ets.insert(tensor_table, {cache_key, cached})
        cached
    end
  end

  @doc """
  Returns the list of active tensor indices (host sync).

  Prefer `active_index_set/2` on the tick hot path. This helper exists for
  tools, tests, and debug inspection.
  """
  @spec active_indices(module() | [module()], term()) :: [non_neg_integer()]
  def active_indices(component_or_list, store_id \\ nil) do
    case active_index_set(component_or_list, store_id) do
      %{count: 0} ->
        []

      %{indices: indices} when not is_nil(indices) ->
        indices |> Host.to_list() |> Enum.map(&trunc/1)
    end
  end

  @doc """
  Compacts input tensors to only the rows at the given indices.

  `indices` may be:

  * a `%{indices: tensor}` / full index-set map from `active_index_set/2`
  * an `{N}` index tensor
  * an Elixir list of integers (host path / tests)
  """
  @spec gather(map(), [non_neg_integer()] | Nx.Tensor.t() | map()) :: map()
  def gather(inputs, indices) do
    idx_tensor = normalize_take_indices(indices)

    Map.new(inputs, fn {key, value} ->
      if gatherable_tensor?(value) do
        {key, Nx.take(value, idx_tensor)}
      else
        {key, value}
      end
    end)
  end

  @doc """
  Scatters compact output tensors back into full-capacity originals.

  `indices` accepts the same forms as `gather/2`. When given an index-set
  map, uses the precomputed `{count, 1}` `put_indices` tensor.
  """
  @spec scatter(map(), map(), [non_neg_integer()] | Nx.Tensor.t() | map()) :: map()
  def scatter(full_inputs, compact_outputs, indices) do
    idx_tensor = normalize_put_indices(indices)

    Map.new(compact_outputs, fn {key, compact_tensor} ->
      full_tensor = Map.fetch!(full_inputs, key)
      updated = Nx.indexed_put(full_tensor, idx_tensor, compact_tensor)
      {key, updated}
    end)
  end

  @doc """
  Clears all cached active-index entries for a store.

  Called by `ComponentStore` when entity lifecycle events occur
  (allocate, deallocate, presence changes).
  """
  @spec invalidate_cache(term()) :: :ok
  def invalidate_cache(store_id) do
    tensor_table = :"lunity_tensors_#{store_id}"

    try do
      :ets.match_delete(tensor_table, {{:_, :cached_indices}, :_})
      :ets.match_delete(tensor_table, {{:_, :cached_active}, :_})
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  # -- Private ------------------------------------------------------------------

  defp compute_active_index_set(components, store_id) do
    masks =
      components
      |> Enum.map(&ComponentStore.get_presence_mask(&1, store_id))
      |> Enum.reject(&is_nil/1)

    case masks do
      [] ->
        empty_index_set()

      [single] ->
        mask_to_index_set(single)

      [first | rest] ->
        combined = Enum.reduce(rest, first, &Nx.logical_and(&2, &1))
        mask_to_index_set(combined)
    end
  end

  defp mask_to_index_set(mask) do
    # Lifecycle / cache-miss path: one host sync to materialize indices, then
    # store them back on the default backend for subsequent device-side ticks.
    list =
      mask
      |> Host.to_list()
      |> Enum.with_index()
      |> Enum.flat_map(fn {v, i} -> if v == 1, do: [i], else: [] end)

    build_index_set(list)
  end

  defp build_index_set([]) do
    empty_index_set()
  end

  defp build_index_set(list) when is_list(list) do
    indices = Host.from_host(list, type: :s32)
    put_indices = Host.from_host(Enum.map(list, &[&1]), type: :s32)

    %{
      count: length(list),
      indices: indices,
      put_indices: put_indices
    }
  end

  defp empty_index_set do
    # Nx cannot represent empty index tensors portably; callers must check `count`.
    %{count: 0, indices: nil, put_indices: nil}
  end

  defp normalize_take_indices(%{count: 0}), do: raise_empty_indices!()
  defp normalize_take_indices(%{indices: %Nx.Tensor{} = indices}), do: indices
  defp normalize_take_indices(%Nx.Tensor{} = indices), do: indices
  defp normalize_take_indices(list) when is_list(list), do: Host.from_host(list, type: :s32)

  defp normalize_put_indices(%{count: 0}), do: raise_empty_indices!()
  defp normalize_put_indices(%{put_indices: %Nx.Tensor{} = indices}), do: indices

  defp normalize_put_indices(%Nx.Tensor{} = indices) do
    case Nx.shape(indices) do
      {_, 1} -> indices
      {_n} -> Nx.reshape(indices, {:auto, 1})
      _ -> indices
    end
  end

  defp normalize_put_indices(list) when is_list(list) do
    Host.from_host(Enum.map(list, &[&1]), type: :s32)
  end

  defp raise_empty_indices! do
    raise ArgumentError,
      message: "cannot gather/scatter with an empty active index set (count == 0)"
  end

  defp gatherable_tensor?(value) do
    is_struct(value, Nx.Tensor) and tuple_size(Nx.shape(value)) >= 1 and
      elem(Nx.shape(value), 0) > 1
  end
end
