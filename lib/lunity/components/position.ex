defmodule Lunity.Components.Position do
  @moduledoc "Entity world position {x, y, z}. Engine-level -- used by renderer, editor, and physics."
  use Lunity.Component, storage: :tensor, shape: {3}, dtype: :f32
end
