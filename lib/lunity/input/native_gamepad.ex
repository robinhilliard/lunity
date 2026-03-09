defmodule Lunity.Input.NativeGamepad do
  @moduledoc """
  Polls connected gamepads via the gilrs Rustler NIF and writes
  their state into the input session ETS table.

  Start with a session_id to associate gamepad data with a session:

      Lunity.Input.NativeGamepad.start_link(session_id: "player_1")
  """

  use GenServer

  alias Lunity.Input.{Session, Gamepad}

  @poll_interval_ms 16

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    poll_interval = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)

    case __MODULE__.Nif.new() do
      {:ok, resource} ->
        schedule_poll(poll_interval)
        {:ok, %{resource: resource, session_id: session_id, interval: poll_interval}}

      {:error, reason} ->
        {:stop, {:gilrs_init_failed, reason}}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    gamepads = __MODULE__.Nif.poll(state.resource)

    Enum.each(gamepads, fn %Gamepad{index: index} = gp ->
      Session.update_gamepad(state.session_id, index, gp)
    end)

    schedule_poll(state.interval)
    {:noreply, state}
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defmodule Nif do
    @moduledoc false
    use Rustler, otp_app: :lunity, crate: "lunity_gamepad"

    @spec new() :: {:ok, reference()} | {:error, String.t()}
    def new, do: :erlang.nif_error(:nif_not_loaded)

    @spec poll(reference()) :: [Gamepad.t()]
    def poll(_resource), do: :erlang.nif_error(:nif_not_loaded)
  end
end
