defmodule Lunity.Physics.Components.Velocity do
  @moduledoc "Linear velocity {vx, vy, vz}. Physics-level -- used by collision response and movement."
  use Lunity.Component, storage: :tensor, shape: {3}, dtype: :f32
end
