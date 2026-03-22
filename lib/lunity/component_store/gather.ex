defmodule Lunity.ComponentStore.Gather do
  @moduledoc """
  Gather/scatter helpers for tensor systems that operate on a subset of entities.

  When a tensor system declares `filter: SomeComponent` (or a list of
  components), the TickRunner uses these helpers to compact the input
  tensors down to only the active entities, run the system on smaller
  tensors, and scatter the results back into the full-capacity originals.

  This is the formal version of the manual gather/scatter pattern used
  in `SweptAABBCollision`. Use it for systems with superlinear cost
  (e.g. N-squared collision) where reducing N saves orders of magnitude.
  For simple linear systems, processing the full tensor with `Nx.select`
  masking is typically faster.

  Active indices are cached per-store and invalidated only when entity
  lifecycle events occur (allocate, deallocate, presence changes), so
  the per-tick cost of determining active entities is O(1) in the common
  case.
  """

  alias Lunity.ComponentStore

  @doc """
  Returns the list of active tensor indices for one or more components.

  Accepts a single component module or a list. When given a list, the
  presence masks are ANDed together -- only entities present in ALL
  listed components are included.

  Results are cached in the store's tensor ETS table and invalidated
  by `ComponentStore` on entity lifecycle events.
  """
  @spec active_indices(module() | [module()], term()) :: [non_neg_integer()]
  def active_indices(component_or_list, store_id \\ nil) do
    sid = store_id || ComponentStore.current_store!()
    components = List.wrap(component_or_list) |> Enum.sort()
    cache_key = {components, :cached_indices}
    tensor_table = :"lunity_tensors_#{sid}"

    case :ets.lookup(tensor_table, cache_key) do
      [{_, cached}] ->
        cached

      [] ->
        indices = compute_active_indices(components, sid)
        :ets.insert(tensor_table, {cache_key, indices})
        indices
    end
  end

  @doc """
  Compacts input tensors to only the rows at the given indices.

  Takes an inputs map (e.g. `%{position: {128,3}, velocity: {128,3}}`)
  and a list of integer indices. Returns a new map where each tensor
  value has been gathered via `Nx.take`. Non-tensor values (like
  `:ball_idx` scalar inputs from the `entities:` option) are passed
  through unchanged.
  """
  @spec gather(map(), [non_neg_integer()]) :: map()
  def gather(inputs, indices) do
    idx_tensor = Nx.tensor(indices)

    Map.new(inputs, fn {key, value} ->
      if is_struct(value, Nx.Tensor) and tuple_size(Nx.shape(value)) >= 1 and
           elem(Nx.shape(value), 0) > 1 do
        {key, Nx.take(value, idx_tensor)}
      else
        {key, value}
      end
    end)
  end

  @doc """
  Scatters compact output tensors back into full-capacity originals.

  For each key in `compact_outputs`, reads the corresponding full tensor
  from `full_inputs` and writes the compact rows back at the given indices
  using a single batched `Nx.indexed_put`.

  Returns a map of full-capacity tensors ready for `ComponentStore.put_tensor`.
  """
  @spec scatter(map(), map(), [non_neg_integer()]) :: map()
  def scatter(full_inputs, compact_outputs, indices) do
    idx_tensor = Nx.tensor(Enum.map(indices, &[&1]))

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
    rescue
      ArgumentError -> :ok
    end

    :ok
  end

  defp compute_active_indices(components, store_id) do
    masks =
      Enum.map(components, fn comp ->
        ComponentStore.get_presence_mask(comp, store_id)
      end)
      |> Enum.reject(&is_nil/1)

    case masks do
      [] ->
        []

      [single] ->
        mask_to_indices(single)

      [first | rest] ->
        combined = Enum.reduce(rest, first, &Nx.logical_and(&2, &1))
        mask_to_indices(combined)
    end
  end

  defp mask_to_indices(mask) do
    mask
    |> Nx.to_flat_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {v, i} -> if v == 1, do: [i], else: [] end)
  end
end
