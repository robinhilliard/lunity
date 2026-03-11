defmodule Lunity.Components.DeltaTime do
  @moduledoc """
  Elapsed time in seconds since the last tick.

  Scalar tensor (shape `{}`) set by the Manager each tick. Systems read it
  like any other component to achieve frame-rate independent behaviour.
  """
  use Lunity.Component, storage: :tensor, shape: {}, dtype: :f32
end
