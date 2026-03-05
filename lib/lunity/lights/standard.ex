defmodule Lunity.Lights.Standard do
  @moduledoc """
  Pre-defined light presets for quick prototyping.

  All functions return `%Lunity.Light{}` structs that can be passed directly
  to the `light:` option on scene nodes.

  ## Examples

      scene do
        light :sun, light: Lunity.Lights.Standard.sun(), rotation: {-0.38, 0.0, 0.0, 0.92}
        node :ball, prefab: "box", material: Pong.Materials.white
      end
  """

  alias Lunity.Light

  @doc "Warm directional sun light (intensity 2.0)."
  @spec sun() :: Light.t()
  def sun, do: Light.directional(color: {1.0, 0.95, 0.8}, intensity: 2.0)

  @doc "Cool directional fill light (intensity 0.5)."
  @spec fill() :: Light.t()
  def fill, do: Light.directional(color: {0.4, 0.5, 0.7}, intensity: 0.5)

  @doc "Warm point light (intensity 5.0, range 10)."
  @spec warm_point() :: Light.t()
  def warm_point, do: Light.point(color: {1.0, 0.8, 0.6}, intensity: 5.0, range: 10.0)

  @doc "Cool point light (intensity 3.0, range 8)."
  @spec cool_point() :: Light.t()
  def cool_point, do: Light.point(color: {0.6, 0.7, 1.0}, intensity: 3.0, range: 8.0)

  @doc "Neutral white point light (intensity 3.0, range 12)."
  @spec white_point() :: Light.t()
  def white_point, do: Light.point(color: {1.0, 1.0, 1.0}, intensity: 3.0, range: 12.0)

  @doc "Warm narrow spot light (intensity 8.0, 30-degree cone)."
  @spec warm_spot() :: Light.t()
  def warm_spot do
    Light.spot(
      color: {1.0, 0.85, 0.6},
      intensity: 8.0,
      range: 15.0,
      inner_cone_angle: 0.17,
      outer_cone_angle: 0.52
    )
  end
end
