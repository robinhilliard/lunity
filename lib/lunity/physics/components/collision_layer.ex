defmodule Lunity.Physics.Components.CollisionLayer do
  @moduledoc "Bitmask identifying which collision layer this entity belongs to (1, 2, 4, 8...)."
  use Lunity.Component, storage: :tensor, shape: {}, dtype: :s32
end
