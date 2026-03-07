defmodule Lunity.TickRunner do
  @moduledoc """
  Executes systems each tick.

  For tensor systems: reads declared component tensors into a map, calls the
  system's `run/1` defn, writes returned tensors back to the ComponentStore.

  For structured systems: finds entities with the declared components, calls
  the system's `run/2` for each entity, writes returned values back.
  """

  alias Lunity.{ComponentStore, System}

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
  end

  defp run_tensor_system(system_module, opts) do
    inputs =
      Map.new(opts.reads, fn component ->
        key = System.component_key(component)
        {key, ComponentStore.get_tensor(component)}
      end)

    outputs = system_module.run(inputs)

    for component <- opts.writes do
      key = System.component_key(component)

      case Map.get(outputs, key) do
        nil -> :ok
        tensor -> ComponentStore.put_tensor(component, tensor)
      end
    end

    :ok
  end

  defp run_structured_system(system_module, opts) do
    [primary | _rest] = opts.reads

    for {entity_id, _val} <- ComponentStore.all(primary) do
      inputs =
        Map.new(opts.reads, fn component ->
          key = System.component_key(component)
          {key, ComponentStore.get(component, entity_id)}
        end)

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

    :ok
  end
end
