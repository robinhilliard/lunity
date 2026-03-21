defmodule Lunity.Web.PlayerSocket do
  @moduledoc """
  WebSocket entry for **game clients** (bootstrap → auth → join → actions → state), distinct from
  legacy `Lunity.Web.ViewerSocket` (WebGL POC / scene watch).

  ## Connect (Phase 0)

  Query param `token` must match `Application.get_env(:lunity, :player_ws_token)`.
  If unset or empty, connections are **rejected** (fail closed).

  ## Protocol (Phase 2)

  Envelope: `{"v": 1, "t": "<type>", ...}`. Sequence: `hello` → `auth` (JWT) → `join` → `actions` /
  optional `subscribe_state`. JWT verification uses `Lunity.Auth.PlayerJWT` and
  `:player_jwt_secret`.
  """

  @behaviour Phoenix.Socket.Transport

  alias Lunity.Input.Session
  alias Lunity.Web.{PlayerMessage}

  require Logger

  @impl true
  def child_spec(_opts), do: :ignore

  @impl true
  def connect(%{params: params} = config) do
    token = params["token"]
    expected = Application.get_env(:lunity, :player_ws_token)

    cond do
      not (is_binary(expected) and expected != "") ->
        Logger.warning("Lunity.Web.PlayerSocket: :player_ws_token not set; rejecting connection")
        :error

      is_binary(token) and token == expected ->
        {:ok, config}

      true ->
        :error
    end
  end

  @impl true
  def init(config) do
    session_id = make_ref()
    :ok = Session.register(session_id)
    send(self(), :send_welcome)

    {:ok,
     Map.merge(config, %{
       session_id: session_id,
       phase: :connected,
       hello_ok: false,
       state_sub: nil,
       state_timer_ref: nil,
       state_interval_ms: 100
     })}
  end

  @impl true
  def handle_in({text, _opts}, state) do
    case PlayerMessage.handle_in(text, state) do
      {:error, :invalid_json} ->
        {:ok, state}

      {:ok, frames, new_state} ->
        case frames do
          [] ->
            {:ok, new_state}

          [one] ->
            {:reply, :ok, {:text, one}, new_state}

          [one | rest] ->
            send(self(), {:push_frames, rest})
            {:reply, :ok, {:text, one}, new_state}
        end
    end
  end

  @impl true
  def handle_info(:send_welcome, state) do
    msg =
      Jason.encode!(%{
        v: 1,
        t: "welcome",
        protocol: 1
      })

    {:push, {:text, msg}, state}
  end

  def handle_info({:push_frames, frames}, state) do
    case frames do
      [] ->
        {:ok, state}

      [f | rest] ->
        send(self(), {:push_frames, rest})
        {:push, {:text, f}, state}
    end
  end

  def handle_info(:player_state_push, state) do
    if state[:phase] == :in_world and state[:state_sub] do
      case Session.get_meta(state.session_id) do
        %{instance_id: iid} = _meta when is_binary(iid) ->
          filter = state[:state_sub][:filter]
          json = PlayerMessage.encode_state_frame(iid, filter)
          new_state = PlayerMessage.schedule_next_state_push(state)
          {:push, {:text, json}, new_state}

        _ ->
          {:ok, PlayerMessage.cancel_state_timer(state)}
      end
    else
      {:ok, state}
    end
  end

  def handle_info(_msg, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    _ = PlayerMessage.cancel_state_timer(state)

    if session_id = state[:session_id] do
      Session.unregister(session_id)
    end

    :ok
  end
end
