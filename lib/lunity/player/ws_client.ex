defmodule Lunity.Player.WsClient do
  @moduledoc false

  use WebSockex

  @type phase ::
          :welcome
          | :expect_hello_ack
          | :expect_auth_ack
          | :expect_assigned

  @type t :: %{
          parent: pid,
          jwt: String.t(),
          hints: map() | nil,
          auth_only: boolean(),
          phase: phase(),
          verbose: boolean(),
          done: boolean()
        }

  def start_link(ws_url, state, ws_opts) when is_map(state) do
    WebSockex.start_link(ws_url, __MODULE__, Map.put(state, :done, false), ws_opts)
  end

  @impl true
  def handle_connect(_conn, state) do
    verbose(state, "tcp + ws handshake ok")
    {:ok, state}
  end

  @impl true
  def handle_frame({:text, _body}, %{done: true} = state), do: {:ok, state}

  def handle_frame({:text, body}, state) do
    verbose(state, "<- #{body}")

    case Jason.decode(body) do
      {:ok, %{"t" => "error"} = err} ->
        notify(state, {:error, err})
        {:close, %{state | done: true}}

      {:ok, json} ->
        dispatch_text(json, state)

      {:error, _} ->
        notify(state, {:error, :invalid_json})
        {:close, %{state | done: true}}
    end
  end

  def handle_frame(_other, state), do: {:ok, state}

  defp dispatch_text(json, %{phase: :welcome} = state) do
    case json do
      %{"t" => "welcome"} ->
        out = Jason.encode!(%{v: 1, t: "hello"})
        verbose(state, "-> #{out}")
        {:reply, {:text, out}, %{state | phase: :expect_hello_ack}}

      _ ->
        notify(state, {:error, {:unexpected, :welcome_phase, json}})
        {:close, %{state | done: true}}
    end
  end

  defp dispatch_text(json, %{phase: :expect_hello_ack} = state) do
    case json do
      %{"t" => "hello_ack"} ->
        out = Jason.encode!(%{v: 1, t: "auth", token: state.jwt})
        verbose(state, "-> auth …")
        {:reply, {:text, out}, %{state | phase: :expect_auth_ack}}

      _ ->
        notify(state, {:error, {:unexpected, :hello_ack_phase, json}})
        {:close, %{state | done: true}}
    end
  end

  defp dispatch_text(json, %{phase: :expect_auth_ack} = state) do
    case json do
      %{"t" => "ack"} = ack ->
        cond do
          state.auth_only == true ->
            notify(state, {:ok, {:authenticated, ack}})
            {:close, %{state | done: true}}

          true ->
            join =
              %{v: 1, t: "join"}
              |> maybe_put_hints(state.hints)

            out = Jason.encode!(join)
            verbose(state, "-> #{out}")
            {:reply, {:text, out}, %{state | phase: :expect_assigned}}
        end

      _ ->
        notify(state, {:error, {:unexpected, :auth_ack_phase, json}})
        {:close, %{state | done: true}}
    end
  end

  defp dispatch_text(json, %{phase: :expect_assigned} = state) do
    case json do
      %{"t" => "assigned"} = m ->
        notify(state, {:ok, {:in_world, m}})
        {:close, %{state | done: true}}

      _ ->
        notify(state, {:error, {:unexpected, :assigned_phase, json}})
        {:close, %{state | done: true}}
    end
  end

  defp maybe_put_hints(map, nil), do: map

  defp maybe_put_hints(map, h) when is_map(h) and map_size(h) == 0, do: map
  defp maybe_put_hints(map, h) when is_map(h), do: Map.put(map, :hints, h)

  defp notify(state, msg), do: send(state.parent, {:lunity_player, msg})

  defp verbose(%{verbose: true}, line), do: IO.puts(:stderr, "[lunity.player] #{line}")
  defp verbose(_, _), do: :ok

  @impl true
  def handle_disconnect(disconnect_map, %{done: true} = state) do
    _ = disconnect_map
    {:ok, state}
  end

  def handle_disconnect(%{reason: reason} = disconnect_map, state) do
    _ = disconnect_map
    notify(state, {:error, {:disconnect, reason}})
    {:ok, state}
  end
end
