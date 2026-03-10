defmodule Lunity.Input.HeadPose do
  @moduledoc """
  6-DOF head tracking state from TrackIR or compatible devices.

  All rotation values are in degrees (-180 to +180), translation values
  in centimeters (-50 to +50). The `frame` field carries the TrackIR
  frame signature for change detection.
  """

  @type t :: %__MODULE__{
          yaw: float(),
          pitch: float(),
          roll: float(),
          x: float(),
          y: float(),
          z: float(),
          frame: non_neg_integer()
        }

  defstruct yaw: 0.0,
            pitch: 0.0,
            roll: 0.0,
            x: 0.0,
            y: 0.0,
            z: 0.0,
            frame: 0
end
