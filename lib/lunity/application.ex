defmodule Lunity.Application do
  @moduledoc """
  Application callback for Lunity. When mode is :editor, starts the editor window.
  Optionally starts the mod EventBus and loads mods when `:mods_enabled` is true.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    if Application.get_env(:lunity, :mode) == :editor do
      start_editor()
    else
      Supervisor.start_link(mod_children(), strategy: :one_for_one)
    end
  end

  defp start_editor do
    Lunity.Editor.State.init()
    init_project_context_from_mix()

    children =
      mod_children() ++
        [
          {Task, fn -> Lunity.Editor.View.run() end},
          Lunity.Editor.FileWatcher
        ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp mod_children do
    if Application.get_env(:lunity, :mods_enabled, false) do
      [Lunity.Mod.EventBus]
    else
      []
    end
  end

  @doc false
  def load_mods do
    if Application.get_env(:lunity, :mods_enabled, false) do
      case Lunity.Mod.Loader.load_all() do
        {:ok, _data} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to load mods: #{inspect(reason)}")
          :error
      end
    else
      :ok
    end
  end

  defp init_project_context_from_mix do
    case {Application.get_env(:lunity, :project_priv), Application.get_env(:lunity, :project_app)} do
      {priv, app} when is_binary(priv) and app ->
        cwd = Path.dirname(priv)
        Lunity.Editor.State.put_project_context(cwd, app)

      _ ->
        :ok
    end
  end
end
