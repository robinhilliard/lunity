defmodule Lunity.Materials do
  @moduledoc """
  DSL for defining material palettes.

  Use `material/2` to define named materials and `import_glb/2` to extract
  materials from Blender-authored GLB files. Each material becomes a zero-arity
  function returning a `%Lunity.Material{}` struct, giving full language server
  support (autocomplete, go-to-definition, compile-time errors).

  ## Example

      defmodule MyGame.Materials do
        use Lunity.Materials

        material :white_plastic, base_color: {1, 1, 1}, metallic: 0.0, roughness: 0.5
        material :red_metal,     base_color: {0.8, 0.1, 0.1}, metallic: 1.0, roughness: 0.3

        import_glb "materials/library.glb"
        import_glb "materials/metals.glb", prefix: :metal
      end

  Then in scenes:

      node :ball, prefab: MyGame.Prefabs.Box,
                  material: MyGame.Materials.white_plastic

  """

  defmacro __using__(_opts) do
    quote do
      import Lunity.Materials, only: [material: 2, import_glb: 1, import_glb: 2]
    end
  end

  @doc """
  Define a named material. Generates a zero-arity function that returns
  a `%Lunity.Material{}` struct.

      material :white_plastic, base_color: {1, 1, 1}, metallic: 0.0, roughness: 0.5

  Supported options: `:base_color`, `:metallic`, `:roughness`, `:emissive`,
  `:alpha_mode`, `:alpha_cutoff`, `:double_sided`.
  """
  defmacro material(name, opts) do
    quote do
      @doc "Material: #{unquote(name)}"
      def unquote(name)() do
        %Lunity.Material{
          name: unquote(name),
          base_color: Keyword.get(unquote(opts), :base_color, {1.0, 1.0, 1.0}),
          metallic: Keyword.get(unquote(opts), :metallic, 1.0),
          roughness: Keyword.get(unquote(opts), :roughness, 1.0),
          emissive: Keyword.get(unquote(opts), :emissive, {0.0, 0.0, 0.0}),
          alpha_mode: Keyword.get(unquote(opts), :alpha_mode, :opaque),
          alpha_cutoff: Keyword.get(unquote(opts), :alpha_cutoff, 0.5),
          double_sided: Keyword.get(unquote(opts), :double_sided, false)
        }
      end
    end
  end

  @doc """
  Import materials from a GLB file. At compile time, the GLB is parsed and
  a function is generated for each material found, named after the glTF
  material name (snake_cased).

      import_glb "materials/library.glb"
      import_glb "materials/metals.glb", prefix: :metal

  With `prefix: :metal`, a material named "Copper" in the GLB becomes
  `metal_copper/0`.

  Textures are not loaded at compile time -- only scalar PBR factors are
  extracted. The `textures` field contains `{:lazy, glb_path, material_index}`
  for deferred GPU upload at runtime.
  """
  defmacro import_glb(path, opts \\ []) do
    caller_file = __CALLER__.file
    priv_dir = find_priv_dir(caller_file)

    glb_path =
      if priv_dir do
        Path.join(priv_dir, path)
      else
        path
      end

    materials = extract_materials_from_glb(glb_path)
    prefix = Keyword.get(opts, :prefix)

    for {mat_name, mat_data, index} <- materials do
      func_name = material_function_name(mat_name, prefix)

      quote do
        @doc "Material imported from #{unquote(path)}: #{unquote(mat_name)}"
        def unquote(func_name)() do
          %Lunity.Material{
            name: unquote(func_name),
            base_color: unquote(Macro.escape(mat_data.base_color)),
            metallic: unquote(mat_data.metallic),
            roughness: unquote(mat_data.roughness),
            emissive: unquote(Macro.escape(mat_data.emissive)),
            alpha_mode: unquote(mat_data.alpha_mode),
            alpha_cutoff: unquote(mat_data.alpha_cutoff),
            double_sided: unquote(mat_data.double_sided),
            textures: %{_glb_source: {unquote(glb_path), unquote(index)}}
          }
        end
      end
    end
  end

  @doc false
  def extract_materials_from_glb(glb_path) do
    case File.read(glb_path) do
      {:ok, binary} ->
        case GLTF.GLBLoader.parse_binary(binary) do
          {:ok, glb} ->
            case GLTF.GLBLoader.load_gltf_from_glb(glb) do
              {:ok, gltf} ->
                (gltf.materials || [])
                |> Enum.with_index()
                |> Enum.map(fn {mat, index} ->
                  lunity_mat = Lunity.Material.from_gltf_material(mat)
                  name = mat.name || "material_#{index}"
                  {name, lunity_mat, index}
                end)

              _ ->
                []
            end

          _ ->
            []
        end

      {:error, reason} ->
        IO.warn("import_glb: could not read #{glb_path}: #{inspect(reason)}")
        []
    end
  end

  @doc false
  def material_function_name(name, prefix) do
    snake =
      name
      |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
      |> Macro.underscore()
      |> String.trim_leading("_")
      |> String.trim_trailing("_")
      |> String.downcase()

    if prefix do
      :"#{prefix}_#{snake}"
    else
      String.to_atom(snake)
    end
  end

  defp find_priv_dir(caller_file) do
    dir = Path.dirname(caller_file)
    find_priv_dir_up(dir)
  end

  defp find_priv_dir_up("/"), do: nil
  defp find_priv_dir_up(""), do: nil
  defp find_priv_dir_up("."), do: nil

  defp find_priv_dir_up(dir) do
    priv = Path.join(dir, "priv")

    if File.dir?(priv) do
      priv
    else
      find_priv_dir_up(Path.dirname(dir))
    end
  end
end
