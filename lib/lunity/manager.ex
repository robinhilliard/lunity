defmodule Lunity.Manager do
  @moduledoc """
  Behaviour for the game's tick manager.

  The game defines a module that `use`s `Lunity.Manager` and provides
  `components/0` and `systems/0` callbacks. The manager starts the
  ComponentStore, registers components, and runs the tick loop.

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

      @impl true
      def init(opts) do
        {:ok, _} = Lunity.ComponentStore.start_link(opts)

        Enum.each(components(), &Lunity.ComponentStore.register/1)

        if function_exported?(__MODULE__, :setup, 0) do
          apply(__MODULE__, :setup, [])
        end

        rate =
          if function_exported?(__MODULE__, :tick_rate, 0),
            do: apply(__MODULE__, :tick_rate, []),
            else: 20

        interval = div(1000, rate)
        :timer.send_interval(interval, :tick)

        {:ok, %{systems: systems(), interval: interval}}
      end

      @impl true
      def handle_info(:tick, state) do
        Lunity.TickRunner.tick(state.systems)
        {:noreply, state}
      end
    end
  end
end
