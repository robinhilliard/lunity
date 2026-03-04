defmodule Lunity.MCP.Server.Setup do
  @moduledoc """
  Wraps ExMCP.Server and injects get_tools/0 override before the use macro expands.
  Converts input_schema -> inputSchema for MCP spec (Cursor expects camelCase).
  """
  defmacro __using__(_opts) do
    quote do
      # Define get_tools FIRST so it overrides ExMCP's generated one (which uses input_schema)
      def get_tools do
        base =
          case __MODULE__.__info__(:attributes)[:__tools__] do
            [map] when is_map(map) -> map
            map when is_map(map) -> map
            _ -> %{}
          end

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

      use ExMCP.Server
    end
  end
end
