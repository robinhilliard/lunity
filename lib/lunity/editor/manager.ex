defmodule Lunity.Editor.Manager do
  @moduledoc """
  Minimal ECSx manager for the Lunity editor when running standalone.

  Used when `mix lunity.edit` is run from the Lunity project (development).
  Has no components or systems; scenes without behaviour nodes will load.
  Scenes with behaviour nodes require the game's ECSx manager and components.
  """
  use ECSx.Manager

  def components, do: []
  def systems, do: []
end
