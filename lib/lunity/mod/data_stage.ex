defmodule Lunity.Mod.DataStage do
  @moduledoc """
  Manages the data stage of mod loading.

  Creates a shared luerl state, injects the `data` API (scenes, prefabs, entities
  tables and `data:extend()`), executes each mod's data files in dependency order,
  and reads the final tables back into Elixir structs.

  ## Execution order

  For each mod in topological order:
  1. `data.lua` - initial prototype definitions
  2. `data-updates.lua` - modifications to existing prototypes
  3. `data-final-fixes.lua` - final adjustments
  """

  require Logger

  alias Lunity.Mod.Sandbox
  alias Lunity.Scene.{Def, NodeDef}

  @data_files ["data.lua", "data-updates.lua", "data-final-fixes.lua"]

  @doc """
  Run the data stage for a list of mods (already sorted by dependency order).

  Returns `{:ok, %{scenes: ..., prefabs: ..., entities: ...}}` or `{:error, reason}`.
  """
  @spec run([Lunity.Mod.mod_info()]) ::
          {:ok, %{scenes: map(), prefabs: map(), entities: map()}} | {:error, term()}
  def run(mods) do
    st = init_data_state(mods)

    case execute_all_mods(st, mods) do
      {:ok, final_st} ->
        read_data_tables(final_st)

      {:error, _} = err ->
        err
    end
  end

  # -- State initialization ---------------------------------------------------

  defp init_data_state(mods) do
    st = Sandbox.new()

    init_lua = """
    data = {
      scenes = {},
      prefabs = {},
      entities = {}
    }

    function data:extend(prototypes)
      for _, proto in ipairs(prototypes) do
        local ptype = proto.type
        if ptype == "scene" then
          self.scenes[proto.name] = proto
        elseif ptype == "prefab" then
          self.prefabs[proto.name] = proto
        elseif ptype == "entity" then
          self.entities[proto.name] = proto
        end
      end
    end

    mods = {}
    """

    st = luerl_do!(init_lua, st)

    Enum.reduce(mods, st, fn mod, acc ->
      set_lua = "mods[\"#{escape_lua_string(mod.name)}\"] = \"#{escape_lua_string(mod.version)}\""
      luerl_do!(set_lua, acc)
    end)
  end

  # -- Mod execution ----------------------------------------------------------

  defp execute_all_mods(st, mods) do
    Enum.reduce_while(mods, {:ok, st}, fn mod, {:ok, acc_st} ->
      case execute_mod_data_files(acc_st, mod) do
        {:ok, new_st} -> {:cont, {:ok, new_st}}
        {:error, reason} -> {:halt, {:error, {mod.name, reason}}}
      end
    end)
  end

  defp execute_mod_data_files(st, mod) do
    Enum.reduce_while(@data_files, {:ok, st}, fn file, {:ok, acc_st} ->
      path = Path.join(mod.dir, file)

      if File.exists?(path) do
        case :luerl.dofile(String.to_charlist(path), acc_st) do
          {:ok, _result, new_st} ->
            {:cont, {:ok, new_st}}

          {_result, new_st} when is_tuple(new_st) ->
            {:cont, {:ok, new_st}}

          error ->
            Logger.warning("Mod #{mod.name}: error executing #{file}: #{inspect(error)}")
            {:halt, {:error, {:lua_error, file, error}}}
        end
      else
        {:cont, {:ok, acc_st}}
      end
    end)
  rescue
    e ->
      {:error, {:lua_exception, Exception.message(e)}}
  catch
    kind, reason ->
      {:error, {:lua_exception, {kind, reason}}}
  end

  # -- Reading data back to Elixir --------------------------------------------

  @doc false
  def read_data_tables(st) do
    scenes = read_typed_table(st, "scenes", &lua_table_to_scene_def/1)
    prefabs = read_typed_table(st, "prefabs", &lua_table_to_prefab/1)
    entities = read_typed_table(st, "entities", &lua_table_to_entity/1)

    {:ok, %{scenes: scenes, prefabs: prefabs, entities: entities}}
  rescue
    e -> {:error, {:read_error, Exception.message(e)}}
  end

  defp luerl_do!(lua_code, st) do
    case :luerl.do(lua_code, st) do
      {:ok, _result, new_st} -> new_st
      {_result, new_st} -> new_st
    end
  end

  defp read_typed_table(st, key, converter) do
    lua_code = "return data.#{key}"

    val =
      case :luerl.do_dec(lua_code, st) do
        {:ok, [v], _st} -> v
        _ -> nil
      end

    case val do
      nil ->
        %{}

      table when is_list(table) ->
        table
        |> Enum.filter(fn {_k, v} -> is_list(v) end)
        |> Map.new(fn {k, v} ->
          props = kv_to_map(v)
          {k, converter.(props)}
        end)

      _ ->
        %{}
    end
  end

  @doc false
  def lua_table_to_scene_def(props) do
    nodes = Map.get(props, "nodes", [])

    node_defs =
      case nodes do
        list when is_list(list) ->
          list
          |> Enum.filter(fn {_k, v} -> is_list(v) end)
          |> Enum.sort_by(fn {k, _v} -> lua_key_to_int(k) end)
          |> Enum.map(fn {_k, v} -> lua_table_to_node_def(kv_to_map(v)) end)

        _ ->
          []
      end

    %Def{nodes: node_defs}
  end

  @doc false
  def lua_table_to_node_def(props) do
    children =
      case Map.get(props, "children") do
        list when is_list(list) ->
          list
          |> Enum.filter(fn {_k, v} -> is_list(v) end)
          |> Enum.sort_by(fn {k, _v} -> lua_key_to_int(k) end)
          |> Enum.map(fn {_k, v} -> lua_table_to_node_def(kv_to_map(v)) end)

        _ ->
          []
      end

    %NodeDef{
      name: lua_to_atom(Map.get(props, "name")),
      prefab: Map.get(props, "prefab"),
      entity: resolve_entity_ref(Map.get(props, "entity")),
      scene: resolve_scene_ref(Map.get(props, "scene")),
      config: Map.get(props, "config"),
      properties: lua_to_properties(Map.get(props, "properties")),
      material: lua_to_material(Map.get(props, "material")),
      light: lua_to_light(Map.get(props, "light")),
      position: lua_to_vec3(Map.get(props, "position")),
      scale: lua_to_vec3(Map.get(props, "scale")),
      rotation: lua_to_quat(Map.get(props, "rotation")),
      children: children
    }
  end

  @doc false
  def lua_table_to_prefab(props) do
    %{
      name: Map.get(props, "name"),
      glb: Map.get(props, "glb"),
      source_mod: Map.get(props, "source_mod"),
      properties: lua_to_property_defs(Map.get(props, "properties"))
    }
  end

  @doc false
  def lua_table_to_entity(props) do
    components =
      case Map.get(props, "components") do
        list when is_list(list) ->
          list
          |> Enum.filter(fn {_k, v} -> is_binary(v) end)
          |> Enum.sort_by(fn {k, _v} -> lua_key_to_int(k) end)
          |> Enum.map(fn {_k, v} -> v end)

        _ ->
          []
      end

    %{
      name: Map.get(props, "name"),
      properties: lua_to_property_defs(Map.get(props, "properties")),
      components: components
    }
  end

  # -- Lua value converters ---------------------------------------------------

  defp kv_to_map(list) when is_list(list), do: Map.new(list)
  defp kv_to_map(other), do: other

  defp lua_to_atom(nil), do: nil

  defp lua_to_atom(str) when is_binary(str) do
    String.to_atom(str)
  end

  defp lua_to_atom(_), do: nil

  defp lua_to_vec3(nil), do: nil

  defp lua_to_vec3(list) when is_list(list) do
    nums =
      list
      |> Enum.sort_by(fn {k, _v} -> lua_key_to_int(k) end)
      |> Enum.map(fn {_k, v} -> to_number(v) end)

    case nums do
      [x, y, z] -> {x, y, z}
      _ -> nil
    end
  end

  defp lua_to_vec3(_), do: nil

  defp lua_to_quat(nil), do: nil

  defp lua_to_quat(list) when is_list(list) do
    nums =
      list
      |> Enum.sort_by(fn {k, _v} -> lua_key_to_int(k) end)
      |> Enum.map(fn {_k, v} -> to_number(v) end)

    case nums do
      [x, y, z, w] -> {x, y, z, w}
      _ -> nil
    end
  end

  defp lua_to_quat(_), do: nil

  defp lua_to_properties(nil), do: nil

  defp lua_to_properties(list) when is_list(list) do
    deep_lua_to_elixir(list)
  end

  defp lua_to_properties(_), do: nil

  defp lua_to_material(nil), do: nil

  defp lua_to_material(list) when is_list(list) do
    map = deep_lua_to_elixir(list)
    if is_map(map), do: Lunity.Material.from_map(map), else: nil
  end

  defp lua_to_material(_), do: nil

  defp lua_to_light(nil), do: nil

  defp lua_to_light(list) when is_list(list) do
    map = deep_lua_to_elixir(list)
    if is_map(map), do: Lunity.Light.from_map(map), else: nil
  end

  defp lua_to_light(_), do: nil

  defp lua_to_property_defs(nil), do: %{}

  defp lua_to_property_defs(list) when is_list(list) do
    list
    |> Enum.filter(fn {_k, v} -> is_list(v) end)
    |> Map.new(fn {k, v} -> {k, kv_to_map(v)} end)
  end

  defp lua_to_property_defs(_), do: %{}

  defp resolve_entity_ref(nil), do: nil
  defp resolve_entity_ref(name) when is_binary(name), do: name
  defp resolve_entity_ref(_), do: nil

  defp resolve_scene_ref(nil), do: nil
  defp resolve_scene_ref(name) when is_binary(name), do: name
  defp resolve_scene_ref(_), do: nil

  defp to_number(n) when is_number(n), do: n * 1.0
  defp to_number(_), do: 0.0

  defp lua_key_to_int(k) when is_number(k), do: trunc(k)
  defp lua_key_to_int(k) when is_binary(k), do: String.to_integer(k)
  defp lua_key_to_int(_), do: 0

  defp deep_lua_to_elixir(list) when is_list(list) do
    if sequential_table?(list) do
      list
      |> Enum.sort_by(fn {k, _} -> lua_key_to_int(k) end)
      |> Enum.map(fn {_k, v} -> deep_lua_to_elixir_val(v) end)
    else
      Map.new(list, fn {k, v} -> {to_string(k), deep_lua_to_elixir_val(v)} end)
    end
  end

  defp deep_lua_to_elixir(other), do: other

  defp deep_lua_to_elixir_val(list) when is_list(list), do: deep_lua_to_elixir(list)
  defp deep_lua_to_elixir_val(val), do: val

  defp sequential_table?(list) do
    keys = Enum.map(list, fn {k, _} -> k end)
    Enum.all?(keys, &is_number/1)
  end

  defp escape_lua_string(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end
end
