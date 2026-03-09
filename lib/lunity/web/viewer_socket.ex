defmodule Lunity.Web.ViewerSocket do
  @moduledoc """
  WebSocket transport for the browser scene viewer.

  On connect, serializes the currently loaded editor scene and sends the
  scene snapshot with initial camera state. Also sends a list of running
  game instances.

  Supports watching a game instance: the client sends a "watch" message
  with an instance_id, and the socket streams ECS position updates at
  ~30 fps until "unwatch" is received or the instance stops.
  """

  @behaviour Phoenix.Socket.Transport

  alias EAGL.OrbitCamera
  alias Lunity.Input.{Session, Keymap, Gamepad}
  alias Lunity.Web.SceneSerializer

  require Logger

  @ecs_interval_ms 33

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(state) do
    {:ok, state}
  end

  @impl true
  def init(state) do
    session_id = make_ref()
    Session.register(session_id)
    send(self(), :send_initial_state)
    {:ok, Map.put(state, :session_id, session_id)}
  end

  @impl true
  def handle_in({text, _opts}, state) do
    case Jason.decode(text) do
      {:ok, event} ->
        handle_event(event, state)

      {:error, _} ->
        {:ok, state}
    end
  end

  # --- Instance watching ---

  defp handle_event(%{"type" => "watch", "instance_id" => instance_id}, state) do
    state = stop_ecs_timer(state)

    case Lunity.Instance.get(instance_id) do
      nil ->
        msg = Jason.encode!(%{type: "error", message: "Instance not found: #{instance_id}"})
        {:reply, :ok, {:text, msg}, state}

      instance ->
        entity_map = build_entity_map(instance)

        scene = Lunity.Editor.State.get_scene()

        state =
          if scene do
            orbit = OrbitCamera.fit_to_scene(scene)
            scene_data = SceneSerializer.serialize(scene)
            camera_data = serialize_camera(orbit)

            scene_msg =
              Jason.encode!(%{type: "scene", nodes: scene_data.nodes, camera: camera_data})

            send(self(), {:push_extra, scene_msg})
            Map.put(state, :orbit, orbit)
          else
            state
          end

        timer_ref = Process.send_after(self(), :ecs_tick, @ecs_interval_ms)

        state =
          Map.merge(state, %{
            watching: instance_id,
            entity_map: entity_map,
            ecs_timer: timer_ref
          })

        {:ok, state}
    end
  end

  defp handle_event(%{"type" => "unwatch"}, state) do
    state = stop_ecs_timer(state)
    state = Map.drop(state, [:watching, :entity_map])
    {:ok, state}
  end

  defp handle_event(%{"type" => "list_instances"}, state) do
    msg = Jason.encode!(%{type: "instances", ids: Lunity.Instance.list()})
    {:reply, :ok, {:text, msg}, state}
  end

  # --- Camera events ---

  defp handle_event(%{"type" => "mouse_motion", "x" => x, "y" => y}, state) do
    case state[:orbit] do
      nil ->
        {:ok, state}

      orbit ->
        orbit = OrbitCamera.handle_mouse_motion(orbit, x, y)
        state = Map.put(state, :orbit, orbit)

        if orbit.mouse_down or orbit.middle_down do
          reply_camera(orbit, state)
        else
          {:ok, state}
        end
    end
  end

  defp handle_event(%{"type" => "mouse_down"}, state) do
    with_orbit(state, &OrbitCamera.handle_mouse_down/1)
  end

  defp handle_event(%{"type" => "mouse_up"}, state) do
    with_orbit(state, &OrbitCamera.handle_mouse_up/1)
  end

  defp handle_event(%{"type" => "middle_down"}, state) do
    with_orbit(state, &OrbitCamera.handle_middle_down/1)
  end

  defp handle_event(%{"type" => "middle_up"}, state) do
    with_orbit(state, &OrbitCamera.handle_middle_up/1)
  end

  defp handle_event(%{"type" => "scroll", "delta" => delta}, state) do
    case state[:orbit] do
      nil ->
        {:ok, state}

      orbit ->
        orbit = OrbitCamera.handle_scroll(orbit, delta)
        reply_camera(orbit, Map.put(state, :orbit, orbit))
    end
  end

  # --- Input events (keyboard, mouse, gamepad) ---

  defp handle_event(%{"type" => "key_down", "code" => code}, state) do
    Session.key_down(state.session_id, Keymap.from_js(code))
    {:ok, state}
  end

  defp handle_event(%{"type" => "key_up", "code" => code}, state) do
    Session.key_up(state.session_id, Keymap.from_js(code))
    {:ok, state}
  end

  defp handle_event(%{"type" => "mouse_move", "x" => x, "y" => y}, state) do
    Session.mouse_move(state.session_id, x * 1.0, y * 1.0)
    {:ok, state}
  end

  defp handle_event(%{"type" => "mouse_button", "button" => btn, "pressed" => pressed}, state) do
    button = String.to_existing_atom(btn)
    Session.mouse_button(state.session_id, button, pressed)
    {:ok, state}
  end

  defp handle_event(%{"type" => "mouse_wheel", "delta" => delta}, state) do
    Session.mouse_wheel(state.session_id, delta * 1.0)
    {:ok, state}
  end

  defp handle_event(%{"type" => "gamepad"} = data, state) do
    gamepad = Gamepad.from_json(data)
    Session.update_gamepad(state.session_id, gamepad.index, gamepad)
    {:ok, state}
  end

  defp handle_event(_event, state) do
    {:ok, state}
  end

  defp with_orbit(state, fun) do
    case state[:orbit] do
      nil -> {:ok, state}
      orbit -> {:ok, Map.put(state, :orbit, fun.(orbit))}
    end
  end

  defp reply_camera(orbit, state) do
    msg = Jason.encode!(Map.put(serialize_camera(orbit), :type, "camera"))
    {:reply, :ok, {:text, msg}, state}
  end

  # --- handle_info ---

  @impl true
  def handle_info(:send_initial_state, state) do
    scene = Lunity.Editor.State.get_scene()

    initial =
      if scene do
        orbit = OrbitCamera.fit_to_scene(scene)
        scene_data = SceneSerializer.serialize(scene)
        camera_data = serialize_camera(orbit)

        scene_msg =
          Jason.encode!(%{type: "scene", nodes: scene_data.nodes, camera: camera_data})

        instances_msg =
          Jason.encode!(%{type: "instances", ids: Lunity.Instance.list()})

        state = Map.put(state, :orbit, orbit)
        {:push, {:text, scene_msg}, state, instances_msg}
      else
        instances_msg =
          Jason.encode!(%{type: "instances", ids: Lunity.Instance.list()})

        {:push, {:text, instances_msg}, state}
      end

    case initial do
      {:push, {:text, scene_msg}, state, instances_msg} ->
        send(self(), {:push_extra, instances_msg})
        {:push, {:text, scene_msg}, state}

      {:push, {:text, msg}, state} ->
        {:push, {:text, msg}, state}
    end
  end

  def handle_info({:push_extra, msg}, state) do
    {:push, {:text, msg}, state}
  end

  def handle_info(:ecs_tick, state) do
    case state do
      %{watching: _instance_id, entity_map: entity_map} ->
        positions = read_positions(entity_map)

        msg = Jason.encode!(%{type: "ecs_update", positions: positions})

        timer_ref = Process.send_after(self(), :ecs_tick, @ecs_interval_ms)
        state = Map.put(state, :ecs_timer, timer_ref)

        {:push, {:text, msg}, state}

      _ ->
        {:ok, state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    if session_id = state[:session_id] do
      Session.unregister(session_id)
    end

    :ok
  end

  # --- Private helpers ---

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

  defp build_entity_map(%{id: _instance_id, entity_ids: entity_ids}) do
    Map.new(entity_ids, fn {_inst, name} = entity_id ->
      {to_string(name), entity_id}
    end)
  end

  defp read_positions(entity_map) do
    pos_mod = Lunity.Components.Position

    Map.new(entity_map, fn {name, entity_id} ->
      case Lunity.ComponentStore.get(pos_mod, entity_id) do
        {x, y, z} -> {name, [x, y, z]}
        _ -> {name, nil}
      end
    end)
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp stop_ecs_timer(state) do
    case state[:ecs_timer] do
      nil ->
        state

      ref ->
        Process.cancel_timer(ref)
        Map.delete(state, :ecs_timer)
    end
  end
end
