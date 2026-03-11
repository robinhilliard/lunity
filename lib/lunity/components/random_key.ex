defmodule Lunity.Components.RandomKey do
  @moduledoc """
  PRNG key for deterministic randomness in tensor systems.

  Stores an `Nx.Random` key as a `{2}` u32 tensor per entity. Systems
  that need randomness split the key, use the subkey for sampling, and
  write the updated key back. This gives each entity its own reproducible
  random stream without side effects.
  """
  use Lunity.Component, storage: :tensor, shape: {2}, dtype: :u32
end
