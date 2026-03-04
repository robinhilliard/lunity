defmodule Lunity.Editor.View do
  @moduledoc """
  Orbit camera view for the Lunity editor. Renders the current scene.

  Processes load commands from ETS (queued by MCP scene_load) on each frame.
  GL context must be current when loading (we're in the render loop).
  """
  use EAGL.Window
  use EAGL.Const
  use EAGL.OrbitCamera

  import Bitwise
  alias EAGL.Scene
  alias Lunity.Editor.State
  alias Lunity.SceneLoader

  def run(opts \\ []) do
    default_opts = [
      depth_testing: true,
      size: {1024, 768},
      enter_to_exit: true
    ]

    EAGL.Window.run(
      __MODULE__,
      "Lunity Editor",
      Keyword.merge(default_opts, opts)
    )
  end

  @impl true
  def setup do
    State.init()

    with {:ok, program} <- GLTF.EAGL.create_pbr_shader() do
      orbit = EAGL.OrbitCamera.new()
      {:ok, %{program: program, orbit: orbit}}
    end
  end

  @impl true
  def render(w, h, state) do
    state = process_load_command(state)
    do_render(w, h, state)
  end

  defp process_load_command(%{program: program} = state) do
    case State.take_load_command() do
      {:load_scene, path} ->
        result =
          case SceneLoader.load_scene(path, shader_program: program) do
            {:ok, scene, entities} ->
              State.set_scene(scene, path, entities)
              orbit = EAGL.OrbitCamera.fit_to_scene(scene)
              State.put_load_result({:ok, path, length(entities)})
              {:ok, %{state | orbit: orbit}}

            {:error, reason} ->
              State.clear_scene()
              State.put_load_result({:error, reason})
              state
          end

        case result do
          {:ok, new_state} -> new_state
          s when is_map(s) -> s
        end

      nil ->
        state
    end
  end

  defp do_render(w, h, %{program: prog, orbit: orbit} = state) do
    :gl.viewport(0, 0, trunc(w), trunc(h))
    :gl.clearColor(0.15, 0.15, 0.2, 1.0)
    :gl.clear(@gl_color_buffer_bit ||| @gl_depth_buffer_bit)
    :gl.enable(@gl_cull_face)
    :gl.cullFace(@gl_back)

    :gl.useProgram(prog)
    view = EAGL.OrbitCamera.get_view_matrix(orbit)
    proj = EAGL.OrbitCamera.get_projection_matrix(orbit, w / max(h, 1))

    GLTF.EAGL.set_pbr_uniforms(prog,
      view_pos: EAGL.OrbitCamera.get_position(orbit)
    )

    case State.get_scene() do
      %Scene{} = scene ->
        Scene.render(scene, view, proj)

      nil ->
        :ok
    end

    {:ok, state}
  end

  @impl true
  def cleanup(%{program: p}) do
    EAGL.Shader.cleanup_program(p)
    :ok
  end
end
