defmodule Lunity.EntityFactory do
  @moduledoc """
  Create node-less ECSx entities from config.

  Config files return a list of component structs. EntityFactory creates an entity,
  adds each component, and returns the entity ID. Use for offscreen processes,
  AI, inventory, spawn queues.

  ## Config format (Option B)

  Config returns structs directly. EntityFactory adds each via the struct's module.

      # priv/config/spawns/enemy_type_a.exs
      alias MyGame.Components.{Movement, Health, AI}

      [
        %Movement{x: 0, y: 0, vx: 1, vy: 0},
        %Health{value: 100},
        %AI{type: :patrol}
      ]

  ## Overrides

  Overrides is a list of structs that replace or add to the config list.
  Structs are matched by module; override structs replace config structs of the same type.

      {:ok, entity_id} =
        Lunity.EntityFactory.create_from_config("spawns/enemy_type_a", [
          %Health{value: 80}
        ])

  ## ECSx

  Requires ECSx to be running. The game adds ECSx to its supervision tree.
  """

  alias Lunity.ConfigLoader

  @doc """
  Create an entity from a config file.

  Loads the config (expects a list of component structs), merges overrides,
  creates an entity, adds each component, and returns the entity ID.

  ## Options

  - `:app` - Application whose priv dir to use (default: current application)

  ## Returns

  - `{:ok, entity_id}` - Entity created with components
  - `{:error, reason}` - Load or path error

  ## Examples

      {:ok, entity_id} = Lunity.EntityFactory.create_from_config("spawns/enemy_type_a")
      {:ok, entity_id} = Lunity.EntityFactory.create_from_config("spawns/enemy_type_a", [%Health{value: 80}])
  """
  @spec create_from_config(String.t(), [struct()] | map(), keyword()) ::
          {:ok, term()} | {:error, term()}
  def create_from_config(path, overrides \\ [], opts \\ []) do
    with {:ok, component_list} <- load_component_list(path, opts),
         merged <- merge_overrides(component_list, overrides),
         entity_id <- generate_entity_id() do
      add_components(entity_id, merged)
      {:ok, entity_id}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp load_component_list(path, opts) do
    case ConfigLoader.load_config(path, opts) do
      {:ok, %{config: list}} when is_list(list) ->
        {:ok, list}

      {:ok, %{components: list}} when is_list(list) ->
        {:ok, list}

      {:ok, list} when is_list(list) ->
        {:ok, list}

      {:ok, other} ->
        {:error, {:invalid_config_format, "expected list of component structs, got: #{inspect(other)}"}}

      {:error, _} = err ->
        err
    end
  end

  defp merge_overrides(config_list, overrides) when is_list(overrides) do
    config_map = Map.new(config_list, fn s -> {s.__struct__, s} end)
    override_map = Map.new(overrides, fn s -> {s.__struct__, s} end)
    Map.merge(config_map, override_map) |> Map.values()
  end

  defp merge_overrides(config_list, overrides) when is_map(overrides) do
    # Map overrides: %{field_name: value} - apply to structs by matching field
    Enum.map(config_list, fn struct ->
      overrides
      |> Enum.filter(fn {k, _v} -> has_field?(struct, k) end)
      |> Enum.reduce(struct, fn {k, v}, acc -> put_field(acc, k, v) end)
    end)
  end

  defp merge_overrides(config_list, _), do: config_list

  defp has_field?(struct, k) when is_binary(k) do
    try do
      field = String.to_existing_atom(k)
      Map.has_key?(struct, field)
    rescue
      ArgumentError -> false
    end
  end

  defp has_field?(struct, k) when is_atom(k), do: Map.has_key?(struct, k)

  defp put_field(acc, k, v) when is_binary(k) do
    try do
      field = String.to_existing_atom(k)
      Map.put(acc, field, v)
    rescue
      ArgumentError -> acc
    end
  end

  defp put_field(acc, k, v) when is_atom(k), do: Map.put(acc, k, v)

  defp generate_entity_id do
    :erlang.unique_integer([:positive])
  end

  defp add_components(entity_id, component_structs) do
    Enum.each(component_structs, fn struct ->
      module = struct.__struct__
      module.add(entity_id, struct)
    end)
  end
end
