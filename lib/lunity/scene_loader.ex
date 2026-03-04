defmodule Lunity.SceneLoader do
  @moduledoc """
  Orchestrates scene loading: glTF, ConfigLoader, PrefabLoader, and behaviour init.

  Single entry point for loading scenes with ECSx entity creation. Traverses
  nodes, resolves prefabs and behaviours, creates entities, and runs init.

  ## Prefab load order

  For nodes with `extras["prefab"]`:
  1. Instantiate prefab (merge placeholder extras as overrides)
  2. Replace placeholder with prefab root at placeholder's transform
  3. Run behaviour on prefab root with merged config

  ## Behaviour nodes

  For nodes with `extras["behaviour"]`:
  1. Create entity (generate ID)
  2. Load config from `extras["config"]`, merge with extras
  3. Call `behaviour.init(merged_config, entity_id)`
  4. Store entity_id in `node.properties["entity_id"]`

  ## Requirements

  - ECSx must be running (game adds ECSx to supervision tree)
  - OpenGL context must be active (for glTF/prefab loading)
  """

  alias EAGL.{Node, Scene}
  alias Lunity.{ConfigLoader, PrefabLoader, NodeBehaviour}

  @doc """
  Load a scene from `priv/scenes/<path>.glb`.

  Loads glTF, traverses nodes, resolves prefabs and behaviours, creates
  entities, and runs init. Returns the scene and a list of {node, entity_id}
  for node-linked entities.

  ## Options

  - `:app` - Application whose priv dir to use
  - `:shader_program` - Shader for meshes (default: PBR)

  ## Returns

  - `{:ok, scene, entities}` - Scene with entities created; entities is [{node, entity_id}, ...]
  - `{:error, reason}` - Load error
  """
  @spec load_scene(String.t(), keyword()) ::
          {:ok, Scene.t(), [{Node.t(), term()}]} | {:error, term()}
  def load_scene(path, opts \\ []) do
    with :ok <- validate_path(path),
         {:ok, glb_path} <- scene_glb_path(path, opts),
         :ok <- ensure_glb_exists(glb_path),
         {:ok, shader_program} <- shader_for_opts(opts),
         {:ok, scene, _gltf, _ds} <- GLTF.EAGL.load_scene(glb_path, shader_program, opts) do
      {updated_roots, entities} = process_roots(scene.root_nodes, [])
      updated_scene = %{scene | root_nodes: updated_roots}
      {:ok, updated_scene, Enum.reverse(entities)}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_path(path) do
    cond do
      not is_binary(path) -> {:error, :path_traversal}
      path == "" -> {:error, :path_traversal}
      String.contains?(path, "..") -> {:error, :path_traversal}
      String.starts_with?(path, "/") -> {:error, :path_traversal}
      true -> :ok
    end
  end

  defp scene_glb_path(path, opts) do
    app = Keyword.get(opts, :app, current_app())
    priv_dir = Application.app_dir(app, "priv")
    scenes_dir = Path.join(priv_dir, "scenes")
    full_path = Path.join(scenes_dir, ensure_glb_suffix(path))

    expanded = Path.expand(full_path)
    scenes_expanded = Path.expand(scenes_dir)

    if String.starts_with?(expanded, scenes_expanded) do
      {:ok, full_path}
    else
      {:error, :path_traversal}
    end
  end

  defp ensure_glb_suffix(path) do
    if String.ends_with?(path, ".glb"), do: path, else: path <> ".glb"
  end

  defp ensure_glb_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, :file_not_found}
  end

  defp shader_for_opts(opts) do
    case Keyword.get(opts, :shader_program) do
      nil ->
        case GLTF.EAGL.create_pbr_shader() do
          {:ok, program} -> {:ok, program}
          {:error, _} = err -> err
        end

      program when is_integer(program) ->
        {:ok, program}
    end
  end

  defp current_app do
    case Mix.Project.get() do
      nil -> :lunity
      project -> project.project()[:app]
    end
  end

  defp process_roots(nodes, acc) do
    Enum.map_reduce(nodes, acc, fn node, acc ->
      process_node(node, nil, acc)
    end)
  end

  defp process_node(node, parent, acc) do
    properties = node.properties || %{}

    cond do
      prefab_id = properties["prefab"] ->
        handle_prefab_node(node, parent, prefab_id, acc)

      behaviour_name = properties["behaviour"] ->
        handle_behaviour_node(node, behaviour_name, acc)

      true ->
        # No prefab or behaviour - just process children
        process_children(node, acc)
    end
  end

  defp handle_prefab_node(placeholder, parent, prefab_id, acc) do
    overrides = placeholder.properties || %{}
    opts = [app: current_app()]

    with {:ok, prefab_scene, prefab_config} <- PrefabLoader.load_prefab(prefab_id, opts),
         merged_config <- ConfigLoader.merge_config(prefab_config, overrides),
         temp = Node.new(),
         {:ok, temp_with_prefab, _} <-
           PrefabLoader.instantiate_prefab_from_loaded(
             prefab_scene,
             prefab_config,
             temp,
             overrides
           ) do
      prefab_root =
        case temp_with_prefab.children do
          [root | _] -> root
          _ -> raise "Prefab must have at least one root node"
        end

      # Copy placeholder transform to prefab root
      prefab_root =
        %{
          prefab_root
          | position: placeholder.position,
            rotation: placeholder.rotation,
            scale: placeholder.scale,
            matrix: placeholder.matrix,
            parent: parent
        }

      # Process prefab root's children and run behaviour if present
      {updated_children, acc} =
        Enum.map_reduce(prefab_root.children || [], acc, fn c, acc ->
          process_node(c, prefab_root, acc)
        end)

      prefab_root = %{prefab_root | children: updated_children}

      # Run behaviour on prefab root if it has one
      prefab_props = prefab_root.properties || %{}

      {prefab_root, acc} =
        if prefab_props["behaviour"] do
          case run_behaviour_init(prefab_root, prefab_props, merged_config) do
            {:ok, entity_id} ->
              prefab_root = put_entity_id(prefab_root, entity_id)
              {prefab_root, [{prefab_root, entity_id} | acc]}

            _ ->
              {prefab_root, acc}
          end
        else
          {prefab_root, acc}
        end

      {prefab_root, acc}
    else
      {:error, _} ->
        # On prefab load error, keep placeholder
        {process_children(placeholder, acc) |> elem(0), acc}
    end
  end

  defp handle_behaviour_node(node, _behaviour_name, acc) do
    case run_behaviour_init(node, node.properties || %{}, nil) do
      {:ok, entity_id} ->
        node_with_id = put_entity_id(node, entity_id)
        {processed_node, acc} = process_children(node_with_id, [{node_with_id, entity_id} | acc])
        {processed_node, acc}

      {:error, _} ->
        process_children(node, acc)
    end
  end

  defp run_behaviour_init(_node, properties, prefab_merged_config) do
    behaviour_name = properties["behaviour"]
    config_path = properties["config"]

    merged_config =
      if prefab_merged_config do
        prefab_merged_config
      else
        case load_node_config(config_path, properties) do
          {:ok, config} -> ConfigLoader.merge_config(config, properties)
          {:error, _} -> properties
        end
      end

    with {:ok, behaviour_module} <- resolve_behaviour(behaviour_name),
         entity_id <- generate_entity_id(),
         :ok <- behaviour_module.init(merged_config, entity_id) do
      {:ok, entity_id}
    end
  end

  defp resolve_behaviour(name) when is_binary(name) do
    try do
      module = NodeBehaviour.resolve_module(name)
      if function_exported?(module, :init, 2), do: {:ok, module}, else: {:error, :no_init}
    rescue
      _ -> {:error, {:behaviour_not_found, name}}
    end
  end

  defp load_node_config(nil, _properties), do: {:ok, %{}}
  defp load_node_config("", _properties), do: {:ok, %{}}

  defp load_node_config(config_path, _properties) do
    ConfigLoader.load_config(config_path)
  end

  defp put_entity_id(node, entity_id) do
    props = node.properties || %{}
    props = Map.put(props, "entity_id", entity_id)
    %{node | properties: props}
  end

  defp process_children(node, acc) do
    {updated_children, acc} =
      Enum.map_reduce(node.children || [], acc, fn child, acc ->
        process_node(child, node, acc)
      end)

    {%{node | children: updated_children}, acc}
  end

  defp generate_entity_id do
    :erlang.unique_integer([:positive])
  end
end
