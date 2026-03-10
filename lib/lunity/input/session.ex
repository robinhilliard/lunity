defmodule Lunity.Input.Session do
  @moduledoc """
  Direct ETS reads and writes for input session state.

  All functions operate directly on the shared `:lunity_input` ETS table
  owned by `Lunity.Input.SessionManager`. No GenServer message passing
  in the hot path -- backends write directly, game systems read directly.

  ## ETS key schema

      {session_id, :keyboard}        => Keyboard.t()
      {session_id, :mouse}           => Mouse.t()
      {session_id, :gamepad, index}  => Gamepad.t()
      {session_id, :head_pose}       => HeadPose.t()
      {session_id, :meta}            => SessionMeta.t()
  """

  alias Lunity.Input.{Keyboard, Mouse, Gamepad, HeadPose, SessionMeta}

  @table :lunity_input

  @type session_id :: term()

  # ---------------------------------------------------------------------------
  # Session lifecycle
  # ---------------------------------------------------------------------------

  @spec register(session_id(), SessionMeta.t()) :: :ok
  def register(session_id, meta \\ %SessionMeta{}) do
    :ets.insert(@table, {{session_id, :keyboard}, %Keyboard{}})
    :ets.insert(@table, {{session_id, :mouse}, %Mouse{}})
    :ets.insert(@table, {{session_id, :head_pose}, %HeadPose{}})
    :ets.insert(@table, {{session_id, :meta}, meta})
    :ok
  end

  @spec unregister(session_id()) :: :ok
  def unregister(session_id) do
    :ets.match_delete(@table, {{session_id, :_}, :_})
    :ets.match_delete(@table, {{session_id, :_, :_}, :_})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @spec get_keyboard(session_id()) :: Keyboard.t() | nil
  def get_keyboard(session_id) do
    case :ets.lookup(@table, {session_id, :keyboard}) do
      [{_, kb}] -> kb
      [] -> nil
    end
  end

  @spec get_mouse(session_id()) :: Mouse.t() | nil
  def get_mouse(session_id) do
    case :ets.lookup(@table, {session_id, :mouse}) do
      [{_, m}] -> m
      [] -> nil
    end
  end

  @spec get_gamepad(session_id(), non_neg_integer()) :: Gamepad.t() | nil
  def get_gamepad(session_id, index) do
    case :ets.lookup(@table, {session_id, :gamepad, index}) do
      [{_, gp}] -> gp
      [] -> nil
    end
  end

  @spec get_gamepads(session_id()) :: %{non_neg_integer() => Gamepad.t()}
  def get_gamepads(session_id) do
    @table
    |> :ets.match_object({{session_id, :gamepad, :_}, :_})
    |> Map.new(fn {{_, :gamepad, idx}, gp} -> {idx, gp} end)
  end

  @spec get_head_pose(session_id()) :: HeadPose.t() | nil
  def get_head_pose(session_id) do
    case :ets.lookup(@table, {session_id, :head_pose}) do
      [{_, hp}] -> hp
      [] -> nil
    end
  end

  @spec get_meta(session_id()) :: SessionMeta.t() | nil
  def get_meta(session_id) do
    case :ets.lookup(@table, {session_id, :meta}) do
      [{_, meta}] -> meta
      [] -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Iterate all sessions
  # ---------------------------------------------------------------------------

  @spec all_sessions() :: [{session_id(), SessionMeta.t()}]
  def all_sessions do
    @table
    |> :ets.match_object({{:_, :meta}, :_})
    |> Enum.map(fn {{sid, :meta}, meta} -> {sid, meta} end)
  end

  # ---------------------------------------------------------------------------
  # Writes -- called directly from backend processes
  # ---------------------------------------------------------------------------

  @spec key_down(session_id(), Keyboard.key()) :: true
  def key_down(session_id, key) do
    [{_, kb}] = :ets.lookup(@table, {session_id, :keyboard})

    :ets.insert(
      @table,
      {{session_id, :keyboard}, %{kb | keys_down: MapSet.put(kb.keys_down, key)}}
    )
  end

  @spec key_up(session_id(), Keyboard.key()) :: true
  def key_up(session_id, key) do
    [{_, kb}] = :ets.lookup(@table, {session_id, :keyboard})

    :ets.insert(
      @table,
      {{session_id, :keyboard}, %{kb | keys_down: MapSet.delete(kb.keys_down, key)}}
    )
  end

  @spec mouse_move(session_id(), float(), float()) :: true
  def mouse_move(session_id, x, y) do
    [{_, m}] = :ets.lookup(@table, {session_id, :mouse})
    :ets.insert(@table, {{session_id, :mouse}, %{m | position: {x, y}}})
  end

  @spec mouse_button(session_id(), Mouse.button(), boolean()) :: true
  def mouse_button(session_id, button, pressed) do
    [{_, m}] = :ets.lookup(@table, {session_id, :mouse})
    :ets.insert(@table, {{session_id, :mouse}, %{m | buttons: Map.put(m.buttons, button, pressed)}})
  end

  @spec mouse_wheel(session_id(), float()) :: true
  def mouse_wheel(session_id, delta) do
    [{_, m}] = :ets.lookup(@table, {session_id, :mouse})
    :ets.insert(@table, {{session_id, :mouse}, %{m | wheel_delta: delta}})
  end

  @spec update_gamepad(session_id(), non_neg_integer(), Gamepad.t()) :: true
  def update_gamepad(session_id, index, %Gamepad{} = gp) do
    :ets.insert(@table, {{session_id, :gamepad, index}, gp})
  end

  @spec remove_gamepad(session_id(), non_neg_integer()) :: true
  def remove_gamepad(session_id, index) do
    :ets.delete(@table, {session_id, :gamepad, index})
  end

  @spec update_head_pose(session_id(), HeadPose.t()) :: true
  def update_head_pose(session_id, %HeadPose{} = hp) do
    :ets.insert(@table, {{session_id, :head_pose}, hp})
  end

  @spec update_meta(session_id(), SessionMeta.t()) :: true
  def update_meta(session_id, %SessionMeta{} = meta) do
    :ets.insert(@table, {{session_id, :meta}, meta})
  end
end
