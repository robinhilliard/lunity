defmodule Lunity.PrefabLoader do
  @moduledoc """
  Load and instantiate prefabs (reusable glTF + config templates).

  A prefab is a mini-scene: `priv/prefabs/<id>.glb` plus config at
  `priv/config/prefabs/<id>.exs`. Use `load_prefab/2` to load, and
  `instantiate_prefab/4` to clone and attach to a parent node.

  ## Shader

  When `opts[:shader_program]` is omitted, uses `GLTF.EAGL.create_pbr_shader/0`
  (matches glTF spec and Blender export). Override for Phong, flat, or custom.

  ## OpenGL context

  `load_prefab/2` requires an active OpenGL context (creates VAOs). Call after
  the window is created.

  ## Examples

      # Load prefab (requires GL context)
      {:ok, scene, config} = Lunity.PrefabLoader.load_prefab("crate")

      # Instantiate and attach to parent
      {:ok, parent, merged_config} =
        Lunity.PrefabLoader.instantiate_prefab("crate", parent_node, %{health: 50})

      # From pre-loaded (e.g. for caching or testing)
      {:ok, parent, merged_config} =
        Lunity.PrefabLoader.instantiate_prefab_from_loaded(scene, config, parent_node, %{})
  """

  alias EAGL.{Node, Scene}
  alias Lunity.ConfigLoader

  @doc """
  Load a prefab by id.

  Loads glTF from `priv/prefabs/<id>.glb` and config from
  `priv/config/prefabs/<id>.exs`. Config is optional; missing config uses `%{}`.

  ## Options

  - `:app` - Application whose priv dir to use (default: current application)
  - `:shader_program` - OpenGL shader program for meshes (default: PBR shader)

  ## Returns

  - `{:ok, scene, config}` - EAGL.Scene and config map
  - `{:error, :path_traversal}` - Invalid id (contains `..` or absolute path)
  - `{:error, :file_not_found}` - glTF file does not exist
  - `{:error, reason}` - Other load error (e.g. from GLTF.EAGL.load_scene)

  ## Examples

      {:ok, scene, config} = Lunity.PrefabLoader.load_prefab("crate")
      {:ok, scene, config} = Lunity.PrefabLoader.load_prefab("props/crate", app: :my_game)
  """
  @spec load_prefab(String.t(), keyword()) ::
          {:ok, Scene.t(), map()} | {:error, term()}
  def load_prefab(id, opts \\ []) do
    with :ok <- validate_prefab_id(id),
         {:ok, glb_path} <- prefab_glb_path(id, opts),
         :ok <- ensure_glb_exists(glb_path),
         {:ok, config} <- load_prefab_config(id, opts),
         {:ok, shader_program} <- shader_for_opts(opts),
         {:ok, scene, _gltf, _data_store} <- GLTF.EAGL.load_scene(glb_path, shader_program, opts) do
      {:ok, scene, config}
    end
  end

  @doc """
  Instantiate a prefab and attach its roots to a parent node.

  Loads the prefab (or uses cache if provided), clones the scene graph, merges
  config overrides, and attaches the cloned roots as children of the parent.
  Returns the updated parent and merged config.

  ## Options

  - `:app` - Application for prefab resolution
  - `:shader_program` - Shader for load (when loading)

  ## Returns

  - `{:ok, parent, merged_config}` - Parent with prefab roots attached
  - `{:error, reason}` - Load or validation error

  ## Examples

      {:ok, parent, config} =
        Lunity.PrefabLoader.instantiate_prefab("crate", parent_node, %{health: 50})
  """
  @spec instantiate_prefab(String.t(), Node.t(), map() | nil, keyword()) ::
          {:ok, Node.t(), map()} | {:error, term()}
  def instantiate_prefab(id, parent, overrides \\ %{}, opts \\ []) do
    with {:ok, scene, config} <- load_prefab(id, opts) do
      instantiate_prefab_from_loaded(scene, config, parent, overrides)
    end
  end

  @doc """
  Instantiate from an already-loaded prefab (scene + config).

  Clones the scene graph (structure only; meshes are shared), merges config
  overrides, and attaches the cloned roots to the parent. Use for caching or
  when you have pre-loaded data.

  ## Returns

  - `{:ok, parent, merged_config}` - Parent with prefab roots attached

  ## Examples

      {:ok, scene, config} = Lunity.PrefabLoader.load_prefab("crate")
      {:ok, parent, merged} =
        Lunity.PrefabLoader.instantiate_prefab_from_loaded(scene, config, parent_node, %{})
  """
  @spec instantiate_prefab_from_loaded(Scene.t(), map(), Node.t(), map() | nil) ::
          {:ok, Node.t(), map()}
  def instantiate_prefab_from_loaded(scene, config, parent, overrides \\ %{}) do
    merged_config = ConfigLoader.merge_config(config, overrides)
    cloned_roots = Enum.map(scene.root_nodes, &clone_node/1)

    updated_parent =
      Enum.reduce(cloned_roots, parent, fn root, acc -> Node.add_child(acc, root) end)

    {:ok, updated_parent, merged_config}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_prefab_id(id) do
    cond do
      not is_binary(id) -> {:error, :path_traversal}
      id == "" -> {:error, :path_traversal}
      String.contains?(id, "..") -> {:error, :path_traversal}
      String.starts_with?(id, "/") -> {:error, :path_traversal}
      true -> :ok
    end
  end

  defp prefab_glb_path(id, opts) do
    app = Keyword.get(opts, :app, current_app())
    priv_dir = Lunity.priv_dir_for_app(app)
    prefabs_dir = Path.join(priv_dir, "prefabs")
    path = Path.join(prefabs_dir, ensure_glb_suffix(id))

    expanded = Path.expand(path)
    prefabs_expanded = Path.expand(prefabs_dir)

    if String.starts_with?(expanded, prefabs_expanded) do
      {:ok, path}
    else
      {:error, :path_traversal}
    end
  end

  defp ensure_glb_suffix(id) do
    if String.ends_with?(id, ".glb"), do: id, else: id <> ".glb"
  end

  defp ensure_glb_exists(path) do
    if File.exists?(path), do: :ok, else: {:error, :file_not_found}
  end

  defp load_prefab_config(id, opts) do
    config_path = "prefabs/#{id}"
    opts_with_app = Keyword.take(opts, [:app])

    case ConfigLoader.load_config(config_path, opts_with_app) do
      {:ok, config} -> {:ok, config}
      {:error, :file_not_found} -> {:ok, %{}}
      {:error, _} = err -> err
    end
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

  # Clone node structure; share mesh, camera, animations (references).
  # Recursively clone children and set parent refs to the final cloned node.
  defp clone_node(%Node{} = node) do
    cloned_children = Enum.map(node.children || [], &clone_node/1)

    cloned_node = %Node{
      position: node.position,
      rotation: node.rotation,
      scale: node.scale,
      matrix: node.matrix,
      children: cloned_children,
      parent: nil,
      mesh: node.mesh,
      camera: node.camera,
      name: node.name,
      properties: if(node.properties, do: Map.new(node.properties), else: nil),
      animations: node.animations
    }

    updated_children = Enum.map(cloned_children, fn c -> %{c | parent: cloned_node} end)
    %{cloned_node | children: updated_children}
  end
end
