defmodule Lunity.MCP.Server.Setup do
  @moduledoc """
  Wraps ExMCP.Server and injects get_tools/0 override after the use macro expands.
  Converts input_schema -> inputSchema for MCP spec (Cursor expects camelCase).
  Uses @before_compile to ensure get_tools/0 is defined before we override it.
  """
  defmacro __using__(_opts) do
    quote do
      use ExMCP.Server
      @before_compile Lunity.MCP.Server.Setup
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      defoverridable get_tools: 0

      def get_tools do
        base = get_attribute_map(:__tools__)

        Map.new(base, fn {name, tool} ->
          schema =
            tool[:input_schema] || tool["input_schema"] ||
              %{"type" => "object", "properties" => %{}}

          mcp_tool =
            tool
            |> Map.drop([:input_schema, "input_schema"])
            |> Map.put("inputSchema", schema)

          {name, mcp_tool}
        end)
      end
    end
  end
end
