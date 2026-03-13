defmodule Mix.Tasks.Lunity.Edit do
  @shortdoc "Start the Lunity editor with MCP server (Phoenix HTTP or stdio transport)"
  @moduledoc """
  Starts the Lunity editor and MCP server.

  ## HTTP via Phoenix (default) - stdio breaks due to group leader issues

  Stdio forces group leader changes that break wx/GL. Use HTTP instead.
  MCP is served via ExMCP.HttpPlug mounted in a Phoenix endpoint.

  Run from your game project: `mix lunity.edit` (or `mix lunity.edit --http`)

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
            "args": ["lunity.edit", "--stdio"],
            "cwd": "/path/to/your_game"
          }
        }
      }

  - Run from your game project directory
  - OpenGL context required for full tool functionality
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
    if :os.type() == {:unix, :darwin} do
      :os.cmd(~c"defaults write beam.smp NSRequiresAquaSystemAppearance -bool true")
    end

    use_http = System.get_env("LUNITY_HTTP") != "0" and "--stdio" not in args

    project_dir = project_dir_from_args(args)

    if project_dir do
      File.cd!(project_dir)
    end

    log_file =
      case File.cwd() do
        {:ok, cwd} ->
          dir = Path.join(cwd, "tmp")
          File.mkdir_p(dir)
          Path.join(dir, "lunity_edit.log")

        _ ->
          "/tmp/lunity_edit.log"
      end

    log = fn msg ->
      try do
        File.write!(log_file, "[#{DateTime.utc_now()}] #{msg}\n", [:append])
      rescue
        _ -> :ok
      end
    end

    log.("Starting Lunity editor...")

    headless = System.get_env("LUNITY_HEADLESS") == "1"
    Application.put_env(:lunity, :mode, if(headless, do: :library, else: :editor))
    log.("headless=#{headless}")

    Mix.Project.get!()
    log.("Mix project OK (cwd=#{File.cwd!()})")

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

    app_ebin = Path.join(Mix.Project.app_path(), "ebin")
    Code.prepend_path(app_ebin)

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

    log.(
      if(headless,
        do: "Starting MCP server (headless)...",
        else: "Starting MCP server (with editor)..."
      )
    )

    if use_http do
      port = System.get_env("LUNITY_HTTP_PORT", "4111") |> String.to_integer()
      log.("Phoenix endpoint on port #{port}, MCP SSE at http://localhost:#{port}/sse")

      Application.put_env(:lunity, Lunity.Web.Endpoint,
        http: [
          port: port,
          transport_options: [socket_opts: [keepalive: true]]
        ],
        server: true,
        secret_key_base: :crypto.strong_rand_bytes(64) |> Base.encode64()
      )

      case Lunity.Web.Endpoint.start_link([]) do
        {:ok, _pid} ->
          log.("Phoenix endpoint started on port #{port}")
          Process.sleep(:infinity)

        {:error, reason} ->
          log.("Phoenix endpoint failed: #{inspect(reason)}")
          Mix.raise("Failed to start Phoenix endpoint: #{inspect(reason)}")
      end
    else
      log.("Stdio transport")

      case Lunity.MCP.Server.start_link(transport: :stdio) do
        {:ok, pid} ->
          log.("MCP server started (pid=#{inspect(pid)})")
          Process.sleep(:infinity)

        {:error, reason} ->
          log.("MCP server failed: #{inspect(reason)}")
          Mix.raise("Failed to start Lunity MCP server: #{inspect(reason)}")
      end
    end
  rescue
    e ->
      log_file =
        case File.cwd() do
          {:ok, cwd} -> Path.join([cwd, "tmp", "lunity_edit.log"])
          _ -> "/tmp/lunity_edit.log"
        end

      stack = Exception.format(:error, e, __STACKTRACE__)
      File.write!(log_file, "[#{DateTime.utc_now()}] CRASH: #{inspect(e)}\n#{stack}\n", [:append])
      reraise e, __STACKTRACE__
  end
end
