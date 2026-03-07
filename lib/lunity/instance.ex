defmodule Lunity.Instance do
  @moduledoc """
  A running game instance.

  Each instance has a unique ID, loads a scene, and manages the entities
  created for that scene. Entity IDs are scoped to the instance:
  `{instance_id, :ball}` is a different entity from `{other_instance, :ball}`.

  Instances track metadata -- the scene module and entity list -- but do NOT
  manage ECS state directly. Component data lives in the global ComponentStore
  tensors, indexed by entity.

  When an instance stops, all its entities are deallocated and their component
  values zeroed.
  """

  use GenServer

  defstruct [:id, :scene_module, :entity_ids, :status]

  # -- Public API ----------------------------------------------------------------

  @doc """
  Starts a new game instance for the given scene module.

  Options:
  - `:id` - instance ID (default: auto-generated)
  - `:shader_program` - OpenGL shader for scene loading
  """
  def start(scene_module, opts \\ []) do
    id = Keyword.get(opts, :id, generate_id())

    DynamicSupervisor.start_child(
      Lunity.Instance.Supervisor,
      {__MODULE__, Keyword.merge(opts, id: id, scene_module: scene_module)}
    )
  end

  @doc "Stops a game instance and cleans up its entities."
  def stop(instance_id) do
    case Registry.lookup(Lunity.Instance.Registry, instance_id) do
      [{pid, _}] -> GenServer.stop(pid)
      [] -> {:error, :not_found}
    end
  end

  @doc "Lists all active instance IDs."
  def list do
    Registry.select(Lunity.Instance.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @doc "Gets instance metadata."
  def get(instance_id) do
    case Registry.lookup(Lunity.Instance.Registry, instance_id) do
      [{pid, _}] -> GenServer.call(pid, :get)
      [] -> nil
    end
  end

  # -- GenServer callbacks -------------------------------------------------------

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: via(id))
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)
    scene_module = Keyword.fetch!(opts, :scene_module)

    entity_ids = init_scene_entities(id, scene_module, opts)

    {:ok,
     %__MODULE__{
       id: id,
       scene_module: scene_module,
       entity_ids: entity_ids,
       status: :running
     }}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def terminate(_reason, state) do
    for entity_id <- state.entity_ids do
      Lunity.ComponentStore.deallocate(entity_id)
    end

    :ok
  end

  def child_spec(opts) do
    id = Keyword.fetch!(opts, :id)

    %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  # -- Private -------------------------------------------------------------------

  defp via(id), do: {:via, Registry, {Lunity.Instance.Registry, id}}

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end

  defp init_scene_entities(instance_id, scene_module, _opts) do
    case Code.ensure_loaded(scene_module) do
      {:module, _} ->
        if function_exported?(scene_module, :__scene_def__, 0) do
          scene_def = scene_module.__scene_def__()
          init_entities_from_def(instance_id, scene_def)
        else
          []
        end

      _ ->
        []
    end
  end

  defp init_entities_from_def(instance_id, %Lunity.Scene.Def{nodes: nodes}) do
    Enum.flat_map(nodes, fn node_def ->
      init_entity_from_node(instance_id, node_def)
    end)
  end

  defp init_entity_from_node(instance_id, %Lunity.Scene.NodeDef{} = node_def) do
    entity_ids =
      if node_def.entity do
        entity_id = {instance_id, node_def.name}
        _index = Lunity.ComponentStore.allocate(entity_id)

        Lunity.ComponentStore.put(
          Lunity.Components.InstanceMembership,
          entity_id,
          instance_id
        )

        config = build_entity_config(node_def)

        try do
          node_def.entity.init(config, entity_id)
        rescue
          _ -> :ok
        end

        [entity_id]
      else
        []
      end

    child_ids =
      Enum.flat_map(node_def.children || [], fn child ->
        init_entity_from_node(instance_id, child)
      end)

    entity_ids ++ child_ids
  end

  defp build_entity_config(%Lunity.Scene.NodeDef{} = node_def) do
    base = node_def.properties || %{}

    base =
      if node_def.position do
        Map.put(base, :position, node_def.position)
      else
        base
      end

    base =
      if node_def.scale do
        Map.put(base, :scale, node_def.scale)
      else
        base
      end

    if node_def.entity && function_exported?(node_def.entity, :__property_spec__, 0) do
      try do
        Lunity.Entity.from_config(node_def.entity, base)
      rescue
        _ -> base
      end
    else
      base
    end
  end
end
