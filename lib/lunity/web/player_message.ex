defmodule Lunity.Web.PlayerMessage do
  @moduledoc false

  alias Lunity.Auth.PlayerJWT
  alias Lunity.Input.{Session, SessionMeta}
  alias Lunity.Player.Resume
  alias Lunity.Web.{EcsState, PlayerWire}

  @protocol_v 1
  @max_actions_per_frame 64
  @max_spawn_depth 4
  @max_spawn_entries 32
  @max_string_len 256

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

  defp handle_t("auth", %{"token" => token} = rest, state) when is_binary(token) do
    if not Map.get(state, :hello_ok, false) do
      reply_error("auth_order", "send hello before auth", state)
    else
      resume = Map.get(rest, "resume") == true

      case PlayerJWT.verify_and_validate_token(token) do
        {:ok, claims} ->
          user_id = claims["user_id"]
          player_id = claims["player_id"] || user_id
          sid = state.session_id

          cond do
            resume ->
              case Resume.take(player_id) do
                :none ->
                  reply_error("resume_failed", "no pending session to resume", state)

                {:ok, old_sid} ->
                  :ok = Session.clone_from(old_sid, sid)
                  meta = Session.get_meta(sid) || %SessionMeta{}

                  true =
                    Session.update_meta(sid, %{meta | user_id: user_id, player_id: player_id})

                  meta = Session.get_meta(sid) || %SessionMeta{}

                  phase =
                    if is_binary(meta.instance_id) and meta.instance_id != "" do
                      :in_world
                    else
                      :authenticated
                    end

                  ack_map = PlayerWire.resume_ack_map(user_id, player_id, meta)

                  reply_ok(
                    [Jason.encode!(ack_map)],
                    Map.put(state, :phase, phase)
                  )
              end

            true ->
              :ok = Resume.clear_pending(player_id)
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
          end

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
    if state[:phase] not in [:authenticated, :in_world] do
      reply_error("join_denied", "authenticate first", state)
    else
      case Application.get_env(:lunity, :player_join) do
        {mod, fun} when is_atom(mod) and is_atom(fun) and mod != nil and fun != nil ->
          join_with_callback(mod, fun, rest, state)

        _ ->
          join_client_driven(rest, state)
      end
    end
  end

  defp handle_t("leave", _rest, state) do
    state =
      if state[:phase] == :in_world and state[:state_sub] do
        cancel_state_push(state)
      else
        state
      end

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

      cond do
        not is_list(actions) ->
          reply_error("bad_actions", "actions must be a list", state)

        length(actions) > @max_actions_per_frame ->
          reply_error(
            "bad_actions",
            "at most #{@max_actions_per_frame} actions per frame",
            state
          )

        not Enum.all?(actions, &is_map/1) ->
          reply_error("bad_actions", "each action must be an object", state)

        true ->
          case normalize_actions(actions) do
            {:error, reason} ->
              reply_error("bad_actions", reason, state)

            {:ok, norm} ->
              :ok = Session.put_actions(state.session_id, norm)

              ack =
                Jason.encode!(%{
                  v: @protocol_v,
                  t: "actions_ack",
                  frame: frame
                })

              reply_ok([ack], state)
          end
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
          schedule_state_push(%{
            state
            | state_sub: %{filter: filter},
              state_interval_ms: interval_ms
          })
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

  defp join_with_callback(mod, fun, rest, state) do
    sid = state.session_id
    meta = Session.get_meta(sid) || %SessionMeta{}
    user_id = meta.user_id
    player_id = meta.player_id || user_id

    if not is_binary(user_id) or user_id == "" do
      reply_error("join_denied", "authenticate first", state)
    else
      case validate_join_callback_client(rest) do
        :ok ->
          info = %{
            session_id: sid,
            user_id: user_id,
            player_id: player_id || user_id,
            client: callback_client(rest)
          }

          case apply(mod, fun, [info]) do
            {:ok, instance_id, entity_raw, spawn} when is_binary(instance_id) ->
              finalize_join(instance_id, entity_raw, spawn, state)

            {:error, code, message} when is_binary(code) and is_binary(message) ->
              reply_error(code, message, state)

            other ->
              reply_error(
                "join_callback",
                "expected {:ok, id, entity, spawn} or {:error, code, msg}, got: #{inspect(other)}",
                state
              )
          end

        {:error, code, message} ->
          reply_error(code, message, state)
      end
    end
  end

  defp validate_join_callback_client(rest) when is_map(rest) do
    sorted_keys = rest |> Map.keys() |> Enum.sort()

    cond do
      Map.has_key?(rest, "instance_id") or Map.has_key?(rest, "entity_id") or
          Map.has_key?(rest, "spawn") ->
        {:error, "join_forbidden", "instance_id, entity_id, and spawn are assigned by the server"}

      sorted_keys == [] ->
        :ok

      sorted_keys == ["hints"] and is_map(rest["hints"]) ->
        :ok

      sorted_keys == ["hints"] ->
        {:error, "bad_hints", "hints must be an object"}

      true ->
        {:error, "join_forbidden", "only optional hints may be sent in join"}
    end
  end

  defp callback_client(rest) do
    Map.take(rest, ["hints"])
  end

  defp join_client_driven(rest, state) do
    cond do
      not Map.has_key?(rest, "instance_id") ->
        reply_error("bad_join", "instance_id required", state)

      true ->
        instance_id = rest["instance_id"]
        entity_raw = Map.get(rest, "entity_id")
        spawn = Map.get(rest, "spawn")

        if not is_binary(instance_id) do
          reply_error("bad_join", "instance_id must be a string", state)
        else
          finalize_join(instance_id, entity_raw, spawn, state)
        end
    end
  end

  defp finalize_join(instance_id, entity_raw, spawn, state) do
    case Lunity.Instance.get(instance_id) do
      nil ->
        reply_error("instance_not_found", instance_id, state)

      _ ->
        case coerce_entity_id(entity_raw) do
          {:error, reason} ->
            reply_error("bad_join", reason, state)

          {:ok, entity_id} ->
            case normalize_spawn(spawn) do
              {:error, reason} ->
                reply_error("bad_spawn", reason, state)

              {:ok, spawn_norm} ->
                commit_join(instance_id, entity_id, spawn_norm, state)
            end
        end
    end
  end

  defp commit_join(instance_id, entity_id, spawn_norm, state) do
    sid = state.session_id
    meta = Session.get_meta(sid) || %SessionMeta{}

    true =
      Session.update_meta(sid, %{
        meta
        | instance_id: instance_id,
          entity_id: entity_id,
          spawn: spawn_norm
      })

    reply_ok(
      [
        Jason.encode!(%{
          v: @protocol_v,
          t: "assigned",
          instance_id: instance_id,
          entity_id: PlayerWire.entity_to_wire(entity_id),
          spawn: spawn_norm
        })
      ],
      Map.put(state, :phase, :in_world)
    )
  end

  defp reply_ok(frames, state), do: {:ok, frames, state}

  defp reply_error(code, message, state) do
    json = Jason.encode!(PlayerWire.error_map(code, message))
    {:ok, [json], state}
  end

  defp parse_entity_id(nil), do: {:ok, nil}

  defp parse_entity_id(s) when is_binary(s) do
    if s == "" do
      {:error, "entity_id must be non-empty"}
    else
      {:ok, String.to_atom(s)}
    end
  end

  defp parse_entity_id(_), do: {:error, "entity_id must be a string"}

  defp coerce_entity_id(nil), do: {:ok, nil}
  defp coerce_entity_id(id) when is_atom(id), do: {:ok, id}
  defp coerce_entity_id(s) when is_binary(s), do: parse_entity_id(s)
  defp coerce_entity_id(_), do: {:error, "entity_id must be a string, atom, or null"}

  defp normalize_spawn(nil), do: {:ok, nil}

  defp normalize_spawn(m) when is_map(m) do
    if map_size(m) > @max_spawn_entries do
      {:error, "spawn map too large"}
    else
      {:ok, normalize_spawn_map(m, 0)}
    end
  end

  defp normalize_spawn(_), do: {:error, "spawn must be an object or null"}

  defp normalize_spawn_map(_m, depth) when depth > @max_spawn_depth do
    %{}
  end

  defp normalize_spawn_map(m, depth) do
    Map.new(m, fn {k, v} ->
      key = to_string(k)
      key = String.slice(key, 0, @max_string_len)
      {key, normalize_spawn_value(v, depth + 1)}
    end)
  end

  defp normalize_spawn_value(_v, depth) when depth > @max_spawn_depth, do: nil

  defp normalize_spawn_value(v, depth) when is_map(v) do
    normalize_spawn_map(v, depth)
  end

  defp normalize_spawn_value(v, _depth) when is_binary(v) do
    String.slice(v, 0, @max_string_len)
  end

  defp normalize_spawn_value(v, _depth) when is_number(v) or is_boolean(v) or is_nil(v), do: v

  defp normalize_spawn_value(v, _depth) when is_list(v) do
    Enum.take(v, 32)
    |> Enum.map(&normalize_spawn_value(&1, @max_spawn_depth))
  end

  defp normalize_spawn_value(v, _depth), do: inspect(v)

  defp normalize_actions(actions) do
    Enum.reduce_while(actions, {:ok, []}, fn m, {:ok, acc} ->
      m = Map.new(m, fn {k, v} -> {to_string(k), v} end)

      op = Map.get(m, "op")

      cond do
        not is_binary(op) or op == "" ->
          {:halt, {:error, "each action needs a non-empty string op"}}

        String.length(op) > @max_string_len ->
          {:halt, {:error, "op too long"}}

        true ->
          m =
            m
            |> cap_string_field("entity")
            |> cap_numeric_field("dz")

          {:cont, {:ok, [m | acc]}}
      end
    end)
    |> case do
      {:ok, rev} -> {:ok, Enum.reverse(rev)}
      other -> other
    end
  end

  defp cap_string_field(m, key) do
    case Map.get(m, key) do
      s when is_binary(s) -> Map.put(m, key, String.slice(s, 0, @max_string_len))
      _ -> m
    end
  end

  defp cap_numeric_field(m, key) do
    case Map.get(m, key) do
      n when is_number(n) -> Map.put(m, key, max(-1.0, min(1.0, n * 1.0)))
      _ -> m
    end
  end

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
