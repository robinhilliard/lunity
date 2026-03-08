defmodule Lunity.Physics.Components.CollisionMask do
  @moduledoc "Bitmask identifying which collision layers this entity collides WITH."
  use Lunity.Component, storage: :tensor, shape: {}, dtype: :s32
end
