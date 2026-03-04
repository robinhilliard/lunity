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

  alias Lunity.Editor.State
  alias Lunity.MCP.BlenderExtras
  alias Lunity.MCP.Hierarchy

  deftool "project_structure" do
    meta do
      name("Project Structure")

      description(
        "Returns the expected priv/ folder layout for Lunity projects. Use when agents need to know where scenes, prefabs, and config live."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{}
    })
  end

  deftool "scene_load" do
    meta do
      name("Scene Load")

      description(
        "Load a scene from priv/scenes/<path>.glb into the editor. Path is project-relative (e.g. 'box' or 'scenes/warehouse'). Requires editor with GL context."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        path: %{
          type: "string",
          description: "Scene path relative to priv/scenes/ (e.g. 'box', 'warehouse')"
        }
      },
      required: ["path"]
    })
  end

  deftool "scene_get_hierarchy" do
    meta do
      name("Scene Get Hierarchy")

      description(
        "Returns the scene graph hierarchy of the currently loaded scene. Nodes include name, properties (extras), and children. Returns error if no scene loaded."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{}
    })
  end

  deftool "get_blender_extras_script" do
    meta do
      name("Get Blender Extras Script")

      description(
        "Returns a Python script to add Blender custom properties from a behaviour's extras spec. Pass the script to Blender MCP execute_blender_code to apply to selected object(s)."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        behaviour: %{
          type: "string",
          description: "Behaviour module name (e.g. 'MyGame.Behaviours.Door')"
        }
      },
      required: ["behaviour"]
    })
  end

  deftool "editor_get_context" do
    meta do
      name("Editor Get Context")

      description(
        "Returns current editor context: type (scene|prefab), path, and camera orbit state. Nil if no scene loaded."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{}
    })
  end

  deftool "editor_set_context" do
    meta do
      name("Editor Set Context")

      description(
        "Switch context to a scene or prefab. Loads the asset into the editor. Use type 'scene' with path (e.g. 'box') or type 'prefab' with path as prefab id (e.g. 'crate')."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        type: %{
          type: "string",
          enum: ["scene", "prefab"],
          description: "Context type: 'scene' or 'prefab'"
        },
        path: %{
          type: "string",
          description: "Scene path (e.g. 'box') or prefab id (e.g. 'crate')"
        }
      },
      required: ["type", "path"]
    })
  end

  deftool "editor_push" do
    meta do
      name("Editor Push")

      description(
        "Push current context (scene/prefab + camera) onto stack. Use before switching to inspect something else; pop to restore."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{}
    })
  end

  deftool "editor_pop" do
    meta do
      name("Editor Pop")

      description(
        "Pop context from stack and restore (load scene/prefab + camera). Returns error if stack empty."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{}
    })
  end

  deftool "editor_peek" do
    meta do
      name("Editor Peek")

      description(
        "Inspect context stack without popping. Returns list of stacked contexts (type, path)."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{}
    })
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

    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  def handle_tool_call("scene_load", %{"path" => path}, state) when is_binary(path) do
    State.put_load_command(path)

    # Poll for result (editor processes on next frame, ~16ms at 60fps)
    result = poll_load_result(60, 50)

    {content, is_error} =
      case result do
        {:ok, loaded_path, entity_count} ->
          {"Loaded scene #{loaded_path} (#{entity_count} entities).", false}

        {:error, reason} ->
          {"Failed to load scene: #{inspect(reason)}", true}

        nil ->
          {"Scene load timed out. The editor may not be running or the path may be invalid.",
           true}
      end

    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  def handle_tool_call("scene_load", _args, state) do
    content = "scene_load requires a 'path' argument (e.g. {\"path\": \"box\"})."
    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  def handle_tool_call("scene_get_hierarchy", _args, state) do
    case State.get_scene() do
      nil ->
        content = "No scene loaded. Use scene_load first."
        {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}

      scene ->
        hierarchy = Hierarchy.from_scene(scene)
        json = Jason.encode!(hierarchy)
        {:ok, %{content: [%{type: "text", text: json}], is_error?: false}, state}
    end
  end

  def handle_tool_call("get_blender_extras_script", %{"behaviour" => behaviour}, state)
      when is_binary(behaviour) do
    case BlenderExtras.generate_script(behaviour) do
      {:ok, script} ->
        {:ok, %{content: [%{type: "text", text: script}], is_error?: false}, state}

      {:error, reason} ->
        content = "Failed to generate script: #{inspect(reason)}"
        {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
    end
  end

  def handle_tool_call("get_blender_extras_script", _args, state) do
    content =
      "get_blender_extras_script requires a 'behaviour' argument (e.g. {\"behaviour\": \"MyGame.Behaviours.Door\"})."

    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  def handle_tool_call("editor_get_context", _args, state) do
    content =
      case State.get_context() do
        nil ->
          "No scene or prefab loaded."

        ctx ->
          ctx
          |> Map.put(:orbit, orbit_to_map(ctx.orbit))
          |> Jason.encode!()
      end

    is_error = State.get_context() == nil
    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  def handle_tool_call("editor_set_context", %{"type" => type, "path" => path}, state)
      when type in ["scene", "prefab"] and is_binary(path) do
    atom_type = if type == "scene", do: :scene, else: :prefab
    State.set_context(atom_type, path)

    result = poll_load_result(60, 50)

    {content, is_error} =
      case result do
        {:ok, loaded_path, entity_count} ->
          {"Loaded #{type} #{loaded_path} (#{entity_count} entities).", false}

        {:error, reason} ->
          {"Failed to load #{type}: #{inspect(reason)}", true}

        nil ->
          {"Context switch timed out. The editor may not be running or the path may be invalid.",
           true}
      end

    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  def handle_tool_call("editor_set_context", _args, state) do
    content =
      "editor_set_context requires 'type' ('scene' or 'prefab') and 'path' (e.g. {\"type\": \"scene\", \"path\": \"box\"})."

    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  def handle_tool_call("editor_push", _args, state) do
    {content, is_error} =
      case State.context_push() do
        :ok -> {"Context pushed onto stack.", false}
        {:error, :no_scene} -> {"No scene loaded. Load a scene or prefab first.", true}
      end

    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  def handle_tool_call("editor_pop", _args, state) do
    {content, is_error} =
      case State.context_pop() do
        {:ok, entry} ->
          {"Restored context: #{entry.type} #{entry.path}.", false}

        {:error, :empty_stack} ->
          {"Context stack is empty. Nothing to restore.", true}
      end

    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  def handle_tool_call("editor_peek", _args, state) do
    stack = State.context_peek()
    summary = Enum.map(stack, fn e -> "#{e.type} #{e.path}" end)
    content = Jason.encode!(%{stack: summary, count: length(stack)})
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp orbit_to_map(nil), do: nil

  defp orbit_to_map(%EAGL.OrbitCamera{} = orbit) do
    [t] = orbit.target

    %{
      target: Tuple.to_list(t),
      distance: orbit.distance,
      azimuth: orbit.azimuth,
      elevation: orbit.elevation
    }
  end

  defp poll_load_result(0, _interval), do: nil

  defp poll_load_result(attempts, interval) do
    case State.take_load_result() do
      nil ->
        Process.sleep(interval)
        poll_load_result(attempts - 1, interval)

      result ->
        result
    end
  end
end
