defmodule Lunity.MCP.BlenderExtras do
  @moduledoc """
  Generates Python scripts for Blender custom properties from entity extras specs.

  The agent passes the script to Blender MCP's `execute_blender_code` to create
  custom properties on selected object(s) that match the entity's schema.
  """
  alias Lunity.Entity

  @doc """
  Generate a Python script that creates Blender custom properties from an entity's extras spec.

  Returns `{:ok, script}` or `{:error, reason}`.
  """
  @spec generate_script(String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate_script(entity_name) when is_binary(entity_name) do
    with {:ok, module} <- resolve_module(entity_name),
         spec when spec != nil <- Entity.extras_spec(module) do
      script = build_script(spec)
      {:ok, script}
    else
      nil -> {:error, :no_extras_spec}
      {:error, _} = err -> err
    end
  end

  defp resolve_module(name) do
    try do
      module = Entity.resolve_module(name)

      if function_exported?(module, :__extras_spec__, 0),
        do: {:ok, module},
        else: {:error, :not_an_entity}
    rescue
      _ -> {:error, {:entity_not_found, name}}
    end
  end

  defp build_script(spec) when is_map(spec) do
    lines = [
      "# Add custom properties from Lunity entity extras spec",
      "# Run on selected object(s) in Blender",
      "",
      "import bpy",
      "",
      "def add_property(obj, name, value, prop_type, min_val=None, max_val=None):",
      "    if name in obj:",
      "        return",
      "    obj[name] = value",
      "    ui = obj.id_properties_ui(name)",
      "    if prop_type == 'int' and min_val is not None:",
      "        ui.update(min=min_val)",
      "    if prop_type == 'int' and max_val is not None:",
      "        ui.update(max=max_val)",
      "    if prop_type == 'float' and min_val is not None:",
      "        ui.update(min=min_val)",
      "    if prop_type == 'float' and max_val is not None:",
      "        ui.update(max=max_val)",
      "",
      "for obj in bpy.context.selected_objects:",
      "    if not hasattr(obj, 'id_properties_ui'):",
      "        continue"
    ]

    prop_lines =
      Enum.flat_map(spec, fn {key, opts} ->
        {py_name, py_value, py_type, min_val, max_val} = spec_to_python(key, opts)

        [
          "    add_property(obj, #{inspect(py_name)}, #{py_value}, #{inspect(py_type)}, #{min_val}, #{max_val})"
        ]
      end)

    (lines ++ prop_lines) |> Enum.join("\n")
  end

  defp spec_to_python(key, opts) do
    name = to_string(key)
    default = Keyword.get(opts, :default)
    type = Keyword.get(opts, :type, :string)
    min_val = Keyword.get(opts, :min)
    max_val = Keyword.get(opts, :max)

    {py_value, py_type} =
      case type do
        :string ->
          val = if is_binary(default), do: default, else: ""
          {"#{inspect(val)}", "str"}

        :integer ->
          val = if is_integer(default), do: default, else: 0
          {"#{val}", "int"}

        :float ->
          val = if is_number(default), do: default, else: 0.0
          {"#{val}", "float"}

        _ ->
          {"\"\"", "str"}
      end

    min_str = if min_val != nil, do: "#{min_val}", else: "None"
    max_str = if max_val != nil, do: "#{max_val}", else: "None"

    {name, py_value, py_type, min_str, max_str}
  end
end
