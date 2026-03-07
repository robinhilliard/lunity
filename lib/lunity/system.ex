defmodule Lunity.System do
  @moduledoc """
  Behaviour for Lunity ECS systems.

  Systems process component data each tick. Two types:

  ## Tensor systems

  Operate on entire tensors at once via `Nx.Defn`. The framework reads
  the declared tensors, passes them as a map to `run/1`, and writes
  the returned tensors back.

      defmodule MyGame.Systems.MoveBall do
        use Lunity.System,
          type: :tensor,
          reads: [MyGame.Components.Position, MyGame.Components.Velocity],
          writes: [MyGame.Components.Position]

        import Nx.Defn

        defn run(%{position: pos, velocity: vel}) do
          %{position: Nx.add(pos, vel)}
        end
      end

  ## Structured systems

  Operate on individual entities. The framework iterates entities that have
  the declared components and calls `run/2` for each.

      defmodule MyGame.Systems.DecayBuffs do
        use Lunity.System,
          type: :structured,
          reads: [MyGame.Components.ActiveBuffs],
          writes: [MyGame.Components.ActiveBuffs]

        def run(_entity_id, %{active_buffs: buffs}) do
          %{active_buffs: Enum.reject(buffs, &expired?/1)}
        end
      end
  """

  @callback __system_opts__() :: map()

  defmacro __using__(opts) do
    type = Keyword.get(opts, :type, :tensor)
    reads = Keyword.get(opts, :reads, [])
    writes = Keyword.get(opts, :writes, [])

    quote do
      @behaviour Lunity.System

      @lunity_system_opts %{
        type: unquote(type),
        reads: unquote(reads),
        writes: unquote(writes)
      }

      @impl Lunity.System
      def __system_opts__, do: @lunity_system_opts
    end
  end

  @doc """
  Converts a component module to its short key for use in system input/output maps.
  `MyGame.Components.Position` becomes `:position`.
  """
  def component_key(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end
end
