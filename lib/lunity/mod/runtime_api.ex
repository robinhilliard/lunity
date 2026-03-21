defmodule Lunity.Mod.RuntimeAPI do
  @moduledoc """
  Bridge between Lua runtime API calls and the Lunity engine.

  When `on_tick` runs, `Lunity.Mod.EventBus` sets `Process.put(:lunity_mod_tick, ...)`
  in the Lua task so `entity_get` / `entity_set` / `input_is_key_down` can target the
  active `Lunity.Instance` (`ComponentStore`) and `Lunity.Input.Session` bindings.

  Without that context, calls fall back to **editor** state (`Lunity.Editor.State`).
  """

  require Logger

  alias Lunity.ComponentStore
  alias Lunity.Components.Position
  alias Lunity.Input.{ControlBinding, Keyboard, Session}

  @doc """
  Get an entity property value (editor scene graph or ECS when mod tick context is set).
  """
  @spec entity_get(term(), String.t()) :: term()
  def entity_get(entity_id, property) do
    case Process.get(:lunity_mod_tick) do
      %{store_id: sid} when property == "position" ->
        eid = ecs_entity_id(entity_id)

        ComponentStore.with_store(sid, fn ->
          case Position.get(eid) do
            {x, y, z} -> [x * 1.0, y * 1.0, z * 1.0]
            _ -> nil
          end
        end)

      _ ->
        editor_entity_get(entity_id, property)
    end
  end

  defp editor_entity_get(entity_id, property) do
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
  Set an entity property (ECS position when mod tick context is set).
  """
  @spec entity_set(term(), String.t(), term()) :: :ok
  def entity_set(entity_id, "position", value) do
    case Process.get(:lunity_mod_tick) do
      %{store_id: sid} ->
        case decode_vec3(value) do
          {x, y, z} ->
            eid = ecs_entity_id(entity_id)

            ComponentStore.with_store(sid, fn ->
              Position.put(eid, {x, y, z})
            end)

          nil ->
            Logger.warning("entity_set position: could not decode vec3 from #{inspect(value)}")
        end

        :ok

      _ ->
        Logger.debug("entity_set: not in mod tick context; ignoring")
        :ok
    end
  end

  def entity_set(_entity_id, _property, _value), do: :ok

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
  Legacy single-arg key check (no entity binding). Always false.
  """
  @spec input_is_key_down(String.t()) :: boolean()
  def input_is_key_down(_key), do: false

  @doc """
  True if `key` is down for the input session bound to `entity_id` in this instance
  (`SessionMeta.entity_id` + `instance_id` match).
  """
  @spec input_is_key_down_for_entity(String.t(), String.t()) :: boolean()
  def input_is_key_down_for_entity(key, entity_id) when is_binary(key) and is_binary(entity_id) do
    case Process.get(:lunity_mod_tick) do
      %{sessions_by_entity: sm} ->
        case Map.get(sm, entity_id) do
          nil ->
            false

          session_id ->
            kb = Session.get_keyboard(session_id) || %Keyboard{}
            atom = ControlBinding.key_from_string(key)
            Keyboard.key_down?(kb, atom)
        end

      _ ->
        false
    end
  end

  def input_is_key_down_for_entity(_, _), do: false

  @doc """
  Semantic actions for this entity this tick (from WebSocket `actions` messages).
  Each item is a map with string keys, e.g. `%{"op" => "move", "dz" => 1.0}`.
  """
  @spec input_actions_for_entity(String.t()) :: [map()]
  def input_actions_for_entity(entity_id) when is_binary(entity_id) do
    case Process.get(:lunity_mod_tick) do
      %{sessions_by_entity: sm} ->
        case Map.get(sm, entity_id) do
          nil ->
            []

          session_id ->
            session_id
            |> Session.get_actions()
            |> Enum.filter(fn m ->
              e = Map.get(m, "entity") || Map.get(m, :entity)
              e == entity_id or to_string(e) == entity_id
            end)
        end

      _ ->
        []
    end
  end

  def input_actions_for_entity(_), do: []

  # -- Private ----------------------------------------------------------------

  defp ecs_entity_id(id) when is_atom(id), do: id
  defp ecs_entity_id(id) when is_binary(id), do: String.to_existing_atom(id)

  defp decode_vec3(v) when is_tuple(v) and tuple_size(v) == 3 do
    {a, b, c} = v
    {a * 1.0, b * 1.0, c * 1.0}
  end

  defp decode_vec3(v) when is_list(v) do
    cond do
      length(v) == 3 and Enum.all?(v, &is_number/1) ->
        [a, b, c] = v
        {a * 1.0, b * 1.0, c * 1.0}

      true ->
        nums =
          v
          |> Enum.flat_map(fn
            {k, val} when is_number(k) and is_number(val) -> [{round(k), val * 1.0}]
            _ -> []
          end)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(&elem(&1, 1))

        case nums do
          [a, b, c] -> {a, b, c}
          _ -> nil
        end
    end
  end

  defp decode_vec3(_), do: nil

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
