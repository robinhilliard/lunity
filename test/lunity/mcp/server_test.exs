defmodule Lunity.MCP.ServerTest do
  use ExUnit.Case, async: false

  @moduletag :mcp

  describe "project_structure tool" do
    test "returns expected priv layout" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text} | _]}, _} =
               Lunity.MCP.Server.handle_tool_call("project_structure", %{}, nil)

      assert text =~ "priv/"
      assert text =~ "prefabs/"
      assert text =~ "scenes/"
      assert text =~ "config/"
    end
  end
end
