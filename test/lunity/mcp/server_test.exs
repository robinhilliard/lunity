defmodule Lunity.MCP.ServerTest do
  use ExUnit.Case, async: false

  @moduletag :mcp

  setup do
    Lunity.Editor.State.init()
    on_exit(fn -> Lunity.Editor.State.clear_scene() end)
    :ok
  end

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

  describe "scene_get_hierarchy tool" do
    test "returns error when no scene loaded" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("scene_get_hierarchy", %{}, nil)

      assert text =~ "No scene loaded"
    end
  end

  describe "get_blender_extras_script tool" do
    test "returns Python script for known behaviour" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: script}], is_error?: false}, _} =
               Lunity.MCP.Server.handle_tool_call(
                 "get_blender_extras_script",
                 %{"behaviour" => "Lunity.TestBehaviour"},
                 nil
               )

      assert script =~ "import bpy"
      assert script =~ "add_property"
      assert script =~ "behaviour"
      assert script =~ "open_angle"
      assert script =~ "health"
    end

    test "returns error for unknown behaviour" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call(
                 "get_blender_extras_script",
                 %{"behaviour" => "NonExistent.Behaviour"},
                 nil
               )

      assert text =~ "Failed to generate script"
    end

    test "returns error when behaviour argument missing" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("get_blender_extras_script", %{}, nil)

      assert text =~ "behaviour"
    end
  end

  describe "scene_load tool" do
    test "returns error when path argument missing" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("scene_load", %{}, nil)

      assert text =~ "path"
    end
  end
end
