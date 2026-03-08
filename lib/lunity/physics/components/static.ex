defmodule Lunity.Physics.Components.Static do
  @moduledoc "1 = static/kinematic (not pushed by collisions), 0 = dynamic."
  use Lunity.Component, storage: :tensor, shape: {}, dtype: :s32
end
