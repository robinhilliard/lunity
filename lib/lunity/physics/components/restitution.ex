defmodule Lunity.Physics.Components.Restitution do
  @moduledoc "Bounciness coefficient. 1.0 = perfect elastic bounce, >1.0 = gains energy (e.g. accelerating pong ball)."
  use Lunity.Component, storage: :tensor, shape: {}, dtype: :f32
end
