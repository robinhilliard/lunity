defmodule Lunity.Input.Keymap do
  @moduledoc """
  Maps platform-specific keycodes to canonical `Lunity.Input.Keyboard.key()` atoms.

  Ensures that `:w` is `:w` whether the input came from a WX `char_hook`
  event (integer keycode) or a browser `KeyboardEvent.code` string.
  """

  # WX char_hook keycodes -- printable ASCII chars arrive as their codepoint.
  # Special keys use wxWidgets WXK_* constants.
  # Reference: https://docs.wxwidgets.org/3.2/defs_8h.html

  @wx_special %{
    8 => :backspace,
    9 => :tab,
    13 => :return,
    27 => :escape,
    32 => :space,
    127 => :delete,
    # Arrow keys
    314 => :arrow_left,
    315 => :arrow_up,
    316 => :arrow_right,
    317 => :arrow_down,
    # Modifier keys
    306 => :shift,
    308 => :alt,
    307 => :control,
    # Function keys
    340 => :f1,
    341 => :f2,
    342 => :f3,
    343 => :f4,
    344 => :f5,
    345 => :f6,
    346 => :f7,
    347 => :f8,
    348 => :f9,
    349 => :f10,
    350 => :f11,
    351 => :f12,
    # Navigation
    312 => :home,
    313 => :end_key,
    366 => :page_up,
    367 => :page_down,
    322 => :insert,
    # Numpad
    324 => :numpad_0,
    325 => :numpad_1,
    326 => :numpad_2,
    327 => :numpad_3,
    328 => :numpad_4,
    329 => :numpad_5,
    330 => :numpad_6,
    331 => :numpad_7,
    332 => :numpad_8,
    333 => :numpad_9,
    387 => :numpad_add,
    390 => :numpad_subtract,
    388 => :numpad_multiply,
    391 => :numpad_divide,
    389 => :numpad_decimal,
    370 => :numpad_enter
  }

  # JS event.code strings to atoms.
  # Reference: https://developer.mozilla.org/en-US/docs/Web/API/KeyboardEvent/code/code_values
  @js_codes %{
    "Backspace" => :backspace,
    "Tab" => :tab,
    "Enter" => :return,
    "Escape" => :escape,
    "Space" => :space,
    "Delete" => :delete,
    "ArrowLeft" => :arrow_left,
    "ArrowUp" => :arrow_up,
    "ArrowRight" => :arrow_right,
    "ArrowDown" => :arrow_down,
    "ShiftLeft" => :shift,
    "ShiftRight" => :shift,
    "AltLeft" => :alt,
    "AltRight" => :alt,
    "ControlLeft" => :control,
    "ControlRight" => :control,
    "F1" => :f1,
    "F2" => :f2,
    "F3" => :f3,
    "F4" => :f4,
    "F5" => :f5,
    "F6" => :f6,
    "F7" => :f7,
    "F8" => :f8,
    "F9" => :f9,
    "F10" => :f10,
    "F11" => :f11,
    "F12" => :f12,
    "Home" => :home,
    "End" => :end_key,
    "PageUp" => :page_up,
    "PageDown" => :page_down,
    "Insert" => :insert,
    "Numpad0" => :numpad_0,
    "Numpad1" => :numpad_1,
    "Numpad2" => :numpad_2,
    "Numpad3" => :numpad_3,
    "Numpad4" => :numpad_4,
    "Numpad5" => :numpad_5,
    "Numpad6" => :numpad_6,
    "Numpad7" => :numpad_7,
    "Numpad8" => :numpad_8,
    "Numpad9" => :numpad_9,
    "NumpadAdd" => :numpad_add,
    "NumpadSubtract" => :numpad_subtract,
    "NumpadMultiply" => :numpad_multiply,
    "NumpadDivide" => :numpad_divide,
    "NumpadDecimal" => :numpad_decimal,
    "NumpadEnter" => :numpad_enter,
    "Minus" => :minus,
    "Equal" => :equal,
    "BracketLeft" => :bracket_left,
    "BracketRight" => :bracket_right,
    "Backslash" => :backslash,
    "Semicolon" => :semicolon,
    "Quote" => :quote_key,
    "Backquote" => :backquote,
    "Comma" => :comma,
    "Period" => :period,
    "Slash" => :slash,
    "CapsLock" => :caps_lock,
    "MetaLeft" => :meta,
    "MetaRight" => :meta
  }

  @spec from_wx(integer()) :: Lunity.Input.Keyboard.key()
  def from_wx(key_code) when is_map_key(@wx_special, key_code) do
    Map.fetch!(@wx_special, key_code)
  end

  def from_wx(key_code) when key_code in ?a..?z do
    List.to_atom([key_code])
  end

  def from_wx(key_code) when key_code in ?A..?Z do
    List.to_atom([key_code + 32])
  end

  def from_wx(key_code) when key_code in ?0..?9 do
    :"digit_#{List.to_string([key_code])}"
  end

  def from_wx(key_code) do
    :"wx_#{key_code}"
  end

  @spec from_js(String.t()) :: Lunity.Input.Keyboard.key()
  def from_js(code) when is_map_key(@js_codes, code) do
    Map.fetch!(@js_codes, code)
  end

  # "KeyA" .. "KeyZ" -> :a .. :z
  def from_js("Key" <> <<char::utf8>>) when char in ?A..?Z do
    List.to_atom([char + 32])
  end

  # "Digit0" .. "Digit9" -> :digit_0 .. :digit_9
  def from_js("Digit" <> <<digit::utf8>>) when digit in ?0..?9 do
    :"digit_#{<<digit::utf8>>}"
  end

  def from_js(code) do
    code
    |> Macro.underscore()
    |> String.to_atom()
  end
end
