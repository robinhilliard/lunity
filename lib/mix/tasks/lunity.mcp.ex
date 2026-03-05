defmodule Mix.Tasks.Lunity.Mcp do
  @shortdoc "Start the Lunity MCP server (stdio or HTTP transport)"
  @moduledoc """
  Starts the Lunity MCP server.

  ## HTTP (default) - stdio breaks due to group leader issues

  Stdio forces group leader changes that break wx/GL. Use HTTP instead.

  Run from your game project: `mix lunity.mcp` (or `mix lunity.mcp --http`)

  Cursor config (`.cursor/mcp.json`):

      {
        "mcpServers": {
          "lunity": {
            "url": "http://localhost:4111/sse"
          }
        }
      }

  Call the set_project tool first with cwd (and optional app) so scene_load
  and other tools know which game project to use.

  ## Stdio (broken) - use LUNITY_HTTP=0 or --stdio only if you know the risks

      {
        "mcpServers": {
          "lunity": {
            "command": "mix",
            "args": ["lunity.mcp", "--stdio"],
            "cwd": "/path/to/your_game"
          }
        }
      }

  - Run from your game project directory
  - ECSx and OpenGL context required for full tool functionality
  """
  use Mix.Task

  defp project_dir_from_args(args) do
    case Enum.find_index(args, &(&1 == "--project")) do
      nil -> System.get_env("LUNITY_PROJECT")
      idx -> Enum.at(args, idx + 1)
    end
  end

  @impl Mix.Task
  def run(args) do
    # Default HTTP: stdio breaks due to group leader issues (wx/GL)
    use_http = System.get_env("LUNITY_HTTP") != "0" and "--stdio" not in args

    # When running from lunity project, use LUNITY_PROJECT to target a game (e.g. pong)
    project_dir = project_dir_from_args(args)

    if project_dir do
      File.cd!(project_dir)
    end

    # Log to project dir
    log_file =
      case File.cwd() do
        {:ok, cwd} -> Path.join(cwd, "lunity_mcp.log")
        _ -> "/tmp/lunity_mcp.log"
      end

    log = fn msg ->
      try do
        File.write!(log_file, "[#{DateTime.utc_now()}] #{msg}\n", [:append])
      rescue
        _ -> :ok
      end
    end

    log.("Starting Lunity MCP...")

    # Headless mode: skip editor window (wx/GL often fails when Cursor spawns MCP subprocess).
    # Set LUNITY_HEADLESS=1 in MCP config env to use. Tools needing the editor will return errors.
    headless = System.get_env("LUNITY_HEADLESS") == "1"
    Application.put_env(:lunity, :mode, if(headless, do: :library, else: :editor))
    log.("headless=#{headless}")

    # Ensure we're in a Mix project
    Mix.Project.get!()
    log.("Mix project OK (cwd=#{File.cwd!()})")

    # Store project priv path so Lunity can resolve it when host app isn't loaded yet
    # (editor may run before pong finishes starting; Application.app_dir(:pong) would fail)
    # app_path is _build/dev/lib/pong; go up 4 levels to project root
    project_priv =
      Mix.Project.app_path()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> Path.dirname()
      |> then(&Path.join(&1, "priv"))

    Application.put_env(:lunity, :project_priv, project_priv)
    app = Mix.Project.get!().project()[:app]

    if app && app != :lunity do
      Application.put_env(:lunity, :project_app, app)
    end

    log.("project_priv=#{project_priv}")

    Application.put_env(:logger, :backends, [])
    Logger.configure(level: :warning)

    # Ensure host app's ebin is on the code path (needed for scene module resolution)
    app_ebin = Path.join(Mix.Project.app_path(), "ebin")
    Code.prepend_path(app_ebin)

    # Start the host project (e.g. pong) so scene_builders like Pong.SceneBuilder are available
    if app && app != :lunity do
      Application.ensure_all_started(app)
      log.("Host app #{app} started")
    end

    System.at_exit(fn reason ->
      try do
        File.write!(log_file, "[#{DateTime.utc_now()}] Process exiting: #{inspect(reason)}\n", [
          :append
        ])
      rescue
        _ -> :ok
      end
    end)

    {:ok, _} = Application.ensure_all_started(:lunity)
    log.("Lunity app started")

    # Start MCP server immediately so Cursor gets a response before timing out.
    log.(
      if(headless,
        do: "Starting MCP server (headless)...",
        else: "Starting MCP server (with editor)..."
      )
    )

    transport_opts =
      if use_http do
        port = System.get_env("LUNITY_HTTP_PORT", "4111") |> String.to_integer()
        log.("HTTP transport on port #{port}, SSE at http://localhost:#{port}/sse")
        [transport: :sse, port: port, sse_enabled: true]
      else
        log.("Stdio transport")
        [transport: :stdio]
      end

    case Lunity.MCP.Server.start_link(transport_opts) do
      {:ok, pid} ->
        log.("MCP server started (pid=#{inspect(pid)})")
        Process.sleep(:infinity)

      {:error, reason} ->
        log.("MCP server failed: #{inspect(reason)}")
        Mix.raise("Failed to start Lunity MCP server: #{inspect(reason)}")
    end
  rescue
    e ->
      log_file =
        case File.cwd() do
          {:ok, cwd} -> Path.join(cwd, "lunity_mcp.log")
          _ -> "lunity_mcp.log"
        end

      stack = Exception.format(:error, e, __STACKTRACE__)
      File.write!(log_file, "[#{DateTime.utc_now()}] CRASH: #{inspect(e)}\n#{stack}\n", [:append])
      reraise e, __STACKTRACE__
  end
end
