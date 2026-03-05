defmodule Lunity.Light do
  @moduledoc """
  First-class light representation for Lunity scenes.

  Supports the three glTF/KHR_lights_punctual light types: directional, point,
  and spot. Use `new/1`, `directional/1`, `point/1`, or `spot/1` to construct.

  ## Examples

      Lunity.Light.directional(color: {1.0, 0.95, 0.8}, intensity: 2.0)
      Lunity.Light.point(color: {1.0, 0.6, 0.3}, intensity: 5.0, range: 10.0)
      Lunity.Light.spot(intensity: 8.0, inner_cone_angle: 0.26, outer_cone_angle: 0.52)
  """

  @type t :: %__MODULE__{
          type: :directional | :point | :spot,
          color: {float(), float(), float()},
          intensity: float(),
          range: float() | nil,
          inner_cone_angle: float(),
          outer_cone_angle: float()
        }

  defstruct type: :point,
            color: {1.0, 1.0, 1.0},
            intensity: 1.0,
            range: nil,
            inner_cone_angle: 0.0,
            outer_cone_angle: 0.7854

  @doc "Create a light with the given options."
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct(__MODULE__, opts)

  @doc "Create a directional light (sun, moon, fill)."
  @spec directional(keyword()) :: t()
  def directional(opts \\ []), do: new([{:type, :directional} | opts])

  @doc "Create a point light (lamp, torch, orb)."
  @spec point(keyword()) :: t()
  def point(opts \\ []), do: new([{:type, :point} | opts])

  @doc "Create a spot light (flashlight, stage light)."
  @spec spot(keyword()) :: t()
  def spot(opts \\ []), do: new([{:type, :spot} | opts])

  @doc "Convert to the map format expected by EAGL.Node's `:light` field."
  @spec to_eagl_light(t()) :: map()
  def to_eagl_light(%__MODULE__{} = light) do
    %{
      type: light.type,
      color: light.color,
      intensity: light.intensity,
      range: light.range,
      inner_cone_angle: light.inner_cone_angle,
      outer_cone_angle: light.outer_cone_angle
    }
  end

  @doc "Build a `Lunity.Light` from a plain map (e.g. from Lua mod tables)."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    type =
      case map[:type] || map["type"] do
        :directional -> :directional
        "directional" -> :directional
        :spot -> :spot
        "spot" -> :spot
        _ -> :point
      end

    color =
      case map[:color] || map["color"] do
        {r, g, b} -> {r * 1.0, g * 1.0, b * 1.0}
        [r, g, b | _] -> {r * 1.0, g * 1.0, b * 1.0}
        _ -> {1.0, 1.0, 1.0}
      end

    %__MODULE__{
      type: type,
      color: color,
      intensity: (map[:intensity] || map["intensity"] || 1.0) * 1.0,
      range: map[:range] || map["range"],
      inner_cone_angle: (map[:inner_cone_angle] || map["inner_cone_angle"] || 0.0) * 1.0,
      outer_cone_angle: (map[:outer_cone_angle] || map["outer_cone_angle"] || 0.7854) * 1.0
    }
  end
end
