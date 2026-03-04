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
    test "returns Python script for known entity" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: script}], is_error?: false}, _} =
               Lunity.MCP.Server.handle_tool_call(
                 "get_blender_extras_script",
                 %{"entity" => "Lunity.TestEntity"},
                 nil
               )

      assert script =~ "import bpy"
      assert script =~ "add_property"
      assert script =~ "open_angle"
      assert script =~ "health"
    end

    test "returns error for unknown entity" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call(
                 "get_blender_extras_script",
                 %{"entity" => "NonExistent.Entity"},
                 nil
               )

      assert text =~ "Failed to generate script"
    end

    test "returns error when entity argument missing" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("get_blender_extras_script", %{}, nil)

      assert text =~ "entity"
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

  describe "editor_get_context tool" do
    test "returns no scene message when nothing loaded" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("editor_get_context", %{}, nil)

      assert text =~ "No scene"
    end
  end

  describe "editor_push tool" do
    test "returns error when no scene loaded" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("editor_push", %{}, nil)

      assert text =~ "No scene"
    end
  end

  describe "editor_pop tool" do
    test "returns error when stack empty" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("editor_pop", %{}, nil)

      assert text =~ "empty"
    end
  end

  describe "editor_peek tool" do
    test "returns empty stack" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: false}, _} =
               Lunity.MCP.Server.handle_tool_call("editor_peek", %{}, nil)

      assert text =~ "count"
      assert text =~ "0"
    end
  end

  describe "editor_set_context tool" do
    test "returns error when type or path missing" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("editor_set_context", %{}, nil)

      assert text =~ "type"
      assert text =~ "path"
    end
  end

  describe "Phase 6d tools" do
    test "view_list returns main view" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: false}, _} =
               Lunity.MCP.Server.handle_tool_call("view_list", %{}, nil)

      assert text =~ "main"
    end

    test "entity_list returns empty when no scene" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: false}, _} =
               Lunity.MCP.Server.handle_tool_call("entity_list", %{}, nil)

      assert text =~ "count"
      assert text =~ "0"
    end

    test "pause and resume" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: false}, _} =
               Lunity.MCP.Server.handle_tool_call("pause", %{}, nil)

      assert text =~ "paused"

      assert {:ok, %{content: [%{type: "text", text: text2}], is_error?: false}, _} =
               Lunity.MCP.Server.handle_tool_call("resume", %{}, nil)

      assert text2 =~ "resumed"
    end

    test "clear_annotations" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: false}, _} =
               Lunity.MCP.Server.handle_tool_call("clear_annotations", %{}, nil)

      assert text =~ "cleared"
    end

    test "entity_at_screen requires x and y" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("entity_at_screen", %{}, nil)

      assert text =~ "x"
      assert text =~ "y"
    end

    test "entity_set requires entity_id, component, value" do
      {:ok, _server} = Lunity.MCP.Server.start_link(transport: :test)

      assert {:ok, %{content: [%{type: "text", text: text}], is_error?: true}, _} =
               Lunity.MCP.Server.handle_tool_call("entity_set", %{}, nil)

      assert text =~ "entity_id"
    end
  end
end
