defmodule Lunity.MCP.Server.Setup do
  @moduledoc """
  Wraps ExMCP.Server and injects get_tools/0 override after the use macro expands.
  Converts input_schema -> inputSchema for MCP spec (Cursor expects camelCase).
  """
  defmacro __using__(_opts) do
    quote do
      use ExMCP.Server
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
