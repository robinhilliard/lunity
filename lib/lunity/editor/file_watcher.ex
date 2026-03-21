defmodule Lunity.Editor.FileWatcher do
  @moduledoc """
  Watches project files for changes and triggers scene reload in the editor.

  Monitors two kinds of source files:

  - **priv/** assets: `priv/config/`, `priv/scenes/`, `priv/prefabs/` for `.exs`
    config scripts and `.glb` assets. Changes trigger an immediate scene reload.

  - **lib/** modules: `.ex` files. Changes trigger a full `mix compile` so that
    cross-file dependencies are resolved correctly, then a scene reload.

  Debounces rapid changes (editors often write multiple times in quick succession)
  with a 300ms window. If compilation fails, the scene reload is skipped --
  the old working code stays loaded (BEAM semantics) and game state is preserved.
  Tracks the last known scene path independently so that recovery works after
  the error is fixed and the next successful compile triggers a reload.
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
      cond do
        String.ends_with?(path, ".ex") ->
          %{state | pending_recompiles: MapSet.put(state.pending_recompiles, path)}

        true ->
          %{state | asset_changed: true}
      end

    state = schedule_reload(state)
    {:noreply, state}
  end

  def handle_info({:file_event, _watcher, :stop}, state) do
    {:noreply, state}
  end

  def handle_info(:do_reload, state) do
    has_code_changes = MapSet.size(state.pending_recompiles) > 0
    compile_ok = if has_code_changes, do: recompile_project(), else: true

    # Only reload the scene when assets changed (.exs configs, .glb models).
    # Code-only changes are already hot-loaded by the compiler -- systems pick
    # up new module code on the next tick without needing a scene rebuild.
    state =
      if compile_ok and state.asset_changed do
        reload_current_scene(state)
      else
        state
      end

    {:noreply,
     %{state | debounce_ref: nil, pending_recompiles: MapSet.new(), asset_changed: false}}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp initial_state do
    %{
      watcher: nil,
      debounce_ref: nil,
      last_scene_path: nil,
      pending_recompiles: MapSet.new(),
      asset_changed: false
    }
  end

  defp schedule_reload(%{debounce_ref: ref} = state) do
    if ref, do: Process.cancel_timer(ref)
    new_ref = Process.send_after(self(), :do_reload, @debounce_ms)
    %{state | debounce_ref: new_ref}
  end

  defp recompile_project do
    case Mix.Task.rerun("compile", ["--no-protocol-consolidation"]) do
      {:ok, _diagnostics} ->
        Logger.info("FileWatcher: recompiled successfully")
        true

      {:error, diagnostics} ->
        errors =
          diagnostics
          |> Enum.filter(&(&1.severity == :error))
          |> Enum.map_join("\n  ", &format_diagnostic/1)

        Logger.warning("FileWatcher: compile failed, scene reload skipped\n  #{errors}")
        false

      {:noop, _diagnostics} ->
        true
    end
  end

  defp format_diagnostic(%{file: file, position: pos, message: msg}) do
    loc = if pos, do: ":#{format_position(pos)}", else: ""
    "#{Path.relative_to_cwd(file || "unknown")}#{loc} #{msg}"
  end

  defp format_diagnostic(%{message: msg}), do: msg

  defp format_position({line, col}), do: "#{line}:#{col}"
  defp format_position(line) when is_integer(line), do: "#{line}"
  defp format_position(other), do: "#{inspect(other)}"

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
      {cwd, _} when is_binary(cwd) ->
        cwd

      _ ->
        Application.get_env(:lunity, :project_priv)
        |> then(fn
          nil ->
            case File.cwd() do
              {:ok, cwd} -> cwd
              _ -> nil
            end

          priv ->
            Path.dirname(priv)
        end)
    end
  end
end
