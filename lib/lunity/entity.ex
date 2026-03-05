defmodule Lunity.Entity do
  @moduledoc """
  Entity type definition for ECSx integration.

  Use `use Lunity.Entity` and define an `entity do...end` block to create
  an entity type module that:
  - Declares properties (input schema for validation)
  - Declares ECSx components (for introspection by editor and MCP tools)
  - Implements `init(config, entity_id)` to add ECSx components
  - Optionally implements `update(entity_id, delta_ms)` for per-tick logic

  ## Example

      defmodule MyGame.Door do
        use Lunity.Entity, config: "scenes/doors/default"

        entity do
          property :open_angle, :float, default: 90, min: 0, max: 360
          property :health,     :integer, default: 100, min: 0
          property :key_id,     :string

          component MyGame.Components.Health
          component MyGame.Components.Openable
        end

        @impl Lunity.Entity
        def init(config, entity_id) do
          ECSx.add(entity_id, MyGame.Components.Health, %{value: config.health})
          ECSx.add(entity_id, MyGame.Components.Openable, %{angle: config.open_angle})
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
  Optional callback for per-tick logic. Called each ECSx tick if implemented.
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
  Declares properties and components for this entity type.
  """
  defmacro entity(do: block) do
    quote do
      @lunity_entity_defined true
      unquote(block)
    end
  end

  @doc """
  Declares an ECSx component used by this entity type.
  """
  defmacro component(module) do
    quote do
      @lunity_components unquote(module)
    end
  end

  defmacro __before_compile__(env) do
    properties = Module.get_attribute(env.module, :lunity_properties) |> Enum.reverse()
    components = Module.get_attribute(env.module, :lunity_components) |> Enum.reverse()
    config_path = Module.get_attribute(env.module, :lunity_config_path)

    struct_fields = Lunity.Properties.build_struct_fields(properties)
    extras_spec = Lunity.Properties.build_extras_spec(properties)

    quote do
      defstruct unquote(struct_fields)

      @doc false
      def __extras_spec__, do: unquote(Macro.escape(extras_spec))

      @doc false
      def __components__, do: unquote(components)

      @doc false
      def __config_path__, do: unquote(config_path)
    end
  end

  # Delegate introspection and validation to Properties
  defdelegate extras_spec(module), to: Lunity.Properties
  defdelegate validate_extras(module, extras), to: Lunity.Properties
  defdelegate from_config(module, merged_config), to: Lunity.Properties
  defdelegate resolve_module(name), to: Lunity.Properties

  @doc """
  Returns the list of ECSx component modules for an entity module.
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
