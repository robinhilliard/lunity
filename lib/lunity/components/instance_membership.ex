defmodule Lunity.Components.InstanceMembership do
  @moduledoc """
  Tracks which game instance an entity belongs to.

  Stored as a structured component with an index for fast lookup:
  `search(instance_id)` returns all entity IDs in that instance.
  """
  use Lunity.Component,
    storage: :structured,
    index: true
end
