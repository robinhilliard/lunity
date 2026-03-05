defmodule Lunity.Mod.RuntimeAPI do
  @moduledoc """
  Bridge between Lua runtime API calls and the Lunity engine.

  These functions are called from Lua via the injected `lunity.*` API.
  They interact with ECSx components and the EAGL scene graph through
  the editor state.

  This is a thin adapter -- the actual game logic lives in ECSx systems
  and entity modules. Lua mods use this API to read/write entity properties
  and scene node transforms.
  """

  require Logger

  @doc """
  Get an entity property value.
  """
  @spec entity_get(term(), String.t()) :: term()
  def entity_get(entity_id, property) do
    entities = Lunity.Editor.State.get_entities()

    case find_entity_node(entities, entity_id) do
      {node, _id} ->
        props = node.properties || %{}
        Map.get(props, property)

      nil ->
        nil
    end
  end

  @doc """
  Set an entity property value.
  """
  @spec entity_set(term(), String.t(), term()) :: :ok
  def entity_set(_entity_id, _property, _value) do
    Logger.debug("entity_set: not yet wired to ECSx")
    :ok
  end

  @doc """
  Find an entity by name, returning its entity_id.
  """
  @spec entity_find(String.t()) :: term()
  def entity_find(entity_name) do
    entities = Lunity.Editor.State.get_entities()

    case Enum.find(entities, fn {node, _id} ->
           node.name == entity_name ||
             (node.properties || %{})["entity"] == entity_name
         end) do
      {_node, id} -> id
      nil -> nil
    end
  end

  @doc """
  Spawn an entity by name with optional overrides.
  """
  @spec entity_spawn(String.t(), term()) :: term()
  def entity_spawn(_entity_name, _overrides) do
    Logger.debug("entity_spawn: not yet implemented")
    nil
  end

  @doc """
  Destroy an entity by ID.
  """
  @spec entity_destroy(term()) :: :ok
  def entity_destroy(_entity_id) do
    Logger.debug("entity_destroy: not yet implemented")
    :ok
  end

  @doc """
  Get scene node info by name.
  """
  @spec scene_get_node(String.t()) :: term()
  def scene_get_node(name) do
    case Lunity.Editor.State.get_scene() do
      %EAGL.Scene{} = scene ->
        case find_node_by_name(scene.root_nodes, name) do
          nil -> nil
          node -> node_to_lua(node)
        end

      _ ->
        nil
    end
  end

  @doc """
  Set a scene node's position.
  """
  @spec scene_set_node_position(String.t(), number(), number(), number()) :: :ok
  def scene_set_node_position(_name, _x, _y, _z) do
    Logger.debug("scene_set_node_position: not yet wired to scene graph mutation")
    :ok
  end

  @doc """
  Check if a key is currently pressed.
  """
  @spec input_is_key_down(String.t()) :: boolean()
  def input_is_key_down(_key) do
    false
  end

  # -- Private ----------------------------------------------------------------

  defp find_entity_node(entities, entity_id) do
    Enum.find(entities, fn {_node, id} -> id == entity_id end)
  end

  defp find_node_by_name([], _name), do: nil

  defp find_node_by_name([node | rest], name) do
    if node.name == name do
      node
    else
      case find_node_by_name(node.children || [], name) do
        nil -> find_node_by_name(rest, name)
        found -> found
      end
    end
  end

  defp node_to_lua(node) do
    [
      {"name", node.name || ""},
      {"position", position_to_lua(node.position)},
      {"scale", scale_to_lua(node.scale)}
    ]
  end

  defp position_to_lua(nil), do: [{1.0, 0.0}, {2.0, 0.0}, {3.0, 0.0}]

  defp position_to_lua({x, y, z}) do
    [{1.0, x * 1.0}, {2.0, y * 1.0}, {3.0, z * 1.0}]
  end

  defp position_to_lua(_), do: [{1.0, 0.0}, {2.0, 0.0}, {3.0, 0.0}]

  defp scale_to_lua(nil), do: [{1.0, 1.0}, {2.0, 1.0}, {3.0, 1.0}]

  defp scale_to_lua({x, y, z}) do
    [{1.0, x * 1.0}, {2.0, y * 1.0}, {3.0, z * 1.0}]
  end

  defp scale_to_lua(_), do: [{1.0, 1.0}, {2.0, 1.0}, {3.0, 1.0}]
end
