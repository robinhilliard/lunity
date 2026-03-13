defmodule Lunity.Editor.Theme do
  @moduledoc """
  Derives editor UI colours from the OS theme via wxSystemSettings.

  Call `detect/0` once after `:wx.new()` to read the system colours.
  All colours are returned as `{r, g, b}` tuples (no alpha).

  ## Dark mode detection

  Uses the `wxSYS_COLOUR_WINDOW` luminance: < 128 = dark, >= 128 = light.

  ## Hover colour

  Blends the system highlight colour toward the tree background at 30%
  opacity, giving a transparent-overlay effect. Pre-blended because native
  tree controls don't support alpha.
  """

  # wxSYS_COLOUR constants
  @sys_window 5
  @sys_window_text 6
  @sys_highlight 13
  @sys_highlight_text 14

  @type colours :: %{
          dark?: boolean(),
          window_bg: {integer(), integer(), integer()},
          window_fg: {integer(), integer(), integer()},
          select_bg: {integer(), integer(), integer()},
          select_fg: {integer(), integer(), integer()},
          hover_bg: {integer(), integer(), integer()},
          hover_fg: {integer(), integer(), integer()},
          panel_bg: {integer(), integer(), integer()},
          separator: {integer(), integer(), integer()},
          tree_bg: {integer(), integer(), integer()}
        }

  @doc "Read system theme colours. Call after `:wx.new()`."
  @spec detect() :: colours()
  def detect do
    window_bg = rgb(:wxSystemSettings.getColour(@sys_window))
    window_fg = rgb(:wxSystemSettings.getColour(@sys_window_text))
    select_bg = rgb(:wxSystemSettings.getColour(@sys_highlight))
    select_fg = rgb(:wxSystemSettings.getColour(@sys_highlight_text))

    dark? = luminance(window_bg) < 128

    # In dark mode, tree_bg is lightened so black disclosure triangles stand out.
    tree_bg =
      if dark?,
        do: shift(window_bg, 20),
        else: window_bg

    # Hover: transparent highlight over tree background (pre-blended; native tree has no alpha)
    hover_bg = blend(select_bg, tree_bg, 0.5)
    hover_fg = window_fg

    panel_bg =
      if dark?,
        do: shift(window_bg, 10),
        else: shift(window_bg, -10)

    separator =
      if dark?,
        do: shift(window_bg, 30),
        else: shift(window_bg, -30)

    %{
      dark?: dark?,
      window_bg: window_bg,
      window_fg: window_fg,
      select_bg: select_bg,
      select_fg: select_fg,
      hover_bg: hover_bg,
      hover_fg: hover_fg,
      panel_bg: panel_bg,
      separator: separator,
      tree_bg: tree_bg
    }
  end

  defp rgb({r, g, b, _a}), do: {r, g, b}
  defp rgb({r, g, b}), do: {r, g, b}

  defp luminance({r, g, b}), do: 0.299 * r + 0.587 * g + 0.114 * b

  defp blend({r1, g1, b1}, {r2, g2, b2}, alpha) do
    {
      round(r1 * alpha + r2 * (1 - alpha)),
      round(g1 * alpha + g2 * (1 - alpha)),
      round(b1 * alpha + b2 * (1 - alpha))
    }
  end

  defp shift({r, g, b}, amount) do
    {clamp(r + amount), clamp(g + amount), clamp(b + amount)}
  end

  defp clamp(v) when v < 0, do: 0
  defp clamp(v) when v > 255, do: 255
  defp clamp(v), do: round(v)
end
