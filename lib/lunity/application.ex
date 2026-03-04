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
    init_project_context_from_mix()

    children = [
      {Task, fn -> Lunity.Editor.View.run() end}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp init_project_context_from_mix do
    case {Application.get_env(:lunity, :project_priv),
          Application.get_env(:lunity, :project_app)} do
      {priv, app} when is_binary(priv) and app ->
        cwd = Path.dirname(priv)
        Lunity.Editor.State.put_project_context(cwd, app)
      _ ->
        :ok
    end
  end
end
