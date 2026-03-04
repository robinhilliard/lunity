defmodule Lunity.Editor.StateTest do
  use ExUnit.Case, async: false

  alias EAGL.OrbitCamera
  alias EAGL.Scene
  alias Lunity.Editor.State

  setup do
    State.init()

    on_exit(fn ->
      State.clear_scene()
      State.clear_context_stack()
    end)

    :ok
  end

  describe "context stack" do
    test "context_push returns error when no scene" do
      assert State.context_push() == {:error, :no_scene}
    end

    test "context_pop returns error when stack empty" do
      assert State.context_pop() == {:error, :empty_stack}
    end

    test "context_peek returns empty list" do
      assert State.context_peek() == []
    end

    test "push and peek with scene" do
      scene = Scene.new()
      orbit = OrbitCamera.new()
      State.set_scene(scene, "box", [], :scene)
      State.put_orbit(orbit)

      assert State.context_push() == :ok
      assert [%{type: :scene, path: "box"}] = State.context_peek()
    end

    test "push and pop restores stack" do
      scene = Scene.new()
      orbit = OrbitCamera.new()
      State.set_scene(scene, "box", [], :scene)
      State.put_orbit(orbit)

      assert State.context_push() == :ok
      assert {:ok, entry} = State.context_pop()
      assert entry.type == :scene
      assert entry.path == "box"
      assert entry.orbit != nil
      assert State.context_peek() == []
    end
  end

  describe "get_context" do
    test "returns nil when no scene" do
      assert State.get_context() == nil
    end

    test "returns context when scene loaded" do
      scene = Scene.new()
      orbit = OrbitCamera.new()
      State.set_scene(scene, "box", [], :scene)
      State.put_orbit(orbit)

      ctx = State.get_context()
      assert ctx.type == :scene
      assert ctx.path == "box"
      assert ctx.orbit == orbit
    end
  end

  describe "orbit commands" do
    test "put and take orbit_command" do
      orbit = OrbitCamera.new()
      State.put_orbit_command(orbit)
      assert State.take_orbit_command() == {:set_orbit, orbit}
      assert State.take_orbit_command() == nil
    end

    test "put and take orbit_after_load" do
      orbit = OrbitCamera.new()
      State.put_orbit_after_load(orbit)
      assert State.take_orbit_after_load() == orbit
      assert State.take_orbit_after_load() == nil
    end
  end
end
