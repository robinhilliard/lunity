defmodule Lunity.Test.Support.MockComponent do
  @moduledoc false
  defstruct [:value]

  def add(entity_id, struct) do
    # Store in process dictionary for test assertions
    key = :entity_factory_adds
    current = Process.get(key, [])
    Process.put(key, [{entity_id, struct} | current])
  end
end
