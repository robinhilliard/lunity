defmodule Lunity.Material do
  @moduledoc """
  A material defines the visual appearance of a mesh surface.

  Materials are the bridge between artistic intent (base color, roughness, etc.)
  and shader uniforms. A `%Material{}` can be:

  - Defined in code via the `Lunity.Materials` DSL
  - Imported from a GLB file via `import_glb`
  - Created inline as a map shorthand in scene nodes

  ## PBR properties

  The struct uses PBR Metallic-Roughness terminology (the glTF 2.0 standard):

  - `:base_color` - `{r, g, b}` surface color or texture tint (default white)
  - `:metallic` - `0.0` (dielectric/plastic) to `1.0` (metal)
  - `:roughness` - `0.0` (mirror) to `1.0` (chalk)
  - `:emissive` - `{r, g, b}` glow color (default black / no glow)
  - `:alpha_mode` - `:opaque`, `:mask`, or `:blend`
  - `:alpha_cutoff` - threshold for `:mask` mode
  - `:double_sided` - whether backfaces are rendered
  - `:textures` - map of texture IDs keyed by type (`:base_color`, `:normal`, etc.)
  """

  defstruct name: nil,
            base_color: {1.0, 1.0, 1.0},
            metallic: 1.0,
            roughness: 1.0,
            emissive: {0.0, 0.0, 0.0},
            alpha_mode: :opaque,
            alpha_cutoff: 0.5,
            double_sided: false,
            textures: %{}

  @type t :: %__MODULE__{
          name: atom() | String.t() | nil,
          base_color: {float(), float(), float()},
          metallic: float(),
          roughness: float(),
          emissive: {float(), float(), float()},
          alpha_mode: :opaque | :mask | :blend,
          alpha_cutoff: float(),
          double_sided: boolean(),
          textures: %{optional(atom()) => non_neg_integer()}
        }

  @doc """
  Create a material from a keyword list of PBR properties.

      Lunity.Material.new(base_color: {0.8, 0.2, 0.2}, metallic: 0.0, roughness: 0.5)
  """
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Create a `%Lunity.Material{}` from a plain map (inline shorthand in scene nodes).

      Lunity.Material.from_map(%{base_color: {1, 1, 1}, roughness: 0.3})
  """
  def from_map(map) when is_map(map) do
    opts =
      map
      |> Enum.map(fn {k, v} -> {to_existing_atom(k), v} end)
      |> Enum.filter(fn {k, _} -> k in fields() end)

    struct(__MODULE__, opts)
  end

  @doc """
  Convert a `%GLTF.Material{}` to a `%Lunity.Material{}`.
  """
  def from_gltf_material(%{__struct__: GLTF.Material} = gltf_mat) do
    pbr = gltf_mat.pbr_metallic_roughness

    base_color =
      case pbr && pbr.base_color_factor do
        [r, g, b | _] -> {r, g, b}
        _ -> {1.0, 1.0, 1.0}
      end

    %__MODULE__{
      name: gltf_mat.name,
      base_color: base_color,
      metallic: (pbr && pbr.metallic_factor) || 1.0,
      roughness: (pbr && pbr.roughness_factor) || 1.0,
      emissive: list_to_tuple3(gltf_mat.emissive_factor || [0.0, 0.0, 0.0]),
      alpha_mode: gltf_mat.alpha_mode || :opaque,
      alpha_cutoff: gltf_mat.alpha_cutoff || 0.5,
      double_sided: gltf_mat.double_sided || false,
      textures: %{}
    }
  end

  @doc """
  Convert a material to a keyword list of shader uniform name/value pairs
  suitable for the PBR shader.

  The returned list can be passed directly to `EAGL.Shader.set_uniforms/2`.
  """
  def to_pbr_uniforms(%__MODULE__{} = mat) do
    {br, bg, bb} = mat.base_color
    {er, eg, eb} = mat.emissive

    [
      "material.baseColor": [{br, bg, bb}],
      "material.metallic": mat.metallic,
      "material.roughness": mat.roughness,
      "material.emissive": [{er, eg, eb}]
    ]
  end

  @doc """
  Convert a material to a keyword list of shader uniform name/value pairs
  suitable for the Phong shader.
  """
  def to_phong_uniforms(%__MODULE__{} = mat) do
    {r, g, b} = mat.base_color
    [objectColor: [{r, g, b}]]
  end

  defp fields do
    [
      :name,
      :base_color,
      :metallic,
      :roughness,
      :emissive,
      :alpha_mode,
      :alpha_cutoff,
      :double_sided,
      :textures
    ]
  end

  defp to_existing_atom(key) when is_atom(key), do: key
  defp to_existing_atom(key) when is_binary(key), do: String.to_existing_atom(key)

  defp list_to_tuple3([x, y, z | _]), do: {x, y, z}
  defp list_to_tuple3(_), do: {0.0, 0.0, 0.0}
end
