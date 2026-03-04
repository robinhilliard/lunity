defmodule Lunity.Entity do
  @moduledoc """
  Entity type definition for ECSx integration.

  Use `use Lunity.Entity` and define an `entity do...end` block to create
  an entity type module that:
  - Declares properties (input schema for validation and Blender template injection)
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

  - `:string` - Binary string
  - `:integer` - Integer with optional `min:`, `max:` constraints
  - `:float` - Number (integer or float) with optional `min:`, `max:` constraints
  - `:atom` - Atom with optional `values: [...]` constraint for enum validation
  - `:boolean` - Boolean value
  - `:module` - Module atom (verified loaded at validation time)
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
      import Lunity.Entity, only: [entity: 1, property: 2, property: 3, component: 1]
      Module.register_attribute(__MODULE__, :lunity_properties, accumulate: true)
      Module.register_attribute(__MODULE__, :lunity_components, accumulate: true)
      @lunity_config_path unquote(Keyword.get(opts, :config))
      @before_compile Lunity.Entity
    end
  end

  @doc """
  Declares properties and components for this entity type.

  Contains `property` and `component` declarations.
  """
  defmacro entity(do: block) do
    quote do
      @lunity_entity_defined true
      unquote(block)
    end
  end

  @doc """
  Declares a property with name, type, and optional constraints.

  ## Options

  - `:default` - Default value
  - `:min` - Minimum value (for `:integer` and `:float`)
  - `:max` - Maximum value (for `:integer` and `:float`)
  - `:values` - Allowed values list (for `:atom`)
  """
  defmacro property(name, type, opts \\ []) do
    quote do
      @lunity_properties {unquote(name), unquote(type), unquote(opts)}
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

    struct_fields = Lunity.Entity.build_struct_fields(properties)
    extras_spec = Lunity.Entity.build_extras_spec(properties)

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

  # ---------------------------------------------------------------------------
  # Compile-time helpers (called from __before_compile__)
  # ---------------------------------------------------------------------------

  @doc false
  def build_struct_fields(properties) do
    Enum.map(properties, fn {name, _type, opts} ->
      {name, Keyword.get(opts, :default)}
    end)
  end

  @doc false
  def build_extras_spec(properties) do
    properties
    |> Enum.map(fn {name, type, opts} ->
      {name, Keyword.put(opts, :type, type)}
    end)
    |> Map.new()
  end

  # ---------------------------------------------------------------------------
  # Runtime introspection
  # ---------------------------------------------------------------------------

  @doc """
  Returns the extras spec for an entity module.
  """
  def extras_spec(module) do
    if function_exported?(module, :__extras_spec__, 0) do
      module.__extras_spec__()
    else
      nil
    end
  end

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

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  @doc """
  Validates extras against the entity module's spec.

  Returns `:ok` or `{:error, reasons}`.
  """
  def validate_extras(module, extras) when is_map(extras) do
    spec = extras_spec(module)
    if spec, do: do_validate_extras(spec, extras), else: :ok
  end

  def validate_extras(_module, _extras), do: {:error, :extras_must_be_map}

  @doc """
  Builds a struct from merged config using the entity's defaults.
  """
  def from_config(module, merged_config) when is_map(merged_config) do
    spec = extras_spec(module)

    if spec do
      struct(
        module,
        Enum.map(spec, fn {key, opts} ->
          value =
            Map.get(merged_config, key) || Map.get(merged_config, to_string(key)) ||
              opts[:default]

          {key, value}
        end)
      )
    else
      struct(module, merged_config)
    end
  end

  @doc """
  Resolves an entity name (string from glTF extras) to a module atom.
  """
  def resolve_module(name) when is_binary(name) do
    name
    |> String.split(".")
    |> Module.safe_concat()
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_validate_extras(spec, extras) do
    errors =
      Enum.flat_map(spec, fn {key, opts} ->
        value = Map.get(extras, key) || Map.get(extras, to_string(key))
        validate_value(key, value, opts)
      end)

    case errors do
      [] -> :ok
      list -> {:error, list}
    end
  end

  defp validate_value(_key, nil, _opts), do: []

  defp validate_value(key, value, opts) do
    errors = []

    errors =
      if type = opts[:type] do
        case type_check(value, type) do
          :ok -> errors
          {:error, msg} -> [{key, msg} | errors]
        end
      else
        errors
      end

    errors =
      if allowed = opts[:values] do
        if value in allowed do
          errors
        else
          [{key, "must be one of #{inspect(allowed)}"} | errors]
        end
      else
        errors
      end

    min_val = opts[:min]

    errors =
      if min_val && is_number(value) && value < min_val do
        [{key, "must be >= #{min_val}"} | errors]
      else
        errors
      end

    max_val = opts[:max]

    errors =
      if max_val && is_number(value) && value > max_val do
        [{key, "must be <= #{max_val}"} | errors]
      else
        errors
      end

    Enum.reverse(errors)
  end

  defp type_check(value, :string) when is_binary(value), do: :ok
  defp type_check(value, :string) when is_atom(value), do: :ok
  defp type_check(_, :string), do: {:error, "must be string"}

  defp type_check(value, :integer) when is_integer(value), do: :ok
  defp type_check(_, :integer), do: {:error, "must be integer"}

  defp type_check(value, :float) when is_float(value), do: :ok
  defp type_check(value, :float) when is_integer(value), do: :ok
  defp type_check(_, :float), do: {:error, "must be number"}

  defp type_check(value, :atom) when is_atom(value), do: :ok
  defp type_check(_, :atom), do: {:error, "must be atom"}

  defp type_check(value, :boolean) when is_boolean(value), do: :ok
  defp type_check(_, :boolean), do: {:error, "must be boolean"}

  defp type_check(value, :module) when is_atom(value) do
    case Code.ensure_loaded(value) do
      {:module, _} -> :ok
      {:error, _} -> {:error, "module #{inspect(value)} is not available"}
    end
  end

  defp type_check(_, :module), do: {:error, "must be a module atom"}
end
