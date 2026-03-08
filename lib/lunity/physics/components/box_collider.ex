defmodule Lunity.Physics.Components.BoxCollider do
  @moduledoc "AABB full size {width, height, depth}. The kernel halves internally for overlap math."
  use Lunity.Component, storage: :tensor, shape: {3}, dtype: :f32
end
