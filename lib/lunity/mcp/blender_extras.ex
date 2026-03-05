defmodule Lunity.MCP.BlenderExtras do
  @moduledoc """
  Generates Python scripts for Blender custom properties from prefab property specs.

  The agent passes the script to Blender MCP's `execute_blender_code` to create
  custom properties on selected object(s) that match the prefab's schema.
  Supports all Blender custom property metadata: min/max, soft limits, step,
  precision, subtype, and description.
  """

  @doc """
  Generate a Python script that creates Blender custom properties from a prefab's property spec.

  Accepts a prefab module name string (e.g. `"MyGame.Prefabs.Door"`).
  Returns `{:ok, script}` or `{:error, reason}`.
  """
  @spec generate_script(String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_script(prefab_name) when is_binary(prefab_name) do
    with {:ok, module} <- resolve_module(prefab_name),
         spec when spec != nil <- Lunity.Properties.property_spec(module) do
      script = build_script(spec)
      {:ok, script}
    else
      nil -> {:error, :no_property_spec}
      {:error, _} = err -> err
    end
  end

  defp resolve_module(name) do
    try do
      module = Lunity.Properties.resolve_module(name)

      if function_exported?(module, :__property_spec__, 0),
        do: {:ok, module},
        else: {:error, :not_a_prefab}
    rescue
      _ -> {:error, {:prefab_not_found, name}}
    end
  end

  defp build_script(spec) when is_map(spec) do
    header = [
      "# Add custom properties from Lunity prefab property spec",
      "# Run on selected object(s) in Blender",
      "",
      "import bpy",
      "",
      "def set_property(obj, name, value, **ui_opts):",
      "    \"\"\"Add or update a custom property with full UI metadata.\"\"\"",
      "    obj[name] = value",
      "    ui = obj.id_properties_ui(name)",
      "    update_args = {}",
      "    for key in ['min', 'max', 'soft_min', 'soft_max', 'step', 'precision',",
      "                'subtype', 'description', 'default']:",
      "        if key in ui_opts and ui_opts[key] is not None:",
      "            update_args[key] = ui_opts[key]",
      "    if update_args:",
      "        ui.update(**update_args)",
      "",
      "for obj in bpy.context.selected_objects:",
      "    if not hasattr(obj, 'id_properties_ui'):",
      "        continue"
    ]

    prop_lines = Enum.flat_map(spec, fn {key, opts} -> property_lines(key, opts) end)

    (header ++ prop_lines) |> Enum.join("\n")
  end

  defp property_lines(key, opts) do
    name = to_string(key)
    type = Keyword.get(opts, :type, :string)
    default = Keyword.get(opts, :default)

    {py_value, ui_args} = type_to_python(type, default, opts)
    ui_str = format_ui_args(ui_args)

    ["    set_property(obj, #{inspect(name)}, #{py_value}#{ui_str})"]
  end

  defp type_to_python(:string, default, opts) do
    val = if is_binary(default), do: inspect(default), else: "\"\""
    {val, base_ui_args(opts)}
  end

  defp type_to_python(:integer, default, opts) do
    val = if is_integer(default), do: "#{default}", else: "0"
    {val, base_ui_args(opts)}
  end

  defp type_to_python(:float, default, opts) do
    val = if is_number(default), do: format_float(default), else: "0.0"
    {val, base_ui_args(opts)}
  end

  defp type_to_python(:boolean, default, opts) do
    val = if default, do: "True", else: "False"
    {val, base_ui_args(opts)}
  end

  defp type_to_python(:atom, default, opts) do
    val = if default, do: inspect(to_string(default)), else: "\"\""
    {val, base_ui_args(opts)}
  end

  defp type_to_python(:float_array, default, opts) do
    val =
      if is_list(default),
        do: "[#{Enum.map_join(default, ", ", &format_float/1)}]",
        else: "[0.0]"

    {val, base_ui_args(opts)}
  end

  defp type_to_python(:integer_array, default, opts) do
    val =
      if is_list(default),
        do: "[#{Enum.join(default, ", ")}]",
        else: "[0]"

    {val, base_ui_args(opts)}
  end

  defp type_to_python(:boolean_array, default, opts) do
    val =
      if is_list(default),
        do: "[#{Enum.map_join(default, ", ", fn b -> if b, do: "True", else: "False" end)}]",
        else: "[False]"

    {val, base_ui_args(opts)}
  end

  defp type_to_python(_type, _default, opts) do
    {"\"\"", base_ui_args(opts)}
  end

  defp base_ui_args(opts) do
    []
    |> maybe_add(:min, opts[:min])
    |> maybe_add(:max, opts[:max])
    |> maybe_add(:soft_min, opts[:soft_min])
    |> maybe_add(:soft_max, opts[:soft_max])
    |> maybe_add(:step, opts[:step])
    |> maybe_add(:precision, opts[:precision])
    |> maybe_add_string(:subtype, blender_subtype(opts[:subtype]))
    |> maybe_add_string(:description, opts[:description])
    |> maybe_add_default(opts)
  end

  defp maybe_add(args, _key, nil), do: args
  defp maybe_add(args, key, val), do: [{key, "#{val}"} | args]

  defp maybe_add_string(args, _key, nil), do: args
  defp maybe_add_string(args, key, val), do: [{key, inspect(val)} | args]

  defp maybe_add_default(args, opts) do
    default = opts[:default]

    case opts[:type] do
      t when t in [:float, :integer] and not is_nil(default) ->
        [{:default, "#{default}"} | args]

      _ ->
        args
    end
  end

  defp blender_subtype(nil), do: nil
  defp blender_subtype(:plain), do: nil
  defp blender_subtype(:pixel), do: "PIXEL"
  defp blender_subtype(:percentage), do: "PERCENTAGE"
  defp blender_subtype(:factor), do: "FACTOR"
  defp blender_subtype(:angle), do: "ANGLE"
  defp blender_subtype(:time), do: "TIME"
  defp blender_subtype(:distance), do: "DISTANCE"
  defp blender_subtype(:power), do: "POWER"
  defp blender_subtype(:temperature), do: "TEMPERATURE"
  defp blender_subtype(:linear_color), do: "COLOR"
  defp blender_subtype(:gamma_color), do: "COLOR_GAMMA"
  defp blender_subtype(:euler), do: "EULER"
  defp blender_subtype(:quaternion), do: "QUATERNION"
  defp blender_subtype(_), do: nil

  defp format_ui_args([]), do: ""

  defp format_ui_args(args) do
    parts =
      args
      |> Enum.reverse()
      |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)

    ", #{parts}"
  end

  defp format_float(val) when is_float(val), do: "#{val}"
  defp format_float(val) when is_integer(val), do: "#{val}.0"
end
