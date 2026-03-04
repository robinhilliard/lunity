defmodule Lunity.ConfigLoader do
  @moduledoc """
  Load code-behind config files and merge with node properties.

  Config files (`.exs`) live under `priv/config/` and support general Elixir code.
  At load time, config (from file) and properties (from glTF extras / `node.properties`)
  are merged: config is the base, properties override. Nil values in properties are
  ignored (do not override config).

  ## Convention

  - `node.properties["behaviour"]` = module name (e.g. `"MyGame.Behaviours.Door"`)
  - `node.properties["config"]` = path relative to `priv/config/` (e.g. `"scenes/doors/level1_door"`)
  - Matching file: `priv/config/scenes/doors/level1_door.exs` returns a keyword list or map

  ## Scope (Phase 3)

  ConfigLoader + merge only. No scene-loading integration; that comes in Phase 5.

  ## Examples

      # Load config from priv/config/scenes/doors/level1_door.exs
      {:ok, config} = Lunity.ConfigLoader.load_config("scenes/doors/level1_door")

      # Merge with node properties (extras override config)
      merged = Lunity.ConfigLoader.merge_config(config, %{"open_angle" => 90})

      # Load from another app (e.g. when Lunity is a dependency)
      {:ok, config} = Lunity.ConfigLoader.load_config("prefabs/crate", app: :my_game)
  """

  @doc """
  Load a config file from `priv/config/<path>.exs`.

  ## Options

  - `:app` - Application whose priv dir to use (default: current application from Mix)

  ## Path resolution

  - Path is relative to `priv_dir(app)/config/`
  - `.exs` suffix is added if not present
  - Paths containing `..` are rejected (path traversal)

  ## Returns

  - `{:ok, config}` - Config as a map (keyword lists are normalized to maps)
  - `{:error, :path_traversal}` - Path contained `..` or escaped config dir
  - `{:error, :file_not_found}` - File does not exist
  - `{:error, {:eval_error, reason}}` - File failed to evaluate

  ## Examples

      iex> Lunity.ConfigLoader.load_config("scenes/doors/level1_door")
      {:ok, %{health: 100, open_angle: 90, key_id: "default_key"}}

      iex> Lunity.ConfigLoader.load_config("nonexistent")
      {:error, :file_not_found}
  """
  @spec load_config(String.t(), keyword()) ::
          {:ok, map()} | {:error, :path_traversal | :file_not_found | {:eval_error, term()}}
  def load_config(path, opts \\ []) do
    app = Keyword.get(opts, :app, current_app())
    config_dir = config_dir_for_app(app)
    full_path = Path.join(config_dir, ensure_exs_suffix(path))

    with :ok <- validate_path(path),
         :ok <- ensure_under_config_dir(full_path, config_dir),
         {:ok, config} <- eval_config_file(full_path) do
      {:ok, to_map(config)}
    end
  end

  @doc """
  Merge config (from .exs file) with properties (from node.properties / glTF extras).

  Config is the base; properties override. Nil values in properties are ignored
  (do not override config). Both inputs are normalized to atom keys before merging.

  ## Examples

      iex> config = %{health: 100, open_angle: 90}
      iex> properties = %{"open_angle" => 45, "key_id" => "gold_key"}
      iex> Lunity.ConfigLoader.merge_config(config, properties)
      %{health: 100, open_angle: 45, key_id: "gold_key"}

      iex> config = %{health: 100}
      iex> properties = %{"health" => nil}
      iex> Lunity.ConfigLoader.merge_config(config, properties)
      %{health: 100}
  """
  @spec merge_config(map() | keyword(), map() | nil) :: map()
  def merge_config(config, nil), do: to_map(config)

  def merge_config(config, properties) when is_map(properties) do
    config_map = to_map(config)
    # Filter nil values from properties; they do not override config
    overrides =
      properties
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Enum.map(fn {k, v} -> {normalize_key(k), v} end)
      |> Map.new()

    Map.merge(config_map, overrides)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp current_app do
    Lunity.project_app()
  end

  defp config_dir_for_app(app) do
    Path.join(Lunity.priv_dir_for_app(app), "config")
  end

  defp ensure_exs_suffix(path) do
    if String.ends_with?(path, ".exs"), do: path, else: path <> ".exs"
  end

  defp validate_path(path) do
    cond do
      not is_binary(path) -> {:error, :path_traversal}
      String.contains?(path, "..") -> {:error, :path_traversal}
      String.starts_with?(path, "/") -> {:error, :path_traversal}
      true -> :ok
    end
  end

  defp ensure_under_config_dir(full_path, config_dir) do
    expanded = Path.expand(full_path)
    config_expanded = Path.expand(config_dir)

    if String.starts_with?(expanded, config_expanded) do
      :ok
    else
      {:error, :path_traversal}
    end
  end

  defp eval_config_file(path) do
    if File.exists?(path) do
      try do
        {result, _binding} = Code.eval_file(path)
        {:ok, result}
      rescue
        e -> {:error, {:eval_error, e}}
      catch
        kind, reason -> {:error, {:eval_error, {kind, reason}}}
      end
    else
      {:error, :file_not_found}
    end
  end

  defp to_map(nil), do: %{}
  defp to_map([]), do: %{}

  defp to_map([{k, _} | _] = list) when is_list(list) and (is_atom(k) or is_binary(k)),
    do: Map.new(list)

  defp to_map(map) when is_map(map), do: map
  defp to_map(other), do: %{config: other}

  defp normalize_key(k) when is_atom(k), do: k

  defp normalize_key(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> String.to_atom(k)
    end
  end
end
