defmodule Lunity.Player.Resume do
  @moduledoc false
  use GenServer

  alias Lunity.Input.Session

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  After a player WebSocket disconnects, keep the input session alive for
  `:player_reconnect_grace_ms` so the same `player_id` can reconnect with `auth` + `resume: true`.
  """
  @spec register_disconnect(String.t(), Session.session_id()) :: :ok
  def register_disconnect(player_id, session_id) when is_binary(player_id) and player_id != "" do
    GenServer.cast(@name, {:register_disconnect, player_id, session_id})
  end

  def register_disconnect(_, _), do: :ok

  @doc """
  Drop any pending reconnect for this `player_id` and unregister its ETS session (new connection
  without `resume` wins).
  """
  @spec clear_pending(String.t()) :: :ok
  def clear_pending(player_id) when is_binary(player_id) do
    GenServer.cast(@name, {:clear_pending, player_id})
  end

  def clear_pending(_), do: :ok

  @spec take(String.t()) :: {:ok, Session.session_id()} | :none
  def take(player_id) when is_binary(player_id) do
    GenServer.call(@name, {:take, player_id})
  end

  def take(_), do: :none

  @impl true
  def init(_opts) do
    {:ok, %{pending: %{}}}
  end

  @impl true
  def handle_cast({:register_disconnect, player_id, session_id}, state) do
    state = cancel_pending_player(state, player_id)
    grace_ms = Application.get_env(:lunity, :player_reconnect_grace_ms, 10_000)
    timer_ref = Process.send_after(self(), {:grace_expired, player_id, session_id}, grace_ms)
    pending = Map.put(state.pending, player_id, {session_id, timer_ref})
    {:noreply, %{state | pending: pending}}
  end

  def handle_cast({:clear_pending, player_id}, state) do
    {:noreply, cancel_pending_player(state, player_id)}
  end

  @impl true
  def handle_call({:take, player_id}, _from, state) do
    case Map.get(state.pending, player_id) do
      nil ->
        {:reply, :none, state}

      {session_id, timer_ref} ->
        Process.cancel_timer(timer_ref)
        {:reply, {:ok, session_id}, %{state | pending: Map.delete(state.pending, player_id)}}
    end
  end

  @impl true
  def handle_info({:grace_expired, player_id, session_id}, state) do
    case Map.get(state.pending, player_id) do
      {^session_id, _} ->
        Session.unregister(session_id)
        {:noreply, %{state | pending: Map.delete(state.pending, player_id)}}

      _ ->
        {:noreply, state}
    end
  end

  defp cancel_pending_player(state, player_id) do
    case Map.get(state.pending, player_id) do
      nil ->
        state

      {session_id, timer_ref} ->
        Process.cancel_timer(timer_ref)
        Session.unregister(session_id)
        %{state | pending: Map.delete(state.pending, player_id)}
    end
  end
end
