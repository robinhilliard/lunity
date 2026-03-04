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
  alias Lunity.PrefabLoader
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
    state = apply_orbit_command(state)
    state = process_load_command(state)
    State.put_viewport(w, h)
    state = process_capture_request(state, w, h)
    state = process_pick_request(state, w, h)
    {:ok, state} = do_render(w, h, state)
    sync_orbit_to_ets(state)
    {:ok, state}
  end

  defp apply_orbit_command(%{orbit: _} = state) do
    case State.take_orbit_command() do
      {:set_orbit, orbit} -> %{state | orbit: orbit}
      nil -> state
    end
  end

  defp process_load_command(%{program: program} = state) do
    case State.take_load_command() do
      {:load_scene, path} ->
        load_scene_and_apply(state, program, path)

      {:load_prefab, id} ->
        load_prefab_and_apply(state, program, id)

      nil ->
        state
    end
  end

  defp load_scene_and_apply(state, program, path) do
    case SceneLoader.load_scene(path, shader_program: program) do
      {:ok, scene, entities} ->
        State.set_scene(scene, path, entities, :scene)
        orbit = State.take_orbit_after_load() || EAGL.OrbitCamera.fit_to_scene(scene)
        State.put_load_result({:ok, path, length(entities)})
        %{state | orbit: orbit}

      {:error, reason} ->
        State.clear_scene()
        State.put_load_result({:error, reason})
        state
    end
  end

  defp load_prefab_and_apply(state, program, id) do
    case PrefabLoader.load_prefab(id, shader_program: program) do
      {:ok, scene, _config} ->
        State.set_scene(scene, id, [], :prefab)
        orbit = State.take_orbit_after_load() || EAGL.OrbitCamera.fit_to_scene(scene)
        State.put_load_result({:ok, id, 0})
        %{state | orbit: orbit}

      {:error, reason} ->
        State.clear_scene()
        State.put_load_result({:error, reason})
        state
    end
  end

  defp sync_orbit_to_ets(%{orbit: orbit}) do
    State.put_orbit(orbit)
  end

  defp process_capture_request(state, w, h) do
    case State.take_capture_request() do
      {:capture, _view_id} ->
        case do_capture(trunc(w), trunc(h)) do
          {:ok, base64} ->
            State.put_capture_result({:ok, base64})

          {:error, reason} ->
            State.put_capture_result({:error, reason})
        end

      nil ->
        :ok
    end

    state
  end

  defp do_capture(width, height) when width > 0 and height > 0 do
    try do
      # glReadPixels returns bottom-to-top; flip for standard image orientation
      pixel_data = <<0::size(width * height * 4)-unit(8)>>
      :gl.readPixels(0, 0, width, height, @gl_rgba, @gl_unsigned_byte, pixel_data)
      flipped = flip_pixels_vertical(pixel_data, width, height)
      {:ok, Base.encode64(flipped)}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp do_capture(_, _), do: {:error, :invalid_viewport}

  defp flip_pixels_vertical(pixels, width, height) do
    row_bytes = width * 4

    rows =
      for i <- 0..(height - 1) do
        offset = i * row_bytes
        binary_part(pixels, offset, row_bytes)
      end

    rows |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp process_pick_request(state, w, h) do
    case State.take_pick_request() do
      {:pick, x, y} ->
        case {State.get_scene(), State.get_orbit()} do
          {scene, orbit} when not is_nil(scene) and not is_nil(orbit) ->
            viewport = {0, 0, trunc(w), trunc(h)}

            case Scene.pick(scene, orbit, viewport, x, y) do
              {:ok, node} ->
                entity_id = (node.properties || %{})["entity_id"]
                State.put_pick_result({:ok, node, entity_id})

              nil ->
                State.put_pick_result(nil)
            end

          _ ->
            State.put_pick_result(nil)
        end

      nil ->
        :ok
    end

    state
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
