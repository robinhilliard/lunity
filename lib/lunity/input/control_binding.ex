defmodule Lunity.Input.ControlBinding do
  @moduledoc """
  Canonical mapping from string key names (Lua / JSON) to `Lunity.Input.Keyboard.key()` atoms.

  Used by mods and clients so bindings stay consistent across Lua and Elixir.
  """

  @doc """
  Parses a lowercase string key name into the atom used in `Lunity.Input.Session`.
  Unknown keys fall back to `Keymap.from_js/1`-style underscore atoms.
  """
  @spec key_from_string(String.t()) :: Lunity.Input.Keyboard.key()
  def key_from_string(key) when is_binary(key) do
    case String.downcase(key) do
      "w" -> :w
      "s" -> :s
      "a" -> :a
      "d" -> :d
      "arrow_up" -> :arrow_up
      "arrow_down" -> :arrow_down
      "arrow_left" -> :arrow_left
      "arrow_right" -> :arrow_right
      "space" -> :space
      other -> fallback_key_atom(other)
    end
  end

  def key_from_string(key) when is_atom(key), do: key

  defp fallback_key_atom(s) do
    # Avoid String.to_atom on arbitrary user input; unknown keys map to unlikely atoms.
    case Macro.underscore(s) do
      "" -> :unknown
      a -> String.to_atom(a)
    end
  end
end
