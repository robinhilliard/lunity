defmodule Lunity.MCP.Server do
  @moduledoc """
  Lunity MCP server. Runs inside the game/editor process.

  Exposes tools for scene loading, hierarchy inspection, prefab instantiation,
  entity queries, view capture, and editor context. Uses stdio transport for
  Cursor integration.

  See the plan for full tool list. Phase 6a provides the skeleton; tools are
  implemented incrementally in subsequent phases.
  """
  use Lunity.MCP.Server.Setup
  alias Lunity.Editor.State
  alias Lunity.MCP.BlenderExtras
  alias Lunity.MCP.Hierarchy
  alias Lunity.MCP.Viewport

  deftool "set_project" do
    meta do
      name("Set Project")

      description(
        "Set the project root (cwd) and app for this session. Call this first when using HTTP transport so scene_load and other tools know which game project to use. With stdio, cwd comes from MCP config."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        cwd: %{
          type: "string",
          description: "Absolute path to the game project root (e.g. /path/to/pong)"
        },
        app: %{
          type: "string",
          description: "Optional app name (e.g. pong). Inferred from mix.exs if omitted."
        }
      },
      required: ["cwd"]
    })
  end

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
        "Returns the scene graph hierarchy of the currently loaded scene. Nodes include name, properties, and children. Returns error if no scene loaded."
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
        "Returns a Python script to add Blender custom properties from a prefab's property spec. Pass the script to Blender MCP execute_blender_code to apply to selected object(s)."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        prefab: %{
          type: "string",
          description: "Prefab module name (e.g. 'MyGame.Prefabs.Door')"
        }
      },
      required: ["prefab"]
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

  # Phase 6d: Agent APIs
  deftool "view_list" do
    meta do
      name("View List")

      description(
        "List available views. Returns view IDs (e.g. 'main' for the orbit camera view)."
      )
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "view_capture" do
    meta do
      name("View Capture")

      description(
        "Capture a view as PNG. Returns format, width, height, base64 data, and data_url (ready for vision APIs). Requires editor with GL context."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        view_id: %{
          type: "string",
          description: "View ID (default 'main')"
        }
      }
    })
  end

  deftool "entity_list" do
    meta do
      name("Entity List")

      description(
        "List entities in the current scene. Optionally filter by component module (e.g. 'MyGame.Components.Health')."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        component: %{
          type: "string",
          description: "Optional component module to filter by"
        }
      }
    })
  end

  deftool "entity_get" do
    meta do
      name("Entity Get")

      description("Get full component state for an entity. Returns the component struct as JSON.")
    end

    input_schema(%{
      type: "object",
      properties: %{
        entity_id: %{
          type: "integer",
          description: "Entity ID"
        },
        component: %{
          type: "string",
          description: "Component module name (e.g. 'MyGame.Components.Health')"
        }
      },
      required: ["entity_id", "component"]
    })
  end

  deftool "entity_at_screen" do
    meta do
      name("Entity At Screen")

      description(
        "Pick at screen coordinates (x, y). Returns node and entity_id under cursor, or nil. Requires scene loaded."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        x: %{type: "number", description: "Screen x (pixels)"},
        y: %{type: "number", description: "Screen y (pixels)"}
      },
      required: ["x", "y"]
    })
  end

  deftool "node_screen_bounds" do
    meta do
      name("Node Screen Bounds")

      description(
        "Get 2D screen bounds for a node. Pass entity_id to find node by entity, or node_name. Returns {x, y, width, height} or nil if behind camera."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        entity_id: %{type: "integer", description: "Entity ID (preferred)"},
        node_name: %{type: "string", description: "Node name (if no entity)"}
      }
    })
  end

  deftool "camera_state" do
    meta do
      name("Camera State")

      description(
        "Get camera position, target, FOV, and orbit params. Helps interpret screenshots."
      )
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "view_annotate" do
    meta do
      name("View Annotate")

      description(
        "Add overlay shapes (rects, circles, text) at pixel coordinates. Shapes persist until clear_annotations."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        shapes: %{
          type: "array",
          description: "List of shapes: {type: 'rect', x, y, w, h} or {type: 'text', x, y, text}"
        }
      },
      required: ["shapes"]
    })
  end

  deftool "highlight_node" do
    meta do
      name("Highlight Node")

      description(
        "Highlight a node (outline/glow) for a duration. Pass entity_id or node_name. Duration in ms (default 2000)."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        entity_id: %{type: "integer", description: "Entity ID"},
        node_name: %{type: "string", description: "Node name"},
        duration_ms: %{type: "integer", description: "Highlight duration (default 2000)"}
      }
    })
  end

  deftool "clear_annotations" do
    meta do
      name("Clear Annotations")

      description("Remove all overlay annotations and highlights.")
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "pause" do
    meta do
      name("Pause")

      description("Pause the game loop. In editor mode, sets paused flag for when game runs.")
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "step" do
    meta do
      name("Step")

      description("Single step when paused. Advances one tick then pauses again.")
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "resume" do
    meta do
      name("Resume")

      description("Resume the game loop.")
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "entity_set" do
    meta do
      name("Entity Set")

      description(
        "Modify a component value. Pass entity_id, component module, and a map of field -> value to merge."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        entity_id: %{type: "integer", description: "Entity ID"},
        component: %{type: "string", description: "Component module name"},
        value: %{
          type: "object",
          description: "Map of field names to values (e.g. {health: 50})"
        }
      },
      required: ["entity_id", "component", "value"]
    })
  end

  deftool "ecs_dump" do
    meta do
      name("ECS Dump")

      description(
        "Dump all allocated entities and their component values from the ComponentStore. Returns entity IDs, tensor indices, and component data. Optionally filter by component names."
      )
    end

    input_schema(%{
      type: "object",
      properties: %{
        components: %{
          type: "array",
          items: %{type: "string"},
          description:
            "Optional list of component module names to include (e.g. ['Lunity.Components.Position']). Omit to dump all registered tensor components."
        }
      }
    })
  end

  deftool "runtime_info" do
    meta do
      name("Runtime Info")

      description(
        "BEAM runtime diagnostics: process count, memory usage, active SSE connections, scheduler utilization, uptime. Use to monitor long-running instances."
      )
    end

    input_schema(%{type: "object", properties: %{}})
  end

  deftool "gc" do
    meta do
      name("Garbage Collect")

      description(
        "Force garbage collection on all BEAM processes. Returns memory before/after. Safe to call at any time."
      )
    end

    input_schema(%{type: "object", properties: %{}})
  end

  # Apply project context from state (set via set_project tool) so Lunity.priv_dir etc. work
  defp apply_project_context(state) do
    if cwd = state[:project_cwd] do
      Process.put(:lunity_project_cwd, cwd)
      if app = state[:project_app], do: Process.put(:lunity_project_app, app)
    end

    state
  end

  @impl true
  def handle_tool_call(tool_name, args, state) do
    state = apply_project_context(state)
    do_handle_tool_call(tool_name, args, state)
  end

  defp do_handle_tool_call("set_project", %{"cwd" => cwd} = args, state) when is_binary(cwd) do
    cwd = String.trim(cwd)

    app =
      case args["app"] do
        a when is_binary(a) and a != "" -> String.to_atom(a)
        _ -> infer_app_from_mix(cwd)
      end

    # Store in ETS so editor process (which runs SceneLoader) can use it
    State.put_project_context(cwd, app)

    state =
      state
      |> Map.put(:project_cwd, cwd)
      |> Map.put(:project_app, app)

    content = "Project set: cwd=#{cwd}, app=#{app || "nil"}"
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call("set_project", _args, state) do
    content = "set_project requires 'cwd' (e.g. {\"cwd\": \"/path/to/your_game\"})."
    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  defp do_handle_tool_call("project_structure", _args, state) do
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

  defp do_handle_tool_call("scene_load", %{"path" => path}, state) when is_binary(path) do
    {cwd, app} =
      case {state[:project_cwd], state[:project_app]} do
        {c, a} when not is_nil(c) -> {c, a}
        _ -> State.get_project_context() || {nil, nil}
      end

    State.put_load_command(path, cwd, app)

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

  defp do_handle_tool_call("scene_load", _args, state) do
    content = "scene_load requires a 'path' argument (e.g. {\"path\": \"box\"})."
    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  defp do_handle_tool_call("scene_get_hierarchy", _args, state) do
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

  defp do_handle_tool_call("get_blender_extras_script", %{"prefab" => prefab}, state)
       when is_binary(prefab) do
    case BlenderExtras.generate_script(prefab) do
      {:ok, script} ->
        {:ok, %{content: [%{type: "text", text: script}], is_error?: false}, state}

      {:error, reason} ->
        content = "Failed to generate script: #{inspect(reason)}"
        {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
    end
  end

  defp do_handle_tool_call("get_blender_extras_script", _args, state) do
    content =
      "get_blender_extras_script requires a 'prefab' argument (e.g. {\"prefab\": \"MyGame.Prefabs.Door\"})."

    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  defp do_handle_tool_call("editor_get_context", _args, state) do
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

  defp do_handle_tool_call("editor_set_context", %{"type" => type, "path" => path}, state)
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

  defp do_handle_tool_call("editor_set_context", _args, state) do
    content =
      "editor_set_context requires 'type' ('scene' or 'prefab') and 'path' (e.g. {\"type\": \"scene\", \"path\": \"box\"})."

    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  defp do_handle_tool_call("editor_push", _args, state) do
    {content, is_error} =
      case State.context_push() do
        :ok -> {"Context pushed onto stack.", false}
        {:error, :no_scene} -> {"No scene loaded. Load a scene or prefab first.", true}
      end

    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  defp do_handle_tool_call("editor_pop", _args, state) do
    {content, is_error} =
      case State.context_pop() do
        {:ok, entry} ->
          {"Restored context: #{entry.type} #{entry.path}.", false}

        {:error, :empty_stack} ->
          {"Context stack is empty. Nothing to restore.", true}
      end

    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  defp do_handle_tool_call("editor_peek", _args, state) do
    stack = State.context_peek()
    summary = Enum.map(stack, fn e -> "#{e.type} #{e.path}" end)
    content = Jason.encode!(%{stack: summary, count: length(stack)})
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  # Phase 6d handlers
  defp do_handle_tool_call("view_list", _args, state) do
    content = Jason.encode!(%{views: ["main"]})
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call("view_capture", args, state) do
    view_id = Map.get(args || %{}, "view_id", "main")
    State.put_capture_request(view_id)
    result = poll_capture_result(60, 50)

    {content, is_error} =
      case result do
        {:ok, base64} ->
          vp = State.get_viewport()
          {w, h} = vp || {0, 0}
          data_url = "data:image/png;base64,#{base64}"

          json =
            Jason.encode!(%{
              format: "png",
              width: w,
              height: h,
              data: base64,
              data_url: data_url
            })

          {json, false}

        {:error, reason} ->
          {"Capture failed: #{inspect(reason)}", true}

        nil ->
          {"View capture timed out. The editor may not be running.", true}
      end

    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  defp do_handle_tool_call("entity_list", args, state) do
    component_filter = args && Map.get(args, "component")
    entities = State.get_entities()
    entity_ids = Enum.map(entities, fn {_node, eid} -> eid end)

    filtered =
      if component_filter && component_filter != "" do
        case resolve_component_module(component_filter) do
          {:ok, mod} ->
            try do
              mod.get_all()
              |> Enum.map(fn {eid, _} -> eid end)
              |> MapSet.new()
              |> MapSet.intersection(MapSet.new(entity_ids))
              |> MapSet.to_list()
            rescue
              _ -> entity_ids
            end

          _ ->
            entity_ids
        end
      else
        entity_ids
      end

    content = Jason.encode!(%{entities: filtered, count: length(filtered)})
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call("entity_get", %{"entity_id" => eid, "component" => comp}, state)
       when is_integer(eid) and is_binary(comp) do
    case resolve_component_module(comp) do
      {:ok, mod} ->
        try do
          value = mod.get(eid, nil)
          content = component_to_json(value)
          {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
        rescue
          e ->
            content = "Entity get failed: #{inspect(e)}"
            {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
        end

      {:error, reason} ->
        content = "Component module not found: #{inspect(reason)}"
        {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
    end
  end

  defp do_handle_tool_call("entity_get", _args, state) do
    content = "entity_get requires entity_id and component."
    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  defp do_handle_tool_call("entity_at_screen", %{"x" => x, "y" => y}, state)
       when is_number(x) and is_number(y) do
    State.put_pick_request(x, y)
    result = poll_pick_result(60, 50)

    {content, is_error} =
      case result do
        {:ok, node, entity_id} ->
          out = %{
            node: node_to_pick_result(node),
            entity_id: entity_id
          }

          {Jason.encode!(out), false}

        nil ->
          {Jason.encode!(%{node: nil, entity_id: nil}), false}
      end

    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  defp do_handle_tool_call("entity_at_screen", _args, state) do
    content = "entity_at_screen requires x and y."
    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  defp do_handle_tool_call("node_screen_bounds", args, state) do
    case {State.get_scene(), State.get_orbit(), State.get_viewport()} do
      {scene, orbit, {vp_w, vp_h}} when not is_nil(scene) and not is_nil(orbit) ->
        viewport = {0, 0, vp_w, vp_h}
        node = find_node_for_bounds(args, scene)
        bounds = node && Viewport.node_screen_bounds(node, orbit, viewport)
        content = Jason.encode!(bounds || %{error: "Node not found or behind camera"})
        {:ok, %{content: [%{type: "text", text: content}], is_error?: bounds == nil}, state}

      _ ->
        content = "No scene loaded or viewport not ready."
        {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
    end
  end

  defp do_handle_tool_call("camera_state", _args, state) do
    orbit = State.get_orbit()
    content = (orbit && orbit_to_map(orbit) |> Jason.encode!()) || "No camera."
    is_error = orbit == nil
    {:ok, %{content: [%{type: "text", text: content}], is_error?: is_error}, state}
  end

  defp do_handle_tool_call("view_annotate", %{"shapes" => shapes}, state) when is_list(shapes) do
    normalized = Enum.map(shapes, &normalize_annotation_shape/1)
    State.add_annotations(normalized)
    content = "Added #{length(shapes)} annotation(s)."
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call("view_annotate", _args, state) do
    content = "view_annotate requires shapes array."
    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  defp do_handle_tool_call("highlight_node", args, state) do
    target = args["entity_id"] || args["node_name"]
    duration = args["duration_ms"] || 2000

    if target do
      State.put_highlight(target, duration)
      content = "Highlight set for #{duration}ms."
      {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
    else
      content = "highlight_node requires entity_id or node_name."
      {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
    end
  end

  defp do_handle_tool_call("clear_annotations", _args, state) do
    State.clear_annotations()
    State.clear_highlight()
    content = "Annotations and highlights cleared."
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call("pause", args, state) do
    targets = resolve_instance_targets(args)
    Enum.each(targets, &Lunity.Instance.pause/1)
    sync_editor_mode_from_watched(targets)
    content = "Paused instances: #{inspect(targets)}"
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call("step", args, state) do
    targets = resolve_instance_targets(args)
    Enum.each(targets, &Lunity.Instance.step/1)
    content = "Step requested for instances: #{inspect(targets)}"
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call("resume", args, state) do
    targets = resolve_instance_targets(args)
    Enum.each(targets, &Lunity.Instance.resume/1)
    sync_editor_mode_from_watched(targets)
    content = "Resumed instances: #{inspect(targets)}"
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp resolve_instance_targets(args) do
    case args && Map.get(args, "instance_id") do
      nil -> Lunity.Instance.list()
      id -> [id]
    end
  end

  defp sync_editor_mode_from_watched(targets) do
    case State.get_watching_instance() do
      nil ->
        :ok

      watched_id ->
        if watched_id in targets do
          case Lunity.Instance.get(watched_id) do
            %{status: :paused} -> State.put_editor_mode(:paused)
            %{status: :running} -> State.put_editor_mode(:watch)
            _ -> :ok
          end
        end
    end
  end

  defp do_handle_tool_call(
         "entity_set",
         %{"entity_id" => eid, "component" => comp, "value" => val},
         state
       )
       when is_integer(eid) and is_binary(comp) and is_map(val) do
    case resolve_component_module(comp) do
      {:ok, mod} ->
        try do
          existing = mod.get(eid, nil)
          merged = merge_component_value(existing, val)
          mod.update(eid, merged)
          content = "Updated. New value: #{component_to_json(merged)}"
          {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
        rescue
          e ->
            content = "entity_set failed: #{inspect(e)}"
            {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
        end

      {:error, reason} ->
        content = "Component module not found: #{inspect(reason)}"
        {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
    end
  end

  defp do_handle_tool_call("entity_set", _args, state) do
    content = "entity_set requires entity_id, component, and value (map)."
    {:ok, %{content: [%{type: "text", text: content}], is_error?: true}, state}
  end

  defp do_handle_tool_call("ecs_dump", args, state) do
    instance_id = args && Map.get(args, "instance_id")

    store_ids =
      case instance_id do
        nil -> Lunity.Instance.list()
        id -> [id]
      end

    results =
      Enum.flat_map(store_ids, fn sid ->
        Lunity.ComponentStore.with_store(sid, fn ->
          registry_table = :"lunity_registry_#{sid}"
          meta_table = :"lunity_meta_#{sid}"

          registry =
            try do
              :ets.tab2list(registry_table)
            rescue
              _ -> []
            end

          all_tensor_mods =
            try do
              :ets.tab2list(meta_table)
              |> Enum.flat_map(fn {mod, opts} ->
                if opts.storage == :tensor, do: [mod], else: []
              end)
            rescue
              _ -> []
            end

          component_mods =
            case args && Map.get(args, "components") do
              list when is_list(list) and list != [] ->
                requested = MapSet.new(list)

                Enum.filter(all_tensor_mods, fn mod ->
                  MapSet.member?(requested, inspect(mod))
                end)

              _ ->
                all_tensor_mods
            end

          Enum.map(registry, fn {entity_id, index} ->
            components =
              Map.new(component_mods, fn mod ->
                val =
                  try do
                    Lunity.ComponentStore.get(mod, entity_id)
                  rescue
                    _ -> nil
                  end

                formatted =
                  case val do
                    nil -> nil
                    t when is_tuple(t) -> Tuple.to_list(t)
                    n when is_number(n) -> n
                    other -> inspect(other)
                  end

                {inspect(mod), formatted}
              end)

            %{id: inspect(entity_id), instance: sid, index: index, components: components}
          end)
        end)
      end)
      |> Enum.sort_by(& &1.index)

    content = Jason.encode!(%{entity_count: length(results), entities: results})
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call("runtime_info", _args, state) do
    mem = :erlang.memory()
    {uptime_ms, _} = :erlang.statistics(:wall_clock)

    info = %{
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      memory_mb: %{
        total: Float.round(mem[:total] / 1_048_576, 1),
        processes: Float.round(mem[:processes] / 1_048_576, 1),
        ets: Float.round(mem[:ets] / 1_048_576, 1),
        binary: Float.round(mem[:binary] / 1_048_576, 1),
        system: Float.round(mem[:system] / 1_048_576, 1)
      },
      sse_connections: Lunity.Web.ConnectionReaper.count(),
      sse_details: Lunity.Web.ConnectionReaper.info(),
      uptime_hours: Float.round(uptime_ms / 3_600_000, 2),
      schedulers: :erlang.system_info(:schedulers_online),
      otp_release: to_string(:erlang.system_info(:otp_release))
    }

    content = Jason.encode!(info, pretty: true)
    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call("gc", _args, state) do
    mem_before = :erlang.memory(:total)

    pids = Process.list()

    Enum.each(pids, fn pid ->
      try do
        :erlang.garbage_collect(pid)
      catch
        _, _ -> :ok
      end
    end)

    mem_after = :erlang.memory(:total)
    freed = mem_before - mem_after

    content =
      Jason.encode!(%{
        processes_collected: length(pids),
        memory_before_mb: Float.round(mem_before / 1_048_576, 1),
        memory_after_mb: Float.round(mem_after / 1_048_576, 1),
        freed_mb: Float.round(freed / 1_048_576, 1)
      })

    {:ok, %{content: [%{type: "text", text: content}], is_error?: false}, state}
  end

  defp do_handle_tool_call(_tool_name, _args, state) do
    {:error, :tool_not_implemented, state}
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

  defp poll_capture_result(0, _interval), do: nil

  defp poll_capture_result(attempts, interval) do
    case State.take_capture_result() do
      nil ->
        Process.sleep(interval)
        poll_capture_result(attempts - 1, interval)

      result ->
        result
    end
  end

  defp poll_pick_result(0, _interval), do: nil

  defp poll_pick_result(attempts, interval) do
    case State.take_pick_result() do
      nil ->
        Process.sleep(interval)
        poll_pick_result(attempts - 1, interval)

      result ->
        result
    end
  end

  defp infer_app_from_mix(cwd) do
    mix_exs = Path.join(cwd, "mix.exs")

    if File.exists?(mix_exs) do
      case File.read(mix_exs) do
        {:ok, content} ->
          case Regex.run(~r/app:\s*:(\w+)/, content) do
            [_, app_str] -> String.to_atom(app_str)
            _ -> nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  rescue
    _ -> nil
  end

  defp resolve_component_module(name) when is_binary(name) do
    try do
      mod = Module.concat([name])
      if function_exported?(mod, :get, 2), do: {:ok, mod}, else: {:error, :no_get}
    rescue
      _ -> {:error, :module_not_found}
    end
  end

  defp node_to_pick_result(%EAGL.Node{} = node) do
    %{
      name: node.name,
      properties: node.properties || %{},
      entity_id: (node.properties || %{})["entity_id"]
    }
  end

  defp find_node_for_bounds(args, scene) do
    cond do
      eid = args["entity_id"] ->
        entities = State.get_entities()
        Enum.find_value(entities, fn {node, id} -> id == eid && node end)

      name = args["node_name"] ->
        find_node_by_name(scene.root_nodes, name)

      true ->
        nil
    end
  end

  defp find_node_by_name(nodes, name) when is_list(nodes) do
    Enum.find_value(nodes, fn
      %{name: ^name} = node -> node
      node -> find_node_by_name(node.children || [], name)
    end)
  end

  defp find_node_by_name(_, _), do: nil

  defp normalize_annotation_shape(shape) when is_map(shape) do
    Map.new(shape, fn
      {k, v} when is_binary(k) ->
        try do
          {String.to_existing_atom(k), v}
        rescue
          ArgumentError -> {k, v}
        end

      {k, v} ->
        {k, v}
    end)
  end

  defp component_to_json(value) when is_struct(value) do
    value
    |> Map.from_struct()
    |> Jason.encode!()
  end

  defp component_to_json(value), do: Jason.encode!(value)

  defp merge_component_value(struct, map) when is_struct(struct) and is_map(map) do
    base = Map.from_struct(struct)
    existing_keys = Map.keys(base)

    atom_map =
      Map.new(map, fn
        {k, v} when is_binary(k) -> {String.to_atom(k), v}
        {k, v} -> {k, v}
      end)

    # Only merge keys that exist in the struct
    filtered = Map.take(atom_map, existing_keys)
    merged = Map.merge(base, filtered)
    struct(struct.__struct__, merged)
  end
end
