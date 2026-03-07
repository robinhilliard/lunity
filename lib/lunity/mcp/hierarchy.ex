defmodule Lunity.MCP.Hierarchy do
  @moduledoc """
  Builds a serializable hierarchy from an EAGL.Scene for MCP tools.
  """
  alias EAGL.Node

  @doc """
  Convert a scene to a hierarchy structure (list of root nodes with children).
  """
  @spec from_scene(EAGL.Scene.t()) :: [map()]
  def from_scene(%EAGL.Scene{root_nodes: roots}) do
    Enum.map(roots, &node_to_map/1)
  end

  defp node_to_map(%Node{} = node) do
    properties =
      (node.properties || %{})
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Map.new()

    base = %{
      "name" => node.name,
      "properties" => properties,
      "children" => Enum.map(Node.get_children(node), &node_to_map/1)
    }

    base
    |> maybe_put("position", node.position, &vec3_to_list/1)
    |> maybe_put("scale", node.scale, &vec3_to_list/1)
  end

  defp maybe_put(map, _key, nil, _fun), do: map
  defp maybe_put(map, key, value, fun) when not is_nil(value), do: Map.put(map, key, fun.(value))

  defp vec3_to_list([{x, y, z}]), do: [x, y, z]
  defp vec3_to_list({x, y, z}), do: [x, y, z]
  defp vec3_to_list(other) when is_list(other), do: other
end
