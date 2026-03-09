defmodule Lunity.Input.Gamepad do
  @moduledoc """
  Raw gamepad state mirroring the Web Gamepad API shape.

  Populated identically by:
  - Browser: `navigator.getGamepads()` via WebSocket
  - Native: gilrs via Rustler NIF
  """

  defmodule Button do
    @moduledoc "Single gamepad button with pressed state and analog value."

    @type t :: %__MODULE__{pressed: boolean(), value: float()}

    defstruct pressed: false, value: 0.0
  end

  @type t :: %__MODULE__{
          id: String.t(),
          index: non_neg_integer(),
          connected: boolean(),
          mapping: :standard | :unknown,
          axes: [float()],
          buttons: [Button.t()],
          timestamp: integer()
        }

  defstruct id: "",
            index: 0,
            connected: false,
            mapping: :unknown,
            axes: [],
            buttons: [],
            timestamp: 0

  @spec axis(t(), non_neg_integer()) :: float() | nil
  def axis(%__MODULE__{axes: axes}, index), do: Enum.at(axes, index)

  @spec button(t(), non_neg_integer()) :: Button.t() | nil
  def button(%__MODULE__{buttons: buttons}, index), do: Enum.at(buttons, index)

  @spec button_pressed?(t(), non_neg_integer()) :: boolean()
  def button_pressed?(gamepad, index) do
    case button(gamepad, index) do
      %Button{pressed: pressed} -> pressed
      nil -> false
    end
  end

  @spec from_json(map()) :: t()
  def from_json(data) do
    buttons =
      Enum.map(data["buttons"] || [], fn b ->
        %Button{pressed: b["pressed"] || false, value: (b["value"] || 0.0) * 1.0}
      end)

    mapping =
      case data["mapping"] do
        "standard" -> :standard
        _ -> :unknown
      end

    %__MODULE__{
      id: data["id"] || "",
      index: data["index"] || 0,
      connected: data["connected"] || false,
      mapping: mapping,
      axes: Enum.map(data["axes"] || [], &(&1 * 1.0)),
      buttons: buttons,
      timestamp: data["timestamp"] || 0
    }
  end
end
