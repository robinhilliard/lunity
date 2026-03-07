defmodule Lunity.Web.ViewerSocket do
  @moduledoc """
  WebSocket transport for the browser scene viewer.

  On connect, serializes the currently loaded editor scene and creates a
  server-side OrbitCamera fitted to the scene bounds. Sends the scene
  snapshot and initial camera state to the client.

  Mouse/scroll events from the browser update the OrbitCamera using the
  same functions as the desktop editor, and the updated camera state is
  sent back as JSON.
  """

  @behaviour Phoenix.Socket.Transport

  alias EAGL.OrbitCamera
  alias Lunity.Web.SceneSerializer

  require Logger

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(state) do
    {:ok, state}
  end

  @impl true
  def init(state) do
    send(self(), :send_initial_state)
    {:ok, state}
  end

  @impl true
  def handle_in({text, _opts}, state) do
    orbit = state[:orbit]

    case Jason.decode(text) do
      {:ok, event} when is_map(orbit) ->
        handle_event(event, orbit, state)

      {:ok, _} ->
        {:ok, state}

      {:error, _} ->
        {:ok, state}
    end
  end

  defp handle_event(%{"type" => "mouse_motion", "x" => x, "y" => y}, orbit, state) do
    orbit = OrbitCamera.handle_mouse_motion(orbit, x, y)
    state = Map.put(state, :orbit, orbit)

    if orbit.mouse_down or orbit.middle_down do
      reply_camera(orbit, state)
    else
      {:ok, state}
    end
  end

  defp handle_event(%{"type" => "mouse_down"}, orbit, state) do
    {:ok, Map.put(state, :orbit, OrbitCamera.handle_mouse_down(orbit))}
  end

  defp handle_event(%{"type" => "mouse_up"}, orbit, state) do
    {:ok, Map.put(state, :orbit, OrbitCamera.handle_mouse_up(orbit))}
  end

  defp handle_event(%{"type" => "middle_down"}, orbit, state) do
    {:ok, Map.put(state, :orbit, OrbitCamera.handle_middle_down(orbit))}
  end

  defp handle_event(%{"type" => "middle_up"}, orbit, state) do
    {:ok, Map.put(state, :orbit, OrbitCamera.handle_middle_up(orbit))}
  end

  defp handle_event(%{"type" => "scroll", "delta" => delta}, orbit, state) do
    orbit = OrbitCamera.handle_scroll(orbit, delta)
    reply_camera(orbit, Map.put(state, :orbit, orbit))
  end

  defp handle_event(_event, _orbit, state) do
    {:ok, state}
  end

  defp reply_camera(orbit, state) do
    msg = Jason.encode!(Map.put(serialize_camera(orbit), :type, "camera"))
    {:reply, :ok, {:text, msg}, state}
  end

  @impl true
  def handle_info(:send_initial_state, state) do
    scene = Lunity.Editor.State.get_scene()

    if scene do
      orbit = OrbitCamera.fit_to_scene(scene)
      scene_data = SceneSerializer.serialize(scene)
      camera_data = serialize_camera(orbit)

      msg = Jason.encode!(%{type: "scene", nodes: scene_data.nodes, camera: camera_data})
      {:push, {:text, msg}, Map.merge(state, %{orbit: orbit})}
    else
      Logger.warning("[ViewerSocket] No scene loaded in editor")
      msg = Jason.encode!(%{type: "error", message: "No scene loaded"})
      {:push, {:text, msg}, state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  defp serialize_camera(%OrbitCamera{} = orbit) do
    [{px, py, pz}] = OrbitCamera.get_position(orbit)
    [{tx, ty, tz}] = orbit.target
    fov_degrees = orbit.camera.yfov * 180.0 / :math.pi()

    %{
      position: [px, py, pz],
      target: [tx, ty, tz],
      fov: fov_degrees,
      near: orbit.camera.znear,
      far: orbit.camera.zfar
    }
  end
end
