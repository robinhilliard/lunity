defmodule Lunity.Mod.RuntimeStage do
  @moduledoc """
  Manages the runtime stage of mod loading.

  Creates per-mod isolated luerl states with a curated engine API
  (`lunity.on`, `lunity.entity.*`, `lunity.scene.*`, `lunity.input.*`, `lunity.log`),
  executes each mod's `control.lua`, and wires event handlers to the EventBus.
  """

  require Logger

  alias Lunity.Mod.{Sandbox, EventBus}

  @doc """
  Initialize runtime states for all mods and execute their control.lua files.

  Each mod gets its own sandboxed luerl state with the `lunity.*` API injected.
  Event handlers registered via `lunity.on()` are forwarded to the EventBus.
  """
  @spec run([Lunity.Mod.mod_info()]) :: :ok | {:error, term()}
  def run(mods) do
    Enum.each(mods, fn mod ->
      control_path = Path.join(mod.dir, "control.lua")

      if File.exists?(control_path) do
        case init_runtime_state(mod) do
          {:ok, st} ->
            case :luerl.dofile(String.to_charlist(control_path), st) do
              {:ok, _result, final_st} ->
                EventBus.set_runtime_state(mod.name, final_st)

              {_result, final_st} when is_tuple(final_st) ->
                EventBus.set_runtime_state(mod.name, final_st)

              error ->
                Logger.warning("Mod #{mod.name}: error executing control.lua: #{inspect(error)}")
            end

          {:error, reason} ->
            Logger.warning("Mod #{mod.name}: failed to init runtime: #{inspect(reason)}")
        end
      end
    end)

    :ok
  rescue
    e -> {:error, {:runtime_error, Exception.message(e)}}
  end

  # -- Private ----------------------------------------------------------------

  defp init_runtime_state(mod) do
    st = Sandbox.new()
    st = inject_lunity_api(st, mod.name)
    {:ok, st}
  rescue
    e -> {:error, {:init_error, Exception.message(e)}}
  end

  defp inject_lunity_api(st, mod_name) do
    on_func = fn [event_name, handler], lua_st ->
      EventBus.register(mod_name, event_name, handler)
      {[], lua_st}
    end

    log_func = fn args, lua_st ->
      message = Enum.map_join(args, " ", &to_string/1)
      Logger.info("[Mod:#{mod_name}] #{message}")
      {[], lua_st}
    end

    entity_get_func = fn [entity_id, property], lua_st ->
      val = Lunity.Mod.RuntimeAPI.entity_get(entity_id, property)
      return_encoded(val, lua_st)
    end

    entity_set_func = fn [entity_id, property, value], lua_st ->
      decoded = :luerl.decode(value, lua_st)
      Lunity.Mod.RuntimeAPI.entity_set(entity_id, property, decoded)
      {[], lua_st}
    end

    entity_find_func = fn [entity_name], lua_st ->
      val = Lunity.Mod.RuntimeAPI.entity_find(entity_name)
      return_encoded(val, lua_st)
    end

    entity_spawn_func = fn [entity_name | rest], lua_st ->
      overrides = List.first(rest)
      val = Lunity.Mod.RuntimeAPI.entity_spawn(entity_name, overrides)
      return_encoded(val, lua_st)
    end

    entity_destroy_func = fn [entity_id], lua_st ->
      Lunity.Mod.RuntimeAPI.entity_destroy(entity_id)
      {[], lua_st}
    end

    scene_get_node_func = fn [name], lua_st ->
      val = Lunity.Mod.RuntimeAPI.scene_get_node(name)
      return_encoded(val, lua_st)
    end

    scene_set_node_position_func = fn [name, x, y, z], lua_st ->
      Lunity.Mod.RuntimeAPI.scene_set_node_position(name, x, y, z)
      {[], lua_st}
    end

    input_is_key_down_func = fn [key], lua_st ->
      val = Lunity.Mod.RuntimeAPI.input_is_key_down(to_string(key))
      return_encoded(val, lua_st)
    end

    # Fixed arity so :luerl.encode/2 accepts the Erlang fun (variadic `fn args, ...` breaks encode).
    input_is_key_down_for_entity_func = fn [key, entity_id], lua_st ->
      k = to_string(key)
      eid = entity_id_to_lua_string(entity_id)
      val = Lunity.Mod.RuntimeAPI.input_is_key_down_for_entity(k, eid)
      return_encoded(val, lua_st)
    end

    input_actions_for_entity_func = fn [entity_id], lua_st ->
      eid = entity_id_to_lua_string(entity_id)
      val = Lunity.Mod.RuntimeAPI.input_actions_for_entity(eid)
      return_encoded(val, lua_st)
    end

    init_lua = """
    lunity = {
      entity = {},
      scene = {},
      input = {}
    }
    """

    st =
      case :luerl.do(init_lua, st) do
        {:ok, _, new_st} -> new_st
        {_, new_st} -> new_st
      end

    st
    |> Sandbox.set_nested(["lunity", "on"], on_func)
    |> Sandbox.set_nested(["lunity", "log"], log_func)
    |> Sandbox.set_nested(["lunity", "entity", "get"], entity_get_func)
    |> Sandbox.set_nested(["lunity", "entity", "set"], entity_set_func)
    |> Sandbox.set_nested(["lunity", "entity", "find"], entity_find_func)
    |> Sandbox.set_nested(["lunity", "entity", "spawn"], entity_spawn_func)
    |> Sandbox.set_nested(["lunity", "entity", "destroy"], entity_destroy_func)
    |> Sandbox.set_nested(["lunity", "scene", "get_node"], scene_get_node_func)
    |> Sandbox.set_nested(["lunity", "scene", "set_node_position"], scene_set_node_position_func)
    |> Sandbox.set_nested(["lunity", "input", "is_key_down"], input_is_key_down_func)
    |> Sandbox.set_nested(
      ["lunity", "input", "is_key_down_for_entity"],
      input_is_key_down_for_entity_func
    )
    |> Sandbox.set_nested(
      ["lunity", "input", "actions_for_entity"],
      input_actions_for_entity_func
    )
  end

  # Erlang funs must return luerldata; raw lists/maps are not Lua tables (see luerl_emul:call_erlfunc/5).
  defp return_encoded(val, lua_st) do
    {enc, st} = :luerl.encode(val, lua_st)
    {[enc], st}
  end

  defp entity_id_to_lua_string(id) when is_binary(id), do: id
  defp entity_id_to_lua_string(id) when is_atom(id), do: Atom.to_string(id)
  defp entity_id_to_lua_string(id), do: to_string(id)
end
