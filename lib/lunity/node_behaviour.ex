defmodule Lunity.NodeBehaviour do
  @moduledoc """
  Behaviour for node-linked ECSx entities.

  Use `use Lunity.NodeBehaviour` and define `behaviour_properties` to create
  a behaviour module that:
  - Defines the extras schema (for validation and Blender template injection)
  - Implements `init(config, entity_id)` to add ECSx components
  - Optionally implements `update(entity_id, delta_ms)` for per-tick logic

  The loader creates the entity via `ECSx.add_entity/1` (or equivalent),
  then calls `behaviour.init(merged_config, entity_id)`.

  ## Example

      defmodule MyGame.Behaviours.Door do
        use Lunity.NodeBehaviour

        behaviour_properties [
          behaviour: [type: :string, default: "MyGame.Behaviours.Door"],
          config: [type: :string, default: "scenes/doors/default"],
          open_angle: [type: :float, default: 90, min: 0, max: 360],
          health: [type: :integer, default: 100, min: 0],
          key_id: [type: :string]
        ]

        @impl Lunity.NodeBehaviour
        def init(config, entity_id) do
          Health.add(entity_id, config[:health] || 100)
          Openable.add(entity_id, config[:open_angle] || 90)
          :ok
        end
      end
  """

  @callback init(config :: map(), entity_id :: term()) :: :ok
  @optional_callbacks [update: 2]

  @doc """
  Optional callback for per-tick logic. Called each ECSx tick if implemented.
  """
  @callback update(entity_id :: term(), delta_ms :: non_neg_integer()) :: :ok

  defmacro __using__(_opts) do
    quote do
      @behaviour Lunity.NodeBehaviour
      import Lunity.NodeBehaviour, only: [behaviour_properties: 1]
    end
  end

  @doc """
  Defines behaviour properties (extras schema) and generates a struct.

  Each property is `name: [type: :string | :integer | :float, default: value, min: n, max: n]`.
  Expands to a `defstruct` and `@extras_spec` module attribute.
  """
  defmacro behaviour_properties(properties) do
    {struct_fields, extras_spec} = build_properties(properties)

    quote do
      defstruct unquote(struct_fields)

      def __extras_spec__ do
        unquote(Macro.escape(extras_spec))
      end
    end
  end

  @doc """
  Returns the extras spec for a behaviour module.
  """
  def extras_spec(module) do
    if function_exported?(module, :__extras_spec__, 0) do
      module.__extras_spec__()
    else
      nil
    end
  end

  @doc """
  Validates extras against the behaviour module's spec.

  Returns `:ok` or `{:error, reason}`.
  """
  def validate_extras(module, extras) when is_map(extras) do
    spec = extras_spec(module)
    if spec, do: do_validate_extras(spec, extras), else: :ok
  end

  def validate_extras(_module, _extras), do: {:error, :extras_must_be_map}

  @doc """
  Builds a struct from merged config using the behaviour's defaults.
  """
  def from_config(module, merged_config) when is_map(merged_config) do
    spec = extras_spec(module)
    if spec do
      struct(module, Enum.map(spec, fn {key, opts} ->
        value = Map.get(merged_config, key) || Map.get(merged_config, to_string(key)) || opts[:default]
        {key, value}
      end))
    else
      struct(module, merged_config)
    end
  end

  @doc """
  Resolves a behaviour name (string from extras) to a module.
  """
  def resolve_module(name) when is_binary(name) do
    name
    |> String.split(".")
    |> Module.safe_concat()
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_properties(properties) when is_list(properties) do
    struct_fields =
      Enum.map(properties, fn
        {name, opts} when is_list(opts) ->
          default = Keyword.get(opts, :default)
          {name, default}
        {name, _} ->
          {name, nil}
      end)

    extras_spec =
      Enum.map(properties, fn
        {name, opts} when is_list(opts) ->
          {name, opts}
        {name, _} ->
          {name, []}
      end)
      |> Map.new()

    {struct_fields, extras_spec}
  end

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
end
