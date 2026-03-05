defmodule Lunity.Editor.FileWatcher do
  @moduledoc """
  Watches project files for changes and triggers scene reload in the editor.

  Monitors two kinds of source files:

  - **priv/** assets: `priv/config/`, `priv/scenes/`, `priv/prefabs/` for `.exs`
    config scripts and `.glb` assets. Changes trigger an immediate scene reload.

  - **lib/** modules: Scene, Entity, and Prefab `.ex` files. Changes trigger
    recompilation via `Code.compile_file/1` to hot-load the new module, then
    a scene reload so the editor reflects the updated definition.

  Debounces rapid changes (editors often write multiple times in quick succession)
  with a 300ms window. Tracks the last known scene path independently so that
  recovery works after load errors (e.g. syntax errors that clear the scene).
  """
  use GenServer
  require Logger

  alias Lunity.Editor.State

  @debounce_ms 300

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    priv_dir = resolve_priv_dir(opts)
    lib_dir = resolve_lib_dir(opts)

    priv_dirs =
      ["config", "scenes", "prefabs"]
      |> Enum.map(&Path.join(priv_dir, &1))
      |> Enum.filter(&File.dir?/1)

    lib_dirs = if lib_dir && File.dir?(lib_dir), do: [lib_dir], else: []
    dirs = priv_dirs ++ lib_dirs

    if dirs == [] do
      {:ok, initial_state()}
    else
      case FileSystem.start_link(dirs: dirs) do
        {:ok, watcher_pid} ->
          FileSystem.subscribe(watcher_pid)
          {:ok, %{initial_state() | watcher: watcher_pid}}

        other ->
          Logger.warning(
            "FileWatcher: could not start file watcher (#{inspect(other)}). " <>
              "Auto-reload disabled. On Linux, install inotify-tools: sudo apt install inotify-tools"
          )

          {:ok, initial_state()}
      end
    end
  end

  @impl true
  def handle_info({:file_event, _watcher, {path, _events}}, state) do
    state =
      if String.ends_with?(path, ".ex") do
        %{state | pending_recompiles: MapSet.put(state.pending_recompiles, path)}
      else
        state
      end

    state = schedule_reload(state)
    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, :stop}, state) do
    {:noreply, state}
  end

  def handle_info(:do_reload, state) do
    recompile_pending(state.pending_recompiles)
    state = reload_current_scene(state)
    {:noreply, %{state | debounce_ref: nil, pending_recompiles: MapSet.new()}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp initial_state do
    %{watcher: nil, debounce_ref: nil, last_scene_path: nil, pending_recompiles: MapSet.new()}
  end

  defp schedule_reload(%{debounce_ref: ref} = state) do
    if ref, do: Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :do_reload, @debounce_ms)
    %{state | debounce_ref: new_ref}
  end

  defp recompile_pending(files) do
    if MapSet.size(files) > 0 do
      prev = Code.compiler_options(ignore_module_conflict: true)

      Enum.each(files, fn path ->
        try do
          Code.compile_file(path)
          Logger.info("FileWatcher: recompiled #{Path.relative_to_cwd(path)}")
        rescue
          e ->
            Logger.warning(
              "FileWatcher: compile error in #{Path.relative_to_cwd(path)}: #{Exception.message(e)}"
            )
        end
      end)

      Code.compiler_options(ignore_module_conflict: prev[:ignore_module_conflict] || false)
    end
  end

  defp reload_current_scene(state) do
    path = State.get_scene_path() || state.last_scene_path

    case path do
      nil ->
        state

      path ->
        current_orbit = State.get_orbit()
        if current_orbit, do: State.put_orbit_after_load(current_orbit)

        case State.get_project_context() do
          {cwd, app} -> State.put_load_command(path, cwd, app)
          nil -> State.put_load_command(path)
        end

        %{state | last_scene_path: path}
    end
  end

  defp resolve_priv_dir(opts) do
    cond do
      dir = opts[:priv_dir] ->
        dir

      true ->
        case State.get_project_context() do
          {cwd, app} when is_binary(cwd) and is_atom(app) and app != nil ->
            Path.join([cwd, "_build/dev/lib/#{app}/priv"])
            |> then(fn build_priv ->
              if File.dir?(build_priv), do: build_priv, else: Path.join(cwd, "priv")
            end)

          {cwd, _} when is_binary(cwd) ->
            Path.join(cwd, "priv")

          _ ->
            app = Lunity.project_app()
            Lunity.priv_dir_for_app(app)
        end
    end
  end

  defp resolve_lib_dir(opts) do
    cond do
      dir = opts[:lib_dir] ->
        dir

      true ->
        project_root = resolve_project_root()
        if project_root, do: Path.join(project_root, "lib")
    end
  end

  defp resolve_project_root do
    case State.get_project_context() do
      {cwd, _} when is_binary(cwd) -> cwd
      _ -> Application.get_env(:lunity, :project_priv) |> then(fn
        nil -> case File.cwd() do {:ok, cwd} -> cwd; _ -> nil end
        priv -> Path.dirname(priv)
      end)
    end
  end
end
