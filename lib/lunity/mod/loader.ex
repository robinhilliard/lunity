defmodule Lunity.Mod.Loader do
  @moduledoc """
  Orchestrates the full mod loading pipeline.

  1. Discover mods in `priv/mods/`
  2. Topological sort by dependencies
  3. Run the data stage (shared Lua state for scene/prefab/entity definitions)
  4. Store materialized data for SceneLoader/PrefabLoader to consume
  5. Start the EventBus
  6. Run the runtime stage (per-mod Lua states with event handlers)
  7. Dispatch `on_init` to all mods
  """

  require Logger

  alias Lunity.Mod
  alias Lunity.Mod.{DataStage, RuntimeStage, EventBus}

  @doc """
  Load all mods for the given app.

  Stores results in `Lunity.Mod.Registry` (ETS) for consumption by
  SceneLoader and PrefabLoader.
  """
  @spec load_all(atom()) :: {:ok, map()} | {:error, term()}
  def load_all(app \\ Lunity.project_app()) do
    mods_dir = Mod.mods_dir(app)

    with {:ok, mods} <- Mod.discover_and_sort(mods_dir),
         _ =
           Logger.info(
             "Lunity.Mod: loaded #{length(mods)} mod(s): #{Enum.map_join(mods, ", ", & &1.name)}"
           ),
         {:ok, data} <- DataStage.run(mods),
         _ = store_data(data, mods),
         :ok <- RuntimeStage.run(mods),
         _ = EventBus.dispatch("on_init") do
      {:ok, data}
    end
  end

  @doc """
  Get the mod data (scenes, prefabs, entities) from the registry.
  """
  @spec get_data() :: map() | nil
  def get_data do
    case :ets.lookup(:lunity_mod_registry, :data) do
      [{:data, data}] -> data
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Get the sorted mod list from the registry.
  """
  @spec get_mods() :: [Mod.mod_info()] | nil
  def get_mods do
    case :ets.lookup(:lunity_mod_registry, :mods) do
      [{:mods, mods}] -> mods
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc """
  Get a specific scene definition from mod data.
  """
  @spec get_scene(String.t()) :: Lunity.Scene.Def.t() | nil
  def get_scene(name) do
    case get_data() do
      %{scenes: scenes} -> Map.get(scenes, name)
      _ -> nil
    end
  end

  @doc """
  Get a specific prefab definition from mod data.
  """
  @spec get_prefab(String.t()) :: map() | nil
  def get_prefab(name) do
    case get_data() do
      %{prefabs: prefabs} -> Map.get(prefabs, name)
      _ -> nil
    end
  end

  @doc """
  Resolve a prefab GLB path, looking in the defining mod's assets directory.
  """
  @spec resolve_prefab_glb(String.t()) :: String.t() | nil
  def resolve_prefab_glb(prefab_name) do
    case get_prefab(prefab_name) do
      %{glb: glb, source_mod: mod_name} when is_binary(glb) and is_binary(mod_name) ->
        case find_mod_dir(mod_name) do
          nil -> nil
          mod_dir -> Path.join([mod_dir, "assets", "prefabs", "#{glb}.glb"])
        end

      %{glb: glb} when is_binary(glb) ->
        find_glb_in_mods(glb)

      _ ->
        nil
    end
  end

  @doc """
  Initialize the mod registry ETS table.
  """
  @spec init_registry() :: :ok
  def init_registry do
    if :ets.info(:lunity_mod_registry) == :undefined do
      :ets.new(:lunity_mod_registry, [:named_table, :public, :set])
    end

    :ok
  end

  # -- Private ----------------------------------------------------------------

  defp store_data(data, mods) do
    init_registry()
    :ets.insert(:lunity_mod_registry, {:data, data})
    :ets.insert(:lunity_mod_registry, {:mods, mods})
  end

  defp find_mod_dir(mod_name) do
    case get_mods() do
      mods when is_list(mods) ->
        case Enum.find(mods, &(&1.name == mod_name)) do
          %{dir: dir} -> dir
          nil -> nil
        end

      _ ->
        nil
    end
  end

  defp find_glb_in_mods(glb_id) do
    case get_mods() do
      mods when is_list(mods) ->
        Enum.find_value(mods, fn mod ->
          path = Path.join([mod.dir, "assets", "prefabs", "#{glb_id}.glb"])
          if File.exists?(path), do: path
        end)

      _ ->
        nil
    end
  end
end
