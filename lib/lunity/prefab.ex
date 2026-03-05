defmodule Lunity.Prefab do
  @moduledoc """
  Prefab definition for visual assets with typed properties.

  A Lunity prefab is a visual asset (.glb) with typed properties -- no nesting,
  no variants, no override chains. Prefab properties are visual/physical and
  editable in Blender. Entity properties (game logic) are separate.

  Use `use Lunity.Prefab` and define a `prefab do...end` block to create a
  prefab module that:
  - Links to a `.glb` file via the `:glb` option
  - Declares typed properties (for validation and Blender custom property generation)
  - Generates a struct with defaults and an extras spec for introspection

  ## Example

      defmodule MyGame.Prefabs.Door do
        use Lunity.Prefab, glb: "door"

        prefab do
          property :open_angle, :float,
            default: 90.0, min: 0.0, max: 180.0,
            subtype: :angle,
            description: "Maximum angle the door opens to"

          property :color, :float_array,
            length: 4, default: [0.5, 0.5, 0.5, 1.0],
            subtype: :gamma_color,
            description: "Door tint color (RGBA)"

          property :material, :atom,
            values: [:wood, :metal, :glass], default: :wood,
            description: "Material type for physics and sound"
        end
      end

  ## Options for `use`

  - `:glb` - GLB file ID relative to `priv/prefabs/` (e.g. `"door"` loads `priv/prefabs/door.glb`)

  ## Property types and options

  See `Lunity.Properties` for the full list of supported types and options,
  including Blender-specific metadata (`:soft_min`, `:soft_max`, `:step`,
  `:precision`, `:subtype`, `:description`).
  """

  defmacro __using__(opts) do
    glb = Keyword.get(opts, :glb)

    unless glb do
      raise ArgumentError,
            "use Lunity.Prefab requires a :glb option (e.g. use Lunity.Prefab, glb: \"door\")"
    end

    quote do
      import Lunity.Properties, only: [property: 2, property: 3]
      import Lunity.Prefab, only: [prefab: 1]
      Module.register_attribute(__MODULE__, :lunity_properties, accumulate: true)
      @lunity_glb_id unquote(glb)
      @before_compile Lunity.Prefab
    end
  end

  @doc """
  Declares properties for this prefab.
  """
  defmacro prefab(do: block) do
    quote do
      @lunity_prefab_defined true
      unquote(block)
    end
  end

  defmacro __before_compile__(env) do
    properties = Module.get_attribute(env.module, :lunity_properties) |> Enum.reverse()
    glb_id = Module.get_attribute(env.module, :lunity_glb_id)

    struct_fields = Lunity.Properties.build_struct_fields(properties)
    extras_spec = Lunity.Properties.build_extras_spec(properties)

    quote do
      defstruct unquote(struct_fields)

      @doc false
      def __extras_spec__, do: unquote(Macro.escape(extras_spec))

      @doc false
      def __glb_id__, do: unquote(glb_id)
    end
  end

  # Delegate introspection and validation to Properties
  defdelegate extras_spec(module), to: Lunity.Properties
  defdelegate validate_extras(module, extras), to: Lunity.Properties
  defdelegate from_config(module, merged_config), to: Lunity.Properties
  defdelegate resolve_module(name), to: Lunity.Properties

  @doc """
  Returns the GLB file ID for a prefab module.
  """
  def glb_id(module) do
    if function_exported?(module, :__glb_id__, 0) do
      module.__glb_id__()
    else
      nil
    end
  end
end
