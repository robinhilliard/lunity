defmodule Lunity.Input.Keyboard do
  @moduledoc """
  Raw keyboard state. Keys are represented as atoms (`:w`, `:space`,
  `:arrow_up`, etc.) normalised from platform-specific keycodes by
  `Lunity.Input.Keymap`.
  """

  @type key :: atom()

  @type t :: %__MODULE__{keys_down: MapSet.t(key())}

  defstruct keys_down: MapSet.new()

  @spec key_down?(t(), key()) :: boolean()
  def key_down?(%__MODULE__{keys_down: keys}, key), do: MapSet.member?(keys, key)
end
