defmodule Lunity.Manager do
  @moduledoc """
  Behaviour for the game's manager.

  The game defines a module that `use`s `Lunity.Manager` and provides
  `components/0` and `systems/0` callbacks. The manager is a configuration
  registry -- each Instance reads its component list, system list, and
  tick rate from the manager, and owns its own ComponentStore and tick loop.

  ## Example

      defmodule Pong.Manager do
        use Lunity.Manager

        def components do
          [
            Pong.Components.Position,
            Pong.Components.Velocity,
          ]
        end

        def systems do
          [
            Pong.Systems.MoveBall,
          ]
        end

        def setup do
          Lunity.Instance.start(Pong.Scenes.Pong)
        end
      end

  ## Callbacks

  - `components/0` -- list of component modules to register (required)
  - `systems/0` -- list of system modules to run each tick, in order (required)
  - `setup/0` -- called once on first start (optional)
  - `tick_rate/0` -- ticks per second, default 20 (optional)
  """

  @callback components() :: [module()]
  @callback systems() :: [module()]
  @callback setup() :: :ok
  @callback tick_rate() :: pos_integer()

  @optional_callbacks [setup: 0, tick_rate: 0]

  defmacro __using__(_opts) do
    quote do
      @behaviour Lunity.Manager
      use GenServer

      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @doc false
      def __lunity_manager__, do: true

      @impl true
      def init(_opts) do
        if function_exported?(__MODULE__, :setup, 0) do
          apply(__MODULE__, :setup, [])
        end

        {:ok, %{}}
      end
    end
  end
end
