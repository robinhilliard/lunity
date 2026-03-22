defmodule Lunity.Web.PlayerWire do
  @moduledoc false
  # Single place for JSON object shapes written to the player WebSocket. Tests compare
  # `Jason.encode!(...)` to full-stack frames so transcript and integration stay aligned.

  alias Lunity.Input.SessionMeta

  @protocol_v 1

  @spec resume_ack_map(String.t(), String.t(), SessionMeta.t()) :: map()
  def resume_ack_map(user_id, player_id, %SessionMeta{} = meta) do
    base = %{
      v: @protocol_v,
      t: "ack",
      user_id: user_id,
      player_id: player_id,
      resumed: true
    }

    if is_binary(meta.instance_id) and meta.instance_id != "" do
      Map.merge(base, %{
        instance_id: meta.instance_id,
        entity_id: entity_to_wire(meta.entity_id),
        spawn: meta.spawn
      })
    else
      base
    end
  end

  @spec error_map(String.t(), String.t()) :: map()
  def error_map(code, message) when is_binary(code) and is_binary(message) do
    %{
      v: @protocol_v,
      t: "error",
      code: code,
      message: message
    }
  end

  @spec entity_to_wire(term()) :: String.t() | nil
  def entity_to_wire(nil), do: nil
  def entity_to_wire(id) when is_atom(id), do: Atom.to_string(id)
  def entity_to_wire(id), do: to_string(id)
end
