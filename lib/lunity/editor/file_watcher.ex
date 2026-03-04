defmodule Lunity.Editor.FileWatcher do
  @moduledoc """
  Watches `priv/` directories for changes and triggers scene reload in the editor.

  Monitors `priv/config/`, `priv/scenes/`, and `priv/prefabs/` for file changes.
  When a change is detected, queues a reload of the current scene via Editor.State,
  preserving the current camera position.

  Tracks the last known scene path independently so that recovery works after
  load errors (e.g. syntax errors in .exs files that clear the scene).

  Debounces rapid changes (editors often write multiple times in quick succession)
  with a 300ms window.
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

    dirs =
      ["config", "scenes", "prefabs"]
      |> Enum.map(&Path.join(priv_dir, &1))
      |> Enum.filter(&File.dir?/1)

    if dirs == [] do
      {:ok, %{watcher: nil, debounce_ref: nil, last_scene_path: nil}}
    else
      case FileSystem.start_link(dirs: dirs) do
        {:ok, watcher_pid} ->
          FileSystem.subscribe(watcher_pid)
          {:ok, %{watcher: watcher_pid, debounce_ref: nil, last_scene_path: nil}}

        other ->
          Logger.warning("FileWatcher: could not start file watcher (#{inspect(other)}). " <>
            "Auto-reload disabled. On Linux, install inotify-tools: sudo apt install inotify-tools")
          {:ok, %{watcher: nil, debounce_ref: nil, last_scene_path: nil}}
      end
    end
  end

  @impl true
  def handle_info({:file_event, _watcher, {_path, _events}}, state) do
    state = schedule_reload(state)
    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, :stop}, state) do
    {:noreply, state}
  end

  def handle_info(:do_reload, state) do
    state = reload_current_scene(state)
    {:noreply, %{state | debounce_ref: nil}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp schedule_reload(%{debounce_ref: ref} = state) do
    if ref, do: Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :do_reload, @debounce_ms)
    %{state | debounce_ref: new_ref}
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
end
