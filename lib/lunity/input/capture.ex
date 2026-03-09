defmodule Lunity.Input.Capture do
  @moduledoc """
  Forwards EAGL.Window events to an input session's ETS state.

  Call `forward/2` from your window's `handle_event/2` to route all
  native input events into the session with zero boilerplate:

      def handle_event(event, state) do
        Lunity.Input.Capture.forward(event, state.session_id)
        {:ok, state}
      end

  Pass `nil` as the session_id to disable capture (e.g. during text
  input or menu screens). Events are silently ignored.
  """

  alias Lunity.Input.{Session, Keymap}

  @spec forward(term(), Session.session_id() | nil) :: :ok | :ignored
  def forward(_event, nil), do: :ignored

  def forward({:key, key_code}, session_id) do
    Session.key_down(session_id, Keymap.from_wx(key_code))
    :ok
  end

  def forward({:key_up, key_code}, session_id) do
    Session.key_up(session_id, Keymap.from_wx(key_code))
    :ok
  end

  def forward({:mouse_motion, x, y}, session_id) do
    Session.mouse_move(session_id, x * 1.0, y * 1.0)
    :ok
  end

  def forward({:mouse_down, _x, _y}, session_id) do
    Session.mouse_button(session_id, :left, true)
    :ok
  end

  def forward({:mouse_up, _x, _y}, session_id) do
    Session.mouse_button(session_id, :left, false)
    :ok
  end

  def forward({:right_down, _x, _y}, session_id) do
    Session.mouse_button(session_id, :right, true)
    :ok
  end

  def forward({:right_up, _x, _y}, session_id) do
    Session.mouse_button(session_id, :right, false)
    :ok
  end

  def forward({:middle_down, _x, _y}, session_id) do
    Session.mouse_button(session_id, :middle, true)
    :ok
  end

  def forward({:middle_up, _x, _y}, session_id) do
    Session.mouse_button(session_id, :middle, false)
    :ok
  end

  def forward({:mouse_wheel, _x, _y, wheel_rotation, _wheel_delta}, session_id) do
    Session.mouse_wheel(session_id, wheel_rotation * 1.0)
    :ok
  end

  def forward(_event, _session_id), do: :ignored
end
