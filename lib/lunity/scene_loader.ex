defmodule Lunity.SceneLoader do
  @moduledoc """
  Orchestrates scene loading: glTF, ConfigLoader, PrefabLoader, and entity init.

  Single entry point for loading scenes with ECSx entity creation. Traverses
  nodes, resolves prefabs and entities, creates entities, and runs init.

  ## Prefab load order

  For nodes with `properties["prefab"]`:
  1. Instantiate prefab (merge placeholder properties as overrides)
  2. Replace placeholder with prefab root at placeholder's transform
  3. Run entity init on prefab root with merged config

  ## Entity nodes

  For nodes with `properties["entity"]`:
  1. Create entity (generate ID)
  2. Load config from `properties["config"]`, merge with properties
  3. Call `entity_module.init(merged_config, entity_id)`
  4. Store entity_id in `node.properties["entity_id"]`

  ## Requirements

  - ECSx must be running (game adds ECSx to supervision tree)
  - OpenGL context must be active (for glTF/prefab loading)
  """

  alias EAGL.{Node, Scene}
  alias Lunity.{ConfigLoader, PrefabLoader, Entity}
  alias Lunity.Scene.{Def, NodeDef}

  import EAGL.Math

  @doc """
  Load a scene by path.

  Resolution order:
  1. Scene builders (explicit `{Module, :function}` in `:lunity, :scene_builders` config)
  2. Mod data (scene definitions from `data:extend()` in Lua mods)
  3. Scene module by convention (`{App}.Scenes.{CamelizedPath}`)
  4. Config file at `priv/config/scenes/<path>.exs` returning `%Lunity.Scene.Def{}`
  5. `.glb` file at `priv/scenes/<path>.glb`

  ## Options

  - `:app` - Application whose priv dir to use
  - `:shader_program` - Shader for meshes (default: PBR)

  ## Returns

  - `{:ok, scene, entities}` - Scene with entities created; entities is [{node, entity_id}, ...]
  - `{:error, reason}` - Load error
  """
  @spec load_scene(module() | String.t(), keyword()) ::
          {:ok, Scene.t(), [{Node.t(), term()}]} | {:error, term()}
  def load_scene(path_or_module, opts \\ [])

  def load_scene(module, opts) when is_atom(module) do
    if cwd = opts[:project_cwd] do
      Lunity.Editor.State.put_project_context(cwd, opts[:project_app])
    end

    case resolve_scene_module(module) do
      {:ok, %Def{} = scene_def} ->
        build_from_def(scene_def, opts)

      {:error, _} = err ->
        err
    end
  end

  def load_scene(path, opts) when is_binary(path) do
    if cwd = opts[:project_cwd] do
      Lunity.Editor.State.put_project_context(cwd, opts[:project_app])
    end

    with :ok <- validate_path(path) do
      case resolve_scene_builder(path, opts) do
        {:ok, scene} ->
          {:ok, scene, []}

        {:error, _reason} = err ->
          err

        nil ->
          case resolve_mod_scene(path, opts) do
            {:ok, _scene, _entities} = result ->
              result

            nil ->
              case resolve_scene_module_by_path(path, opts) do
                {:ok, _scene, _entities} = result ->
                  result

                nil ->
                  case resolve_config_scene(path, opts) do
                    {:ok, _scene, _entities} = result ->
                      result

                    nil ->
                      load_scene_from_file(path, opts)
                  end
              end
          end
      end
    end
  end

  defp resolve_scene_builder(path, opts) do
    builders = Application.get_env(:lunity, :scene_builders, %{})
    key = path |> String.replace_suffix(".glb", "") |> String.trim_leading("scenes/")

    case Map.get(builders, key) do
      {module, function} when is_atom(module) and is_atom(function) ->
        case Code.ensure_loaded(module) do
          {:module, _} ->
            shader_opts = Keyword.take(opts, [:shader_program])
            builder_opts = [app: Keyword.get(opts, :app, current_app())] ++ shader_opts

            try do
              case apply(module, function, [builder_opts]) do
                {:ok, scene} -> {:ok, scene}
                {:ok, scene, _} -> {:ok, scene}
                other -> other
              end
            rescue
              e ->
                {:error, {:scene_builder_error, Exception.message(e)}}
            end

          {:error, :nofile} ->
            # Ensure host app is started (editor may run before project app is fully loaded)
            app =
              module |> Module.split() |> List.first() |> String.downcase() |> String.to_atom()

            _ = Application.ensure_all_started(app)
            # Add app's ebin to code path; use opts (from load command) or ETS or project_priv
            try do
              ebin =
                opts[:project_cwd] ||
                  case Lunity.Editor.State.get_project_context() do
                    {cwd, _} when is_binary(cwd) -> cwd
                    _ -> nil
                  end

              ebin =
                if ebin do
                  Path.join(ebin, "_build/dev/lib/#{app}/ebin")
                else
                  project_priv = Application.get_env(:lunity, :project_priv)

                  if project_priv do
                    Path.join(Path.dirname(project_priv), "_build/dev/lib/#{app}/ebin")
                  else
                    Path.join(Application.app_dir(app), "ebin")
                  end
                end

              ebin = Path.expand(ebin)

              if File.dir?(ebin) do
                # Elixir's :code.add_path uses add_path/2 with :nocache; Erlang add_path/1 works
                apply(:code, :add_path, [String.to_charlist(ebin)])
              end
            rescue
              _ -> :ok
            end

            case Code.ensure_loaded(module) do
              {:module, _} ->
                shader_opts = Keyword.take(opts, [:shader_program])
                builder_opts = [app: Keyword.get(opts, :app, current_app())] ++ shader_opts

                try do
                  case apply(module, function, [builder_opts]) do
                    {:ok, scene} -> {:ok, scene}
                    {:ok, scene, _} -> {:ok, scene}
                    other -> other
                  end
                rescue
                  e -> {:error, {:scene_builder_error, Exception.message(e)}}
                end

              {:error, _} ->
                {:error, {:scene_builder_error, "module #{inspect(module)} is not available"}}
            end
        end

      _ ->
        nil
    end
  end

  defp resolve_mod_scene(path, opts) do
    scene_key = path |> String.replace_suffix(".glb", "") |> String.trim_leading("scenes/")

    case Lunity.Mod.Loader.get_scene(scene_key) do
      %Def{} = scene_def ->
        build_from_def(scene_def, opts)

      nil ->
        nil
    end
  end

  defp resolve_scene_module_by_path(path, opts) do
    scene_key = path |> String.replace_suffix(".glb", "") |> String.trim_leading("scenes/")
    app = current_app()
    app_prefix = app |> to_string() |> Macro.camelize()

    module_parts =
      scene_key
      |> String.split("/")
      |> Enum.map(&Macro.camelize/1)
      |> Enum.map(&String.to_atom/1)

    module = Module.concat([String.to_atom(app_prefix), :Scenes] ++ module_parts)

    case resolve_scene_module(module) do
      {:ok, %Def{} = scene_def} ->
        build_from_def(scene_def, opts)

      _ ->
        nil
    end
  end

  defp resolve_config_scene(path, opts) do
    config_key = path |> String.replace_suffix(".glb", "") |> String.trim_leading("scenes/")
    config_path = "scenes/#{config_key}"
    config_opts = Keyword.take(opts, [:app])

    case ConfigLoader.load_config(config_path, config_opts) do
      {:ok, %Def{} = scene_def} ->
        build_from_def(scene_def, opts)

      {:ok, _other} ->
        nil

      {:error, _} ->
        nil
    end
  end

  defp build_from_def(%Def{nodes: node_defs}, opts) do
    root = Node.new(name: "scene_root")

    {root, entities} =
      Enum.reduce(node_defs, {root, []}, fn node_def, {parent, entities} ->
        {:ok, updated_parent, new_entities} = build_node_from_def(node_def, parent, opts)
        {updated_parent, entities ++ new_entities}
      end)

    scene = Scene.new(name: "scene") |> Scene.add_root_node(root)
    {:ok, scene, entities}
  end

  defp build_node_from_def(%NodeDef{} = node_def, parent, opts) do
    check_property_conflicts(node_def)

    {parent, child_node, entities} =
      cond do
        node_def.scene ->
          build_scene_ref_node(node_def, parent, opts)

        node_def.prefab ->
          case PrefabLoader.load_prefab(node_def.prefab, opts) do
            {:ok, prefab_scene, prefab_config} ->
              overrides = node_def.properties || %{}

              {:ok, updated_parent, _merged} =
                PrefabLoader.instantiate_prefab_from_loaded(
                  prefab_scene,
                  prefab_config,
                  parent,
                  overrides
                )

              [child | rest] = updated_parent.children

              child =
                child
                |> apply_transform(node_def)
                |> Map.put(:name, to_string(node_def.name))
                |> maybe_apply_material(node_def)

              {child, entity_entities} =
                if node_def.entity do
                  merged_config = ConfigLoader.merge_config(prefab_config, overrides)

                  case init_entity_from_def(node_def, merged_config) do
                    {:ok, entity_id} ->
                      {put_entity_id(child, entity_id), [{child, entity_id}]}

                    {:error, _} ->
                      {child, []}
                  end
                else
                  {child, []}
                end

              final_parent = Node.set_children(updated_parent, [child | rest])
              {final_parent, child, entity_entities}

            {:error, reason} ->
              raise "Failed to load prefab #{node_def.prefab}: #{inspect(reason)}"
          end

        true ->
          child =
            Node.new(name: to_string(node_def.name))
            |> apply_transform(node_def)
            |> maybe_apply_material(node_def)

          {child, entity_entities} =
            if node_def.entity do
              config = node_def.properties || %{}

              case init_entity_from_def(node_def, config) do
                {:ok, entity_id} ->
                  {put_entity_id(child, entity_id), [{child, entity_id}]}

                {:error, _} ->
                  {child, []}
              end
            else
              {child, []}
            end

          updated_parent = Node.add_child(parent, child)
          {updated_parent, child, entity_entities}
      end

    child_entities =
      Enum.flat_map(node_def.children || [], fn child_def ->
        {:ok, _updated_child, child_ents} = build_node_from_def(child_def, child_node, opts)
        child_ents
      end)

    {:ok, parent, entities ++ child_entities}
  end

  defp maybe_apply_material(node, %NodeDef{material: nil}), do: node

  defp maybe_apply_material(node, %NodeDef{material: material}) do
    mat =
      case material do
        %Lunity.Material{} -> material
        map when is_map(map) -> Lunity.Material.from_map(map)
      end

    uniforms = Lunity.Material.to_pbr_uniforms(mat)
    propagate_material_to_meshes(node, uniforms)
  end

  defp propagate_material_to_meshes(node, uniforms) do
    node =
      if node.mesh do
        %{node | material_uniforms: uniforms}
      else
        node
      end

    updated_children =
      Enum.map(node.children || [], fn c ->
        propagate_material_to_meshes(c, uniforms)
      end)

    %{node | children: updated_children}
  end

  defp init_entity_from_def(%NodeDef{entity: entity_module}, merged_config)
       when is_atom(entity_module) and entity_module != nil do
    config_path = Entity.config_path(entity_module)

    full_config =
      if config_path do
        case ConfigLoader.load_config(config_path) do
          {:ok, base_config} ->
            ConfigLoader.merge_config(
              if(is_list(base_config), do: Map.new(base_config), else: base_config),
              merged_config
            )

          {:error, _} ->
            merged_config
        end
      else
        merged_config
      end

    entity_id = generate_entity_id()

    struct_config =
      if function_exported?(entity_module, :__property_spec__, 0) do
        Entity.from_config(
          entity_module,
          if(is_list(full_config), do: Map.new(full_config), else: full_config)
        )
      else
        full_config
      end

    case entity_module.init(struct_config, entity_id) do
      :ok -> {:ok, entity_id}
      {:error, _} = err -> err
    end
  rescue
    e -> {:error, {:entity_init_error, Exception.message(e)}}
  end

  defp init_entity_from_def(_, _), do: {:error, :no_entity}

  defp apply_transform(node, %NodeDef{} = def) do
    node =
      if def.position do
        {x, y, z} = def.position
        Node.set_position(node, vec3(x, y, z))
      else
        node
      end

    node =
      if def.scale do
        {x, y, z} = def.scale
        Node.set_scale(node, vec3(x, y, z))
      else
        node
      end

    if def.rotation do
      {x, y, z, w} = def.rotation
      Node.set_rotation(node, quat(x, y, z, w))
    else
      node
    end
  end

  defp load_scene_from_file(path, opts) do
    with {:ok, glb_path} <- scene_glb_path(path, opts),
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
    priv_dir = Lunity.priv_dir_for_app(app)
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
    Lunity.project_app()
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

      entity_name = properties["entity"] ->
        handle_entity_node(node, entity_name, acc)

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

      prefab_props = prefab_root.properties || %{}

      {prefab_root, acc} =
        if prefab_props["entity"] do
          case run_entity_init(prefab_root, prefab_props, merged_config) do
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

  defp handle_entity_node(node, _entity_name, acc) do
    case run_entity_init(node, node.properties || %{}, nil) do
      {:ok, entity_id} ->
        node_with_id = put_entity_id(node, entity_id)
        {processed_node, acc} = process_children(node_with_id, [{node_with_id, entity_id} | acc])
        {processed_node, acc}

      {:error, _} ->
        process_children(node, acc)
    end
  end

  defp run_entity_init(_node, properties, prefab_merged_config) do
    entity_name = properties["entity"]
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

    with {:ok, entity_module} <- resolve_entity(entity_name),
         entity_id <- generate_entity_id(),
         :ok <- entity_module.init(merged_config, entity_id) do
      {:ok, entity_id}
    end
  end

  defp resolve_entity(name) when is_binary(name) do
    try do
      module = Entity.resolve_module(name)
      if function_exported?(module, :init, 2), do: {:ok, module}, else: {:error, :no_init}
    rescue
      _ -> {:error, {:entity_not_found, name}}
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

  defp build_scene_ref_node(%NodeDef{scene: scene_module} = node_def, parent, opts) do
    case resolve_scene_module(scene_module) do
      {:ok, %Def{nodes: sub_nodes}} ->
        group = Node.new(name: to_string(node_def.name)) |> apply_transform(node_def)

        {group, sub_entities} =
          Enum.reduce(sub_nodes, {group, []}, fn sub_def, {grp, ents} ->
            {:ok, updated_grp, new_ents} = build_node_from_def(sub_def, grp, opts)
            {updated_grp, ents ++ new_ents}
          end)

        updated_parent = Node.add_child(parent, group)
        {updated_parent, group, sub_entities}

      {:error, reason} ->
        raise "Failed to load sub-scene #{inspect(scene_module)}: #{inspect(reason)}"
    end
  end

  defp resolve_scene_module(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        if function_exported?(module, :__scene_def__, 0) do
          case module.__scene_def__() do
            %Def{} = scene_def -> {:ok, scene_def}
            nil -> {:error, {:no_scene_def, module}}
          end
        else
          {:error, {:not_a_scene, module}}
        end

      {:error, _} ->
        {:error, {:module_not_found, module}}
    end
  end

  defp check_property_conflicts(%NodeDef{prefab: prefab, entity: entity})
       when is_atom(prefab) and prefab != nil and is_atom(entity) and entity != nil do
    prefab_spec = Lunity.Properties.property_spec(prefab)
    entity_spec = Lunity.Properties.property_spec(entity)

    if prefab_spec && entity_spec do
      prefab_keys = Map.keys(prefab_spec) |> MapSet.new()
      entity_keys = Map.keys(entity_spec) |> MapSet.new()
      conflicts = MapSet.intersection(prefab_keys, entity_keys)

      unless MapSet.size(conflicts) == 0 do
        raise ArgumentError,
              "Property conflict between prefab #{inspect(prefab)} and entity #{inspect(entity)}: " <>
                "#{inspect(MapSet.to_list(conflicts))} declared in both"
      end
    end
  end

  defp check_property_conflicts(_node_def), do: :ok

  defp generate_entity_id do
    :erlang.unique_integer([:positive])
  end
end
