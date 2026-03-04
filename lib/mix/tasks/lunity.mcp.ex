defmodule Mix.Tasks.Lunity.Mcp do
  @shortdoc "Start the Lunity MCP server (stdio transport for Cursor)"
  @moduledoc """
  Starts the Lunity MCP server with stdio transport.

  Cursor spawns this process and communicates via stdin/stdout. Configure in
  Cursor's MCP settings with cwd set to your game project path.

  ## Cursor config

      {
        "mcpServers": {
          "lunity": {
            "command": "mix",
            "args": ["lunity.mcp"],
            "cwd": "/path/to/your_game"
          }
        }
      }

  ## Requirements

  - Run from your game project directory (or set cwd in Cursor config)
  - ECSx and OpenGL context required for full tool functionality (scene_load,
    entity_list, etc.). Phase 6a provides the skeleton; tools are added
    incrementally.
  """
  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    # Ensure we're in a Mix project
    Mix.Project.get!()

    # Start the MCP server with stdio transport
    # Log to stderr so stdout stays clean for JSON-RPC
    Application.put_env(:logger, :backends, [])
    Logger.configure(level: :warning)

    opts = [transport: :stdio]

    case Lunity.MCP.Server.start_link(opts) do
      {:ok, _pid} ->
        # Block until the process exits
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.raise("Failed to start Lunity MCP server: #{inspect(reason)}")
    end
  end
end
