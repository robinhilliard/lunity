defmodule Lunity.Input.SessionMeta do
  @moduledoc """
  Metadata for an input session, stored alongside raw input state in ETS.

  ## Identity (see Phase 0 / Phase 1)

  - **`input_session_id`** — the ETS key (`ref()` today from sockets or tests). Ephemeral per connection.
  - **`player_id`** — stable logical player (post-auth). Optional until login exists; use for reconnect and multiplayer roster.
  - **`instance_id`** — which `Lunity.Instance` (same string as `ComponentStore` / instance id) this binding targets. Required for gameplay input so the same `entity_id` in two instances does not share input.
  - **`entity_id`** — ECS entity controlled in that instance.

  Control **`mapping`** will become a dedicated `ControlMapping.t()` when that layer is built.
  """

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          player_id: String.t() | nil,
          instance_id: String.t() | nil,
          entity_id: term() | nil,
          spawn: map() | nil,
          mapping: map()
        }

  defstruct user_id: nil,
            player_id: nil,
            instance_id: nil,
            entity_id: nil,
            spawn: nil,
            mapping: %{}
end
