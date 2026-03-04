defmodule Lunity do
  @moduledoc """
  Documentation for `Lunity`.
  """

  @doc """
  Returns the current project app (e.g. :pong). Uses set_project context (ETS),
  Process dict (MCP request), or Application config (stdio).
  """
  def project_app do
    case Lunity.Editor.State.get_project_context() do
      {_, app} when not is_nil(app) -> app
      _ ->
        Process.get(:lunity_project_app) ||
          Application.get_env(:lunity, :project_app) ||
          (case Mix.Project.get() do
            nil -> :lunity
            project -> project.project()[:app]
          end)
    end
  end

  @doc """
  Returns the priv directory for an application. Falls back to project priv when
  the app is not yet loaded (e.g. editor runs before host app finishes starting).
  """
  def priv_dir_for_app(app) do
    Application.app_dir(app, "priv")
  rescue
    ArgumentError -> project_priv_dir(app)
  end

  defp project_priv_dir(app) do
    # set_project stores in ETS (shared); Process is per-MCP-request
    cwd =
      case Lunity.Editor.State.get_project_context() do
        {c, _} -> c
        nil -> Process.get(:lunity_project_cwd)
      end

    if cwd do
      Path.join(cwd, "priv")
    else
      # Stdio: path stored by MCP task (set before apps start)
      case Application.get_env(:lunity, :project_priv) do
        path when is_binary(path) -> path
        _ -> project_priv_from_mix(app)
      end
    end
  end

  defp project_priv_from_mix(app) do
    case Mix.Project.get() do
      nil ->
        raise "Cannot resolve priv dir for #{inspect(app)}: app not loaded, no Mix project, and no :project_priv in config"

      project ->
        if project.project()[:app] == app do
          app_path = project.app_path()
          project_root = Path.dirname(Path.dirname(app_path))
          Path.join(project_root, "priv")
        else
          raise "Cannot resolve priv dir for #{inspect(app)}: app not loaded and Mix project is #{inspect(project.project()[:app])}"
        end
    end
  end
end
