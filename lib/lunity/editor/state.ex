defmodule Lunity.Editor.State do
  @moduledoc """
  ETS-backed editor state. Shared between the editor view (GL thread) and MCP tools.

  Keys:
  - `:scene` - Current EAGL.Scene (or nil)
  - `:scene_path` - Path that was loaded
  - `:entities` - [{node, entity_id}, ...] from SceneLoader
  - `:load_command` - `{:load_scene, path}` when MCP requests a load
  - `:load_result` - `{:ok, ...}` or `{:error, reason}` after load attempt
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

  @doc "Set the current scene and related state."
  def set_scene(scene, path, entities) do
    :ets.insert(@table, {:scene, scene})
    :ets.insert(@table, {:scene_path, path})
    :ets.insert(@table, {:entities, entities})
    :ok
  end

  @doc "Clear the scene (e.g. on load error)."
  def clear_scene do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _ ->
        :ets.delete(@table, :scene)
        :ets.delete(@table, :scene_path)
        :ets.delete(@table, :entities)
        :ok
    end
  end

  @doc "Get the path of the loaded scene."
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

  @doc "Take and clear the load command. Returns the command or nil."
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
end
