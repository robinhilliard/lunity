defmodule Lunity.TickRunner do
  @moduledoc """
  Executes systems each tick.

  For tensor systems: reads declared component tensors into a map, calls the
  system's `run/1` defn, writes returned tensors back to the ComponentStore.

  For structured systems: finds entities with the declared components, calls
  the system's `run/2` for each entity, writes returned values back.
  """

  alias Lunity.{ComponentStore, System}
  alias Lunity.ComponentStore.Gather

  @doc "Runs all systems in order."
  def tick(systems) do
    Enum.each(systems, &run_system/1)
  end

  defp run_system(system_module) do
    opts = system_module.__system_opts__()

    case opts.type do
      :tensor -> run_tensor_system(system_module, opts)
      :structured -> run_structured_system(system_module, opts)
    end
  rescue
    UndefinedFunctionError ->
      :ok
  end

  defp run_tensor_system(system_module, opts) do
    inputs =
      Map.new(opts.reads, fn component ->
        key = System.component_key(component)
        {key, ComponentStore.get_tensor(component)}
      end)

    entity_names = Map.get(opts, :entities, [])
    inputs = resolve_entity_indices(inputs, entity_names)

    filter = Map.get(opts, :filter)

    if filter do
      run_filtered_tensor_system(system_module, opts, inputs, filter)
    else
      run_full_tensor_system(system_module, opts, inputs)
    end
  end

  defp run_full_tensor_system(system_module, opts, inputs) do
    outputs = system_module.run(inputs)
    write_outputs(opts, outputs)
  end

  defp run_filtered_tensor_system(system_module, opts, inputs, filter) do
    indices = Gather.active_indices(filter)

    if indices == [] do
      :ok
    else
      compact_inputs = Gather.gather(inputs, indices)
      compact_outputs = system_module.run(compact_inputs)
      full_outputs = Gather.scatter(inputs, compact_outputs, indices)
      write_outputs(opts, full_outputs)
    end
  end

  defp write_outputs(opts, outputs) do
    for component <- opts.writes do
      key = System.component_key(component)

      case Map.get(outputs, key) do
        nil -> :ok
        tensor -> ComponentStore.put_tensor(component, tensor)
      end
    end

    :ok
  end

  defp resolve_entity_indices(inputs, []), do: inputs

  defp resolve_entity_indices(inputs, entity_names) do
    indices =
      Map.new(entity_names, fn name ->
        key = :"#{name}_idx"
        idx = ComponentStore.index_of(name) || -1
        {key, Nx.tensor(idx, type: :s32)}
      end)

    Map.merge(inputs, indices)
  end

  defp run_structured_system(system_module, opts) do
    [primary | _rest] = opts.reads

    entity_ids = entity_ids_for(primary)

    for entity_id <- entity_ids do
      inputs =
        Map.new(opts.reads, fn component ->
          key = System.component_key(component)
          {key, ComponentStore.get(component, entity_id)}
        end)

      if Enum.all?(Map.values(inputs), &(&1 != nil)) do
        case system_module.run(entity_id, inputs) do
          updates when is_map(updates) ->
            for component <- opts.writes do
              key = System.component_key(component)

              case Map.get(updates, key) do
                nil -> :ok
                value -> ComponentStore.put(component, entity_id, value)
              end
            end

          _ ->
            :ok
        end
      end
    end

    :ok
  end

  defp entity_ids_for(component) do
    opts = component.__component_opts__()

    case opts.storage do
      :structured ->
        ComponentStore.all(component) |> Enum.map(fn {id, _} -> id end)

      :tensor ->
        ComponentStore.entity_ids_with(component)
    end
  end
end
