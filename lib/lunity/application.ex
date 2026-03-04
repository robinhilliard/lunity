defmodule Lunity.Application do
  @moduledoc """
  Application callback for Lunity. When mode is :editor, starts the editor window.
  """
  use Application

  @impl true
  def start(_type, _args) do
    if Application.get_env(:lunity, :mode) == :editor do
      start_editor()
    else
      # Library mode - no supervision tree
      Supervisor.start_link([], strategy: :one_for_one)
    end
  end

  defp start_editor do
    Lunity.Editor.State.init()

    children = [
      {Task, fn -> Lunity.Editor.View.run() end}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
