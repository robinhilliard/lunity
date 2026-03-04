defmodule Lunity.MCP.Server do
  @moduledoc """
  Lunity MCP server. Runs inside the game/editor process.

  Exposes tools for scene loading, hierarchy inspection, prefab instantiation,
  entity queries, view capture, and editor context. Uses stdio transport for
  Cursor integration.

  See the plan for full tool list. Phase 6a provides the skeleton; tools are
  implemented incrementally in subsequent phases.
  """
  use ExMCP.Server

  deftool "project_structure" do
    meta do
      name "Project Structure"
      description "Returns the expected priv/ folder layout for Lunity projects. Use when agents need to know where scenes, prefabs, and config live."
    end

    input_schema %{
      type: "object",
      properties: %{},
      required: []
    }
  end

  @impl true
  def handle_tool_call("project_structure", _args, state) do
    content = """
    Lunity project structure (game's priv/ when Lunity is a dependency):

    priv/
      prefabs/
        *.glb           # glTF only; config in config/prefabs/
      scenes/
        *.glb           # glTF only; config in config/scenes/
      config/           # Code-behind configs
        scenes/
        prefabs/

    Paths are project-relative. Resolve via Application.app_dir(app, "priv").
    """

    {:ok, %{content: [%{type: "text", text: content}]}, state}
  end
end
