defmodule Lunity.Properties do
  @moduledoc """
  Shared property infrastructure for Entity and Prefab DSLs.

  Provides macros for declaring typed properties, compile-time struct generation,
  and runtime validation. Both `Lunity.Entity` and `Lunity.Prefab` delegate to
  this module for consistent property handling.

  ## Property types

  - `:string` - Binary string
  - `:integer` - Integer
  - `:float` - Number (integer or float)
  - `:atom` - Atom
  - `:boolean` - Boolean
  - `:module` - Module atom (verified loaded at validation time)
  - `:float_array` - List of floats (with `:length`)
  - `:integer_array` - List of integers (with `:length`)
  - `:boolean_array` - List of booleans (with `:length`)

  ## Property options

  - `:default` - Default value
  - `:min`, `:max` - Hard limits (for numeric types)
  - `:soft_min`, `:soft_max` - Soft limits (UI slider range in Blender)
  - `:step` - Increment multiplier
  - `:precision` - Decimal digits displayed (floats only)
  - `:subtype` - UI presentation hint for Blender
  - `:description` - Tooltip text
  - `:values` - Allowed values list (for `:atom`)
  - `:length` - Array length (for array types)
  """

  @doc """
  Declares a property with name, type, and optional constraints.
  Accumulates into `@lunity_properties` module attribute.
  """
  defmacro property(name, type, opts \\ []) do
    quote do
      @lunity_properties {unquote(name), unquote(type), unquote(opts)}
    end
  end

  # ---------------------------------------------------------------------------
  # Compile-time helpers (called from __before_compile__ in Entity/Prefab)
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
  Returns the extras spec for a module with properties.
  """
  def extras_spec(module) do
    if function_exported?(module, :__extras_spec__, 0) do
      module.__extras_spec__()
    else
      nil
    end
  end

  @doc """
  Validates extras against a module's property spec.

  Returns `:ok` or `{:error, reasons}`.
  """
  def validate_extras(module, extras) when is_map(extras) do
    spec = extras_spec(module)
    if spec, do: do_validate_extras(spec, extras), else: :ok
  end

  def validate_extras(_module, _extras), do: {:error, :extras_must_be_map}

  @doc """
  Builds a struct from merged config using the module's defaults.
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
  Resolves a module name string (from glTF extras) to a module atom.
  """
  def resolve_module(name) when is_binary(name) do
    name
    |> String.split(".")
    |> Module.safe_concat()
  end

  # ---------------------------------------------------------------------------
  # Validation
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

    errors =
      if length = opts[:length] do
        if is_list(value) && length(value) != length do
          [{key, "array must have #{length} elements"} | errors]
        else
          errors
        end
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

  defp type_check(value, :float_array) when is_list(value) do
    if Enum.all?(value, &is_number/1), do: :ok, else: {:error, "all elements must be numbers"}
  end

  defp type_check(_, :float_array), do: {:error, "must be a list of numbers"}

  defp type_check(value, :integer_array) when is_list(value) do
    if Enum.all?(value, &is_integer/1),
      do: :ok,
      else: {:error, "all elements must be integers"}
  end

  defp type_check(_, :integer_array), do: {:error, "must be a list of integers"}

  defp type_check(value, :boolean_array) when is_list(value) do
    if Enum.all?(value, &is_boolean/1),
      do: :ok,
      else: {:error, "all elements must be booleans"}
  end

  defp type_check(_, :boolean_array), do: {:error, "must be a list of booleans"}
end
