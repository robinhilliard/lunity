defmodule Lunity.Web.PlayerJoin do
  @moduledoc """
  Optional hook: the **game** decides `instance_id`, `entity_id`, and `spawn` after `auth`.

  Configure:

      config :lunity, :player_join, {MyGame.PlayerJoin, :assign}

  When set, the wire **`join`** body may only be `{}` or `{"hints":{...}}`. Top-level
  **`instance_id`**, **`entity_id`**, and **`spawn`** are **rejected** — they cannot be set by
  the client (anti-cheat). Only **`hints`** is accepted for non-authoritative data (queue name,
  cosmetics, etc.). The callback receives `client` as `Map.take(rest, ["hints"])` (empty or
  `hints` only).

  - Return `{:ok, instance_id, entity_id, spawn}` where `instance_id` must refer to a running
    `Lunity.Instance`, `entity_id` is an atom or string (or `nil`), and `spawn` is a map or `nil`.

  When **unset**, behaviour is unchanged: **`join` requires `instance_id`** from the client
  (browser/CLI chooses the instance explicitly).
  """

  @type info :: %{
          session_id: term(),
          user_id: String.t(),
          player_id: String.t(),
          client: %{String.t() => term()}
        }

  @doc """
  Returns the authoritative assignment for this player session.

  `client` is the JSON object for `join` with envelope fields removed in the handler — use
  string keys (`"hints"`, etc.).
  """
  @callback assign(info()) ::
              {:ok, instance_id :: String.t(), entity_id :: atom() | String.t() | nil,
               spawn :: map() | nil}
              | {:error, code :: String.t(), message :: String.t()}
end
