defmodule Lunity.Input.SessionMeta do
  @moduledoc """
  Metadata for an input session, stored alongside raw input state in ETS.

  Associates a session with a user account and player entity, and holds
  the control mapping configuration used to translate raw input into
  semantic actions. The `mapping` type will be refined to a dedicated
  `ControlMapping.t()` when that layer is built.
  """

  @type t :: %__MODULE__{
          user_id: String.t() | nil,
          entity_id: term() | nil,
          mapping: map()
        }

  defstruct user_id: nil,
            entity_id: nil,
            mapping: %{}
end
