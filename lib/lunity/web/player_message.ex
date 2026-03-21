defmodule Lunity.Web.PlayerMessage do
  @moduledoc false

  alias Lunity.Auth.PlayerJWT
  alias Lunity.Input.{Session, SessionMeta}
  alias Lunity.Web.EcsState

  @protocol_v 1

  @spec handle_in(String.t(), map()) ::
          {:ok, [String.t()], map()} | {:error, :invalid_json}

  def handle_in(text, state) when is_binary(text) do
    case Jason.decode(text) do
      {:ok, map} when is_map(map) -> dispatch(map, state)
      _ -> {:error, :invalid_json}
    end
  end

  defp dispatch(map, state) do
    case envelope(map) do
      {:ok, v, t, rest} ->
        if v != @protocol_v do
          reply_error("bad_version", "unsupported protocol v", state)
        else
          handle_t(t, rest, state)
        end

      :legacy_ping ->
        reply_ok([Jason.encode!(%{v: @protocol_v, t: "pong"})], state)

      :invalid ->
        reply_error("bad_envelope", "expected v and t", state)
    end
  end

  defp envelope(%{"v" => v, "t" => t} = m) when is_integer(v) and is_binary(t) do
    rest = Map.drop(m, ["v", "t"])
    {:ok, v, t, rest}
  end

  defp envelope(%{"type" => "ping"}) do
    :legacy_ping
  end

  defp envelope(_), do: :invalid

  defp handle_t("hello", _rest, state) do
    reply_ok(
      [
        Jason.encode!(%{
          v: @protocol_v,
          t: "hello_ack",
          protocol: @protocol_v
        })
      ],
      Map.put(state, :hello_ok, true)
    )
  end

  defp handle_t("auth", %{"token" => token}, state) when is_binary(token) do
    if not Map.get(state, :hello_ok, false) do
      reply_error("auth_order", "send hello before auth", state)
    else
      case PlayerJWT.verify_and_validate_token(token) do
        {:ok, claims} ->
          user_id = claims["user_id"]
          player_id = claims["player_id"] || user_id
          sid = state.session_id
          meta = Session.get_meta(sid) || %SessionMeta{}
          true = Session.update_meta(sid, %{meta | user_id: user_id, player_id: player_id})

          reply_ok(
            [
              Jason.encode!(%{
                v: @protocol_v,
                t: "ack",
                user_id: user_id,
                player_id: player_id
              })
            ],
            Map.put(state, :phase, :authenticated)
          )

        {:error, reason} ->
          reply_error(
            "auth_failed",
            "token invalid: #{inspect(reason)}",
            state
          )
      end
    end
  end

  defp handle_t("auth", _, state) do
    reply_error("bad_auth", "missing token", state)
  end

  defp handle_t("join", rest, state) do
    cond do
      state[:phase] not in [:authenticated, :in_world] ->
        reply_error("join_denied", "authenticate first", state)

      not Map.has_key?(rest, "instance_id") ->
        reply_error("bad_join", "instance_id required", state)

      true ->
        instance_id = rest["instance_id"]
        entity_raw = Map.get(rest, "entity_id")
        spawn = Map.get(rest, "spawn")

        if not is_binary(instance_id) do
          reply_error("bad_join", "instance_id must be a string", state)
        else
          case Lunity.Instance.get(instance_id) do
            nil ->
              reply_error("instance_not_found", instance_id, state)

            _ ->
              entity_id = parse_entity_id(entity_raw)
              sid = state.session_id
              meta = Session.get_meta(sid) || %SessionMeta{}

              true =
                Session.update_meta(sid, %{
                  meta
                  | instance_id: instance_id,
                    entity_id: entity_id,
                    spawn: if(is_map(spawn), do: spawn, else: nil)
                })

              reply_ok(
                [
                  Jason.encode!(%{
                    v: @protocol_v,
                    t: "assigned",
                    instance_id: instance_id,
                    entity_id: entity_to_wire(entity_id),
                    spawn: spawn
                  })
                ],
                Map.put(state, :phase, :in_world)
              )
          end
        end
    end
  end

  defp handle_t("leave", _rest, state) do
    if state[:phase] != :in_world do
      reply_ok([Jason.encode!(%{v: @protocol_v, t: "left"})], state)
    else
      sid = state.session_id
      meta = Session.get_meta(sid) || %SessionMeta{}
      true = Session.update_meta(sid, %{meta | instance_id: nil, entity_id: nil, spawn: nil})

      reply_ok(
        [Jason.encode!(%{v: @protocol_v, t: "left"})],
        Map.put(state, :phase, :authenticated)
      )
    end
  end

  defp handle_t("actions", rest, state) do
    if state[:phase] != :in_world do
      reply_error("actions_denied", "join an instance first", state)
    else
      actions = Map.get(rest, "actions") || []
      frame = Map.get(rest, "frame")

      if is_list(actions) and Enum.all?(actions, &is_map/1) do
        norm =
          Enum.map(actions, fn m ->
            Map.new(m, fn {k, v} -> {to_string(k), v} end)
          end)

        :ok = Session.put_actions(state.session_id, norm)

        ack =
          Jason.encode!(%{
            v: @protocol_v,
            t: "actions_ack",
            frame: frame
          })

        reply_ok([ack], state)
      else
        reply_error("bad_actions", "actions must be a list of objects", state)
      end
    end
  end

  defp handle_t("subscribe_state", rest, state) do
    if state[:phase] != :in_world do
      reply_error("subscribe_denied", "join an instance first", state)
    else
      filter = Map.get(rest, "filter")
      meta = Session.get_meta(state.session_id)

      if is_nil(meta) or is_nil(meta.instance_id) do
        reply_error("subscribe_denied", "no instance bound", state)
      else
        interval_ms = Application.get_env(:lunity, :player_state_push_interval_ms, 100)

        reply_ok(
          [
            Jason.encode!(%{
              v: @protocol_v,
              t: "subscribe_ack",
              filter: filter,
              interval_ms: interval_ms
            })
          ],
          schedule_state_push(%{state | state_sub: %{filter: filter}, state_interval_ms: interval_ms})
        )
      end
    end
  end

  defp handle_t("unsubscribe_state", _rest, state) do
    reply_ok(
      [Jason.encode!(%{v: @protocol_v, t: "unsubscribe_ack"})],
      cancel_state_push(state)
    )
  end

  defp handle_t("ping", _, state) do
    reply_ok([Jason.encode!(%{v: @protocol_v, t: "pong"})], state)
  end

  defp handle_t(other, _, state) do
    reply_error("unknown_type", other, state)
  end

  defp reply_ok(frames, state), do: {:ok, frames, state}

  defp reply_error(code, message, state) do
    json =
      Jason.encode!(%{
        v: @protocol_v,
        t: "error",
        code: code,
        message: message
      })

    {:ok, [json], state}
  end

  defp parse_entity_id(nil), do: nil
  defp parse_entity_id(s) when is_binary(s), do: String.to_atom(s)

  defp entity_to_wire(nil), do: nil
  defp entity_to_wire(id) when is_atom(id), do: Atom.to_string(id)
  defp entity_to_wire(id), do: to_string(id)

  defp schedule_state_push(state) do
    if ref = state[:state_timer_ref] do
      Process.cancel_timer(ref)
    end

    ms = Map.get(state, :state_interval_ms, 100)
    ref = Process.send_after(self(), :player_state_push, ms)
    Map.put(state, :state_timer_ref, ref)
  end

  defp cancel_state_push(state) do
    if ref = state[:state_timer_ref] do
      Process.cancel_timer(ref)
    end

    Map.merge(state, %{state_timer_ref: nil, state_sub: nil})
  end

  @doc false
  def cancel_state_timer(state), do: cancel_state_push(state)

  @doc false
  def schedule_next_state_push(state), do: schedule_state_push(state)

  @doc """
  Builds a JSON `state` frame for the current socket meta (full ECS when `filter` is nil).
  """
  @spec encode_state_frame(String.t(), term() | nil) :: String.t()
  def encode_state_frame(instance_id, filter) when is_binary(instance_id) do
    snap =
      case Lunity.Instance.snapshot(instance_id) do
        {:error, _} -> %{error: "snapshot_unavailable"}
        s when is_map(s) -> EcsState.encode_for_wire(s)
        _ -> %{error: "snapshot_unavailable"}
      end

    body = %{v: @protocol_v, t: "state", filter: filter, ecs: snap}
    Jason.encode!(body)
  end
end
