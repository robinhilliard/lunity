defmodule Mix.Tasks.Lunity.InputTest do
  @shortdoc "Open a window and dump changed input state at 10 fps"
  @moduledoc """
  Starts a minimal EAGL window to capture keyboard and mouse events, polls
  gamepads via gilrs, and prints input state changes at 10 fps.

  Run from your game project (or the lunity project itself):

      mix lunity.input_test

  Press Escape or close the window to exit.
  """
  use Mix.Task

  alias Lunity.Input.Session

  @session_id "input_test"
  @poll_ms 100

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:lunity)

    Session.register(@session_id)

    gamepad_status =
      case Lunity.Input.NativeGamepad.start_link(session_id: @session_id) do
        {:ok, _pid} -> "gilrs gamepad poller started"
        {:error, reason} -> "gilrs unavailable (#{inspect(reason)})"
      end

    IO.puts("--- Lunity Input Test (10 fps, changes only) ---")
    IO.puts("Session: #{@session_id}")
    IO.puts("Gamepads: #{gamepad_status}")
    IO.puts("Focus the window and press keys / move mouse / use controllers.")
    IO.puts("Press ESC or close the window to quit.\n")

    dump_pid = spawn_link(fn -> dump_loop(%{}) end)

    EAGL.Window.run(InputTestWindow, "Lunity Input Test",
      size: {400, 200},
      enter_to_exit: false
    )

    Process.exit(dump_pid, :shutdown)
    Session.unregister(@session_id)
    :ok
  end

  # --------------------------------------------------------------------------
  # Periodic diff-based dump
  # --------------------------------------------------------------------------

  defp dump_loop(prev) do
    Process.sleep(@poll_ms)

    kb = Session.get_keyboard(@session_id)
    mouse = Session.get_mouse(@session_id)
    gamepads = Session.get_gamepads(@session_id)

    cur = snapshot(kb, mouse, gamepads)
    lines = diff(prev, cur)

    if lines != [] do
      ts = Calendar.strftime(DateTime.utc_now(), "%H:%M:%S.%f") |> binary_part(0, 12)
      IO.puts("[#{ts}]")
      Enum.each(lines, &IO.puts/1)
      IO.puts("")
    end

    dump_loop(cur)
  end

  # --------------------------------------------------------------------------
  # Snapshot: reduce live state to comparable terms
  # --------------------------------------------------------------------------

  defp snapshot(kb, mouse, gamepads) do
    %{
      keys: if(kb, do: kb.keys_down |> MapSet.to_list() |> Enum.sort(), else: []),
      mouse_pos: if(mouse, do: round_pos(mouse.position), else: {0, 0}),
      mouse_btns: if(mouse, do: pressed_buttons(mouse.buttons), else: []),
      mouse_wheel: if(mouse, do: round3(mouse.wheel_delta), else: 0.0),
      gamepads: gamepads |> Enum.sort_by(fn {i, _} -> i end) |> Enum.map(&snap_gamepad/1)
    }
  end

  @axis_deadzone 0.03

  defp round_pos({x, y}), do: {round3(x), round3(y)}
  defp round3(v) when is_float(v), do: Float.round(v, 3)
  defp round3(v), do: v

  defp deaden(v) when is_float(v) do
    r = Float.round(v, 1)
    if abs(r) < @axis_deadzone, do: 0.0, else: r
  end

  defp deaden(v), do: v

  defp pressed_buttons(btns) do
    btns |> Enum.filter(fn {_, v} -> v end) |> Enum.map(fn {b, _} -> b end) |> Enum.sort()
  end

  defp snap_gamepad({idx, gp}) do
    {idx, %{
      id: gp.id,
      connected: gp.connected,
      axes: Enum.map(gp.axes, &deaden/1),
      pressed: gp.buttons |> Enum.with_index() |> Enum.filter(fn {b, _} -> b.pressed end) |> Enum.map(fn {_, i} -> i end),
      analog: gp.buttons |> Enum.with_index() |> Enum.reject(fn {b, _} -> b.value == 0.0 end) |> Enum.map(fn {b, i} -> {i, round3(b.value)} end)
    }}
  end

  # --------------------------------------------------------------------------
  # Diff: compare snapshots, return lines for changed fields
  # --------------------------------------------------------------------------

  defp diff(prev, cur) when prev == %{}, do: format_all(cur)

  defp diff(prev, cur) do
    lines = []

    lines = if prev.keys != cur.keys do
      label = if cur.keys == [], do: "(none)", else: Enum.join(cur.keys, ", ")
      lines ++ ["  KEYBOARD: #{label}"]
    else
      lines
    end

    lines = if prev.mouse_pos != cur.mouse_pos do
      {x, y} = cur.mouse_pos
      lines ++ ["  MOUSE pos: (#{fmt(x)}, #{fmt(y)})"]
    else
      lines
    end

    lines = if prev.mouse_btns != cur.mouse_btns do
      label = if cur.mouse_btns == [], do: "(none)", else: Enum.join(cur.mouse_btns, ", ")
      lines ++ ["  MOUSE buttons: [#{label}]"]
    else
      lines
    end

    lines = if prev.mouse_wheel != cur.mouse_wheel do
      lines ++ ["  MOUSE wheel: #{fmt(cur.mouse_wheel)}"]
    else
      lines
    end

    prev_gp = Map.new(prev.gamepads)
    cur_gp = Map.new(cur.gamepads)

    all_indices = MapSet.union(MapSet.new(Map.keys(prev_gp)), MapSet.new(Map.keys(cur_gp)))

    lines =
      Enum.reduce(Enum.sort(all_indices), lines, fn idx, acc ->
        case {Map.get(prev_gp, idx), Map.get(cur_gp, idx)} do
          {nil, gp} ->
            acc ++ gamepad_lines(idx, gp, :connected)

          {_gp, nil} ->
            acc ++ ["  GAMEPAD #{idx}: disconnected"]

          {old, new} when old != new ->
            acc ++ gamepad_diff_lines(idx, old, new)

          _ ->
            acc
        end
      end)

    lines
  end

  defp format_all(cur) do
    lines = []
    label = if cur.keys == [], do: "(none)", else: Enum.join(cur.keys, ", ")
    lines = lines ++ ["  KEYBOARD: #{label}"]

    {x, y} = cur.mouse_pos
    btn_label = if cur.mouse_btns == [], do: "(none)", else: Enum.join(cur.mouse_btns, ", ")
    lines = lines ++ ["  MOUSE: pos=(#{fmt(x)}, #{fmt(y)})  buttons=[#{btn_label}]  wheel=#{fmt(cur.mouse_wheel)}"]

    if cur.gamepads == [] do
      lines ++ ["  GAMEPADS: (none connected)"]
    else
      Enum.reduce(cur.gamepads, lines, fn {idx, gp}, acc ->
        acc ++ gamepad_lines(idx, gp, :full)
      end)
    end
  end

  defp gamepad_lines(idx, gp, mode) do
    id_label = if gp.id == "", do: "unknown", else: gp.id
    header = if mode == :connected, do: "connected", else: "found"
    lines = ["  GAMEPAD #{idx}: \"#{id_label}\" (#{header})"]

    lines = if gp.axes != [] do
      axes_str = gp.axes |> Enum.with_index() |> Enum.map(fn {v, i} -> "#{i}:#{fmt(v)}" end) |> Enum.join("  ")
      lines ++ ["    axes:    #{axes_str}"]
    else
      lines
    end

    if gp.pressed != [] do
      lines ++ ["    pressed: #{Enum.join(gp.pressed, ", ")}"]
    else
      lines
    end
  end

  defp gamepad_diff_lines(idx, old, new) do
    lines = []

    lines = if old.connected != new.connected do
      lines ++ ["  GAMEPAD #{idx}: #{if new.connected, do: "connected", else: "disconnected"}"]
    else
      lines
    end

    lines = if old.axes != new.axes do
      axes_str = new.axes |> Enum.with_index() |> Enum.map(fn {v, i} -> "#{i}:#{fmt(v)}" end) |> Enum.join("  ")
      lines ++ ["  GAMEPAD #{idx} axes: #{axes_str}"]
    else
      lines
    end

    lines = if old.pressed != new.pressed do
      label = if new.pressed == [], do: "(none)", else: Enum.join(new.pressed, ", ")
      lines ++ ["  GAMEPAD #{idx} pressed: #{label}"]
    else
      lines
    end

    if old.analog != new.analog do
      analog_str = new.analog |> Enum.map(fn {i, v} -> "#{i}:#{fmt(v)}" end) |> Enum.join("  ")
      label = if analog_str == "", do: "(none)", else: analog_str
      lines ++ ["  GAMEPAD #{idx} analog: #{label}"]
    else
      lines
    end
  end

  defp fmt(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 3)
  defp fmt(v), do: "#{v}"
end

# --------------------------------------------------------------------------
# Minimal EAGL window -- captures keyboard/mouse into the input session
# --------------------------------------------------------------------------

defmodule InputTestWindow do
  use EAGL.Window
  use EAGL.Const

  @impl true
  def setup do
    {:ok, %{session_id: "input_test"}}
  end

  @impl true
  def render(_w, _h, state) do
    :gl.clearColor(0.12, 0.12, 0.14, 1.0)
    :gl.clear(@gl_color_buffer_bit)
    {:ok, state}
  end

  @impl true
  def handle_event({:key, 27}, state) do
    throw(:close_window)
    {:ok, state}
  end

  def handle_event(event, state) do
    Lunity.Input.Capture.forward(event, state.session_id)
    {:ok, state}
  end

  @impl true
  def cleanup(_state), do: :ok
end
