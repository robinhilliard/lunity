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

    %{
      "name" => node.name,
      "properties" => properties,
      "children" => Enum.map(Node.get_children(node), &node_to_map/1)
    }
  end
end
