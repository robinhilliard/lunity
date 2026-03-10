defmodule Lunity.Entity do
  @moduledoc """
  Entity type definition for Lunity's component system.

  Use `use Lunity.Entity` and define an `entity do...end` block to create
  an entity type module that:
  - Declares properties (input schema for validation)
  - Implements `init(config, entity_id)` to add components
  - Optionally implements `update(entity_id, delta_ms)` for per-tick logic

  ## Example

      defmodule MyGame.Door do
        use Lunity.Entity, config: "scenes/doors/default"

        entity do
          property :open_angle, :float, default: 90, min: 0, max: 360
          property :health,     :integer, default: 100, min: 0
          property :key_id,     :string
        end

        @impl Lunity.Entity
        def init(config, entity_id) do
          Lunity.ComponentStore.put(MyGame.Components.Health, entity_id, config.health)
          Lunity.ComponentStore.put(MyGame.Components.Openable, entity_id, config.open_angle)
          :ok
        end
      end

  ## Options for `use`

  - `:config` - Default config path relative to `priv/config/` (e.g. `"doors/default"`)

  ## Property types

  See `Lunity.Properties` for the full list of supported types and options.
  """

  @callback init(config :: struct(), entity_id :: term()) :: :ok
  @optional_callbacks [update: 2]

  @doc """
  Optional callback for per-tick logic. Called each tick if implemented.
  """
  @callback update(entity_id :: term(), delta_ms :: non_neg_integer()) :: :ok

  defmacro __using__(opts) do
    quote do
      @behaviour Lunity.Entity
      import Lunity.Properties, only: [property: 2, property: 3]
      import Lunity.Entity, only: [entity: 1, component: 1]
      Module.register_attribute(__MODULE__, :lunity_properties, accumulate: true)
      Module.register_attribute(__MODULE__, :lunity_components, accumulate: true)
      @lunity_config_path unquote(Keyword.get(opts, :config))
      @before_compile Lunity.Entity
    end
  end

  @doc """
  Declares properties for this entity type.
  """
  defmacro entity(do: block) do
    quote do
      @lunity_entity_defined true
      unquote(block)
    end
  end

  @doc """
  Declares a component type attached to this entity and aliases the module.
  """
  defmacro component(module) do
    quote do
      @lunity_components unquote(module)
      alias unquote(module)
    end
  end

  defmacro __before_compile__(env) do
    properties = Module.get_attribute(env.module, :lunity_properties) |> Enum.reverse()
    components = Module.get_attribute(env.module, :lunity_components) |> Enum.reverse()
    config_path = Module.get_attribute(env.module, :lunity_config_path)

    struct_fields = Lunity.Properties.build_struct_fields(properties)
    property_spec = Lunity.Properties.build_property_spec(properties)
    type_fields = Lunity.Properties.build_type_fields(properties)

    struct_type =
      {:%, [],
       [
         {:__MODULE__, [], Elixir},
         {:%{}, [], Enum.map(type_fields, fn {k, v} -> {k, v} end)}
       ]}

    quote do
      defstruct unquote(struct_fields)

      @type t :: unquote(struct_type)

      @doc false
      def __property_spec__, do: unquote(Macro.escape(property_spec))

      @doc false
      def __config_path__, do: unquote(config_path)

      @doc false
      def __components__, do: unquote(components)
    end
  end

  defdelegate property_spec(module), to: Lunity.Properties
  defdelegate validate_properties(module, properties), to: Lunity.Properties
  defdelegate from_config(module, merged_config), to: Lunity.Properties
  defdelegate resolve_module(name), to: Lunity.Properties

  @doc """
  Returns the list of component modules declared for an entity module.
  """
  def components(module) do
    if function_exported?(module, :__components__, 0) do
      module.__components__()
    else
      []
    end
  end

  @doc """
  Returns the default config path for an entity module, or nil.
  """
  def config_path(module) do
    if function_exported?(module, :__config_path__, 0) do
      module.__config_path__()
    else
      nil
    end
  end
end
