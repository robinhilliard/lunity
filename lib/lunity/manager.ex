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

        all_components = [Lunity.Components.DeltaTime | components()]
        Enum.each(all_components, &Lunity.ComponentStore.register/1)

        if function_exported?(__MODULE__, :setup, 0) do
          apply(__MODULE__, :setup, [])
        end

        rate =
          if function_exported?(__MODULE__, :tick_rate, 0),
            do: apply(__MODULE__, :tick_rate, []),
            else: 20

        interval = div(1000, rate)
        :timer.send_interval(interval, :tick)

        {:ok, %{systems: systems(), interval: interval, last_tick: System.monotonic_time(:millisecond)}}
      end

      @impl true
      def handle_info(:tick, state) do
        now = System.monotonic_time(:millisecond)
        dt_ms = now - state.last_tick
        dt_s = dt_ms / 1000.0

        dt_tensor = Lunity.ComponentStore.get_tensor(Lunity.Components.DeltaTime)
        Lunity.ComponentStore.put_tensor(
          Lunity.Components.DeltaTime,
          Nx.broadcast(Nx.tensor(dt_s, type: :f32), Nx.shape(dt_tensor))
        )

        cond do
          not Lunity.Editor.State.get_game_paused() ->
            Lunity.TickRunner.tick(state.systems)

          Lunity.Editor.State.take_step_request() ->
            Lunity.TickRunner.tick(state.systems)

          true ->
            :ok
        end

        {:noreply, %{state | last_tick: now}}
      end
    end
  end
end
