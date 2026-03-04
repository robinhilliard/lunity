defmodule Lunity.Editor.State do
  @moduledoc """
  ETS-backed editor state. Shared between the editor view (GL thread) and MCP tools.

  Keys:
  - `:scene` - Current EAGL.Scene (or nil)
  - `:scene_path` - Path that was loaded (scene path or prefab id)
  - `:context_type` - `:scene` or `:prefab`
  - `:entities` - [{node, entity_id}, ...] from SceneLoader
  - `:orbit` - Current EAGL.OrbitCamera (written by View each frame)
  - `:orbit_command` - `{:set_orbit, orbit}` when MCP wants to change camera
  - `:orbit_after_load` - orbit to apply after next load completes (used by context_pop)
  - `:load_command` - `{:load_scene, path}` or `{:load_prefab, id}` when MCP requests a load
  - `:load_result` - `{:ok, ...}` or `{:error, reason}` after load attempt
  - `:context_stack` - Stack of `%{type: type, path: path, orbit: orbit}` for push/pop
  - `:viewport` - `{width, height}` of the main view (written by View each frame)
  - `:capture_request` - `{:capture, view_id}` when MCP requests screenshot
  - `:capture_result` - `{:ok, base64_png}` or `{:error, reason}` after capture
  - `:pick_request` - `{:pick, x, y}` when MCP requests entity_at_screen
  - `:pick_result` - `{:ok, node, entity_id}` or `nil` after pick
  - `:game_paused` - boolean for pause/step/resume
  - `:annotations` - list of overlay shapes for view_annotate
  - `:highlight_node` - `{node_id, duration_ms, expires_at}` for highlight_node
  """
  @table :lunity_editor_state

  @doc "Create the ETS table. Call once at editor startup."
  def init do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :public, :set])
        :ok

      _ ->
        :ok
    end
  end

  @doc "Get the current scene."
  def get_scene do
    case :ets.lookup(@table, :scene) do
      [{:scene, scene}] -> scene
      [] -> nil
    end
  end

  @doc "Set the current scene and related state. Type is :scene or :prefab."
  def set_scene(scene, path, entities, type \\ :scene) do
    :ets.insert(@table, {:scene, scene})
    :ets.insert(@table, {:scene_path, path})
    :ets.insert(@table, {:context_type, type})
    :ets.insert(@table, {:entities, entities})
    :ok
  end

  @doc "Get the current context type (:scene or :prefab)."
  def get_context_type do
    case :ets.lookup(@table, :context_type) do
      [{:context_type, type}] -> type
      [] -> :scene
    end
  end

  @doc "Clear the scene (e.g. on load error)."
  def clear_scene do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      _ ->
        :ets.delete(@table, :scene)
        :ets.delete(@table, :scene_path)
        :ets.delete(@table, :context_type)
        :ets.delete(@table, :entities)
        :ok
    end
  end

  @doc "Get entities from the loaded scene. Returns [{node, entity_id}, ...] or []."
  def get_entities do
    case :ets.lookup(@table, :entities) do
      [{:entities, entities}] -> entities
      [] -> []
    end
  end

  @doc "Get the path of the loaded scene or prefab id."
  def get_scene_path do
    case :ets.lookup(@table, :scene_path) do
      [{:scene_path, path}] -> path
      [] -> nil
    end
  end

  @doc "Queue a scene load. The editor view will process this on the next frame."
  def put_load_command(path) do
    :ets.insert(@table, {:load_command, {:load_scene, path}})
    :ok
  end

  @doc "Queue a prefab load for inspection. The editor view will process this on the next frame."
  def put_load_prefab_command(id) do
    :ets.insert(@table, {:load_command, {:load_prefab, id}})
    :ok
  end

  @doc "Take and clear the load command. Returns {:load_scene, path} or {:load_prefab, id} or nil."
  def take_load_command do
    case :ets.lookup(@table, :load_command) do
      [{:load_command, cmd}] ->
        :ets.delete(@table, :load_command)
        cmd

      [] ->
        nil
    end
  end

  @doc "Store the result of a load attempt (for MCP to read)."
  def put_load_result(result) do
    :ets.insert(@table, {:load_result, result})
    :ok
  end

  @doc "Take the load result. Returns the result or nil."
  def take_load_result do
    case :ets.lookup(@table, :load_result) do
      [{:load_result, result}] ->
        :ets.delete(@table, :load_result)
        result

      [] ->
        nil
    end
  end

  # Orbit camera state (View writes each frame; MCP reads)
  @doc "Get the current orbit camera state. Nil before first frame."
  def get_orbit do
    case :ets.lookup(@table, :orbit) do
      [{:orbit, orbit}] -> orbit
      [] -> nil
    end
  end

  @doc "Store orbit state. Called by View each frame."
  def put_orbit(orbit) do
    :ets.insert(@table, {:orbit, orbit})
    :ok
  end

  @doc "Queue orbit change. View applies on next frame."
  def put_orbit_command(orbit) do
    :ets.insert(@table, {:orbit_command, {:set_orbit, orbit}})
    :ok
  end

  @doc "Take and clear orbit command. Returns {:set_orbit, orbit} or nil."
  def take_orbit_command do
    case :ets.lookup(@table, :orbit_command) do
      [{:orbit_command, cmd}] ->
        :ets.delete(@table, :orbit_command)
        cmd

      [] ->
        nil
    end
  end

  @doc "Set orbit to apply after next load completes (used by context_pop)."
  def put_orbit_after_load(orbit) do
    :ets.insert(@table, {:orbit_after_load, orbit})
    :ok
  end

  @doc "Take orbit to apply after load. Returns orbit or nil."
  def take_orbit_after_load do
    case :ets.lookup(@table, :orbit_after_load) do
      [{:orbit_after_load, orbit}] ->
        :ets.delete(@table, :orbit_after_load)
        orbit

      [] ->
        nil
    end
  end

  # Context stack for push/pop (6c)
  @doc "Push current context onto stack. Returns :ok or {:error, :no_scene} if nothing loaded."
  def context_push do
    case {get_scene(), get_scene_path(), get_context_type(), get_orbit()} do
      {nil, _, _, _} ->
        {:error, :no_scene}

      {_scene, path, type, orbit} when path != nil ->
        entry = %{type: type, path: path, orbit: orbit}
        stack = (get_context_stack() || []) ++ [entry]
        :ets.insert(@table, {:context_stack, stack})
        :ok
    end
  end

  @doc "Pop context from stack and restore (load scene/prefab + apply orbit). Returns :ok or {:error, :empty_stack}."
  def context_pop do
    case get_context_stack() do
      [] ->
        {:error, :empty_stack}

      [entry | rest] ->
        :ets.insert(@table, {:context_stack, rest})

        case entry.type do
          :scene -> put_load_command(entry.path)
          :prefab -> put_load_prefab_command(entry.path)
        end

        if entry.orbit, do: put_orbit_after_load(entry.orbit)
        {:ok, entry}
    end
  end

  @doc "Peek at stack without popping. Returns list of entries or []."
  def context_peek do
    get_context_stack() || []
  end

  defp get_context_stack do
    case :ets.lookup(@table, :context_stack) do
      [{:context_stack, stack}] -> stack
      [] -> []
    end
  end

  @doc "Get current context for MCP. Returns %{type: type, path: path, orbit: orbit} or nil."
  def get_context do
    case {get_scene_path(), get_context_type(), get_orbit()} do
      {nil, _, _} -> nil
      {path, type, orbit} -> %{type: type, path: path, orbit: orbit}
    end
  end

  @doc "Clear the context stack. Used for testing."
  def clear_context_stack do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ -> :ets.delete(@table, :context_stack)
    end

    :ok
  end

  @doc "Set context (load scene or prefab). Use put_load_command or put_load_prefab_command."
  def set_context(type, path) when type in [:scene, :prefab] do
    case type do
      :scene -> put_load_command(path)
      :prefab -> put_load_prefab_command(path)
    end
  end

  # Phase 6d: Viewport (View writes each frame)
  @doc "Store viewport dimensions. Called by View each frame."
  def put_viewport(width, height) do
    :ets.insert(@table, {:viewport, {width, height}})
    :ok
  end

  @doc "Get viewport. Returns {width, height} or nil."
  def get_viewport do
    case :ets.lookup(@table, :viewport) do
      [{:viewport, vp}] -> vp
      [] -> nil
    end
  end

  # Phase 6d: View capture (MCP requests, View performs on GL thread)
  @doc "Request a view capture. View processes on next frame."
  def put_capture_request(view_id \\ "main") do
    :ets.insert(@table, {:capture_request, {:capture, view_id}})
    :ok
  end

  @doc "Take and clear capture request. Returns {:capture, view_id} or nil."
  def take_capture_request do
    case :ets.lookup(@table, :capture_request) do
      [{:capture_request, req}] ->
        :ets.delete(@table, :capture_request)
        req

      [] ->
        nil
    end
  end

  @doc "Store capture result for MCP to read."
  def put_capture_result(result) do
    :ets.insert(@table, {:capture_result, result})
    :ok
  end

  @doc "Take capture result. Returns result or nil."
  def take_capture_result do
    case :ets.lookup(@table, :capture_result) do
      [{:capture_result, result}] ->
        :ets.delete(@table, :capture_result)
        result

      [] ->
        nil
    end
  end

  # Phase 6d: Pick (MCP requests, View performs on GL thread)
  @doc "Request a pick at screen coordinates. View processes on next frame."
  def put_pick_request(x, y) when is_number(x) and is_number(y) do
    :ets.insert(@table, {:pick_request, {:pick, trunc(x), trunc(y)}})
    :ok
  end

  @doc "Take and clear pick request. Returns {:pick, x, y} or nil."
  def take_pick_request do
    case :ets.lookup(@table, :pick_request) do
      [{:pick_request, req}] ->
        :ets.delete(@table, :pick_request)
        req

      [] ->
        nil
    end
  end

  @doc "Store pick result for MCP to read."
  def put_pick_result(result) do
    :ets.insert(@table, {:pick_result, result})
    :ok
  end

  @doc "Take pick result. Returns result or nil."
  def take_pick_result do
    case :ets.lookup(@table, :pick_result) do
      [{:pick_result, result}] ->
        :ets.delete(@table, :pick_result)
        result

      [] ->
        nil
    end
  end

  # Phase 6d: Pause/step/resume (game loop control)
  @doc "Get whether game is paused."
  def get_game_paused do
    case :ets.lookup(@table, :game_paused) do
      [{:game_paused, paused}] -> paused
      [] -> false
    end
  end

  @doc "Set game paused state."
  def put_game_paused(paused) when is_boolean(paused) do
    :ets.insert(@table, {:game_paused, paused})
    :ok
  end

  @doc "Request a single step (when paused). Cleared after one tick."
  def put_step_request do
    :ets.insert(@table, {:step_request, true})
    :ok
  end

  @doc "Take step request. Returns true if step was requested."
  def take_step_request do
    case :ets.lookup(@table, :step_request) do
      [{:step_request, _}] ->
        :ets.delete(@table, :step_request)
        true

      [] ->
        false
    end
  end

  # Phase 6d: Annotations and highlights (overlay rendering)
  @doc "Add annotation shapes. Each is %{type: :rect|:circle|:text, ...}."
  def add_annotations(shapes) when is_list(shapes) do
    current = get_annotations() || []
    :ets.insert(@table, {:annotations, current ++ shapes})
    :ok
  end

  @doc "Get annotations list."
  def get_annotations do
    case :ets.lookup(@table, :annotations) do
      [{:annotations, list}] -> list
      [] -> []
    end
  end

  @doc "Clear all annotations."
  def clear_annotations do
    :ets.delete(@table, :annotations)
    :ok
  end

  @doc "Set highlight target. entity_id when available, else node_name. Duration in ms."
  def put_highlight(entity_id_or_name, duration_ms) when is_integer(duration_ms) do
    expires = System.monotonic_time(:millisecond) + duration_ms
    :ets.insert(@table, {:highlight, {entity_id_or_name, expires}})
    :ok
  end

  @doc "Get current highlight if not expired."
  def get_highlight do
    case :ets.lookup(@table, :highlight) do
      [{:highlight, {target, expires}}] ->
        if System.monotonic_time(:millisecond) < expires do
          {target, expires}
        else
          :ets.delete(@table, :highlight)
          nil
        end

      [] ->
        nil
    end
  end

  @doc "Clear highlight."
  def clear_highlight do
    :ets.delete(@table, :highlight)
    :ok
  end
end
