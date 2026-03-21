defmodule Lunity.Player.WsClient do
  @moduledoc false

  use WebSockex

  @type phase ::
          :welcome
          | :expect_hello_ack
          | :expect_auth_ack
          | :expect_assigned
          | :expect_subscribe_ack
          | :expect_actions_ack

  @type t :: %{
          parent: pid,
          jwt: String.t(),
          hints: map() | nil,
          auth_only: boolean(),
          followup: boolean(),
          resume: boolean(),
          assigned_row: map() | nil,
          subscribe_ack: map() | nil,
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
        auth = %{v: 1, t: "auth", token: state.jwt}
        auth = if Map.get(state, :resume) == true, do: Map.put(auth, :resume, true), else: auth
        out = Jason.encode!(auth)
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

          resumed_in_world?(ack) ->
            assigned = resumed_assigned_row(ack)
            resume_followup(state, assigned)

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
        if state.followup do
          out = Jason.encode!(%{v: 1, t: "subscribe_state", filter: nil})
          verbose(state, "-> #{out}")
          {:reply, {:text, out}, %{state | phase: :expect_subscribe_ack, assigned_row: m}}
        else
          notify(state, {:ok, {:in_world, m}})
          {:close, %{state | done: true}}
        end

      _ ->
        notify(state, {:error, {:unexpected, :assigned_phase, json}})
        {:close, %{state | done: true}}
    end
  end

  defp dispatch_text(%{"t" => "state"}, %{phase: ph} = state)
       when ph in [:expect_subscribe_ack, :expect_actions_ack] do
    verbose(state, "<- state (ignored)")
    {:ok, state}
  end

  defp dispatch_text(json, %{phase: :expect_subscribe_ack} = state) do
    case json do
      %{"t" => "subscribe_ack"} = sub ->
        assigned = state.assigned_row || %{}
        entity = Map.get(assigned, "entity_id") || "paddle_left"

        out =
          Jason.encode!(%{
            v: 1,
            t: "actions",
            frame: 1,
            actions: [%{"op" => "move", "entity" => to_string(entity), "dz" => 0.25}]
          })

        verbose(state, "-> #{out}")
        {:reply, {:text, out}, %{state | phase: :expect_actions_ack, subscribe_ack: sub}}

      _ ->
        notify(state, {:error, {:unexpected, :subscribe_phase, json}})
        {:close, %{state | done: true}}
    end
  end

  defp dispatch_text(json, %{phase: :expect_actions_ack} = state) do
    case json do
      %{"t" => "actions_ack"} = ack ->
        notify(
          state,
          {:ok, {:parity, state.assigned_row, state.subscribe_ack, ack}}
        )

        {:close, %{state | done: true}}

      _ ->
        notify(state, {:error, {:unexpected, :actions_ack_phase, json}})
        {:close, %{state | done: true}}
    end
  end

  defp resumed_in_world?(%{"resumed" => true, "instance_id" => id})
       when is_binary(id) and id != "",
       do: true

  defp resumed_in_world?(_), do: false

  defp resumed_assigned_row(ack) do
    %{
      "t" => "assigned",
      "instance_id" => ack["instance_id"],
      "entity_id" => Map.get(ack, "entity_id"),
      "spawn" => Map.get(ack, "spawn")
    }
  end

  defp resume_followup(%{followup: true} = state, assigned) do
    verbose(state, "-> resume: skip join (ack had instance_id), subscribe_state …")
    out = Jason.encode!(%{v: 1, t: "subscribe_state", filter: nil})
    verbose(state, "-> #{out}")

    {:reply, {:text, out}, %{state | phase: :expect_subscribe_ack, assigned_row: assigned}}
  end

  defp resume_followup(state, assigned) do
    notify(state, {:ok, {:in_world, assigned}})
    {:close, %{state | done: true}}
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
