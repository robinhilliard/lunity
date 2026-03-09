defmodule Lunity.Input.Mouse do
  @moduledoc """
  Raw mouse state: cursor position, button states, and wheel delta.
  """

  @type button :: :left | :right | :middle

  @type t :: %__MODULE__{
          position: {float(), float()},
          buttons: %{button() => boolean()},
          wheel_delta: float()
        }

  defstruct position: {0.0, 0.0},
            buttons: %{left: false, right: false, middle: false},
            wheel_delta: 0.0

  @spec button_down?(t(), button()) :: boolean()
  def button_down?(%__MODULE__{buttons: buttons}, button), do: Map.get(buttons, button, false)
end
