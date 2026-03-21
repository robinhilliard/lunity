defmodule Lunity.Web.EcsState do
  @moduledoc """
  JSON-safe projection of ECS snapshots for player `state` messages.

  `filter: nil` means **full** normalized snapshot; future filters may return a subset
  (e.g. spatial queries) without changing the outer protocol envelope.
  """

  @spec encode_for_wire(term()) :: term()
  def encode_for_wire(term), do: normalize(term)

  defp normalize(%Nx.Tensor{} = t), do: Nx.to_flat_list(t)

  defp normalize(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  defp normalize(%{} = map) do
    Map.new(map, fn {k, v} ->
      {normalize_key(k), normalize(v)}
    end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)

  defp normalize(tuple) when is_tuple(tuple) do
    tuple |> Tuple.to_list() |> normalize()
  end

  defp normalize(other), do: other

  defp normalize_key(k) when is_atom(k), do: Atom.to_string(k)
  defp normalize_key(k), do: k
end
