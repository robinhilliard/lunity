defmodule Lunity.Input.NativeTrackIR do
  @moduledoc """
  Polls TrackIR via the NPClient64.dll SDK and writes 6-DOF head pose
  data into the input session ETS table. Windows only.

  Start with a session_id and the EAGL window handle:

      Lunity.Input.NativeTrackIR.start_link(
        session_id: "player_1",
        hwnd: :wxWindow.getHandle(gl_canvas)
      )

  Options:
  - `:session_id` (required)
  - `:hwnd` (required) -- native window handle from `:wxWindow.getHandle/1`
  - `:dll_path` -- directory containing NPClient64.dll (auto-detected from registry if omitted)
  - `:developer_id` -- TrackIR profile ID (default 1001)
  - `:poll_interval_ms` -- polling interval in ms (default 16, ~60 Hz)
  """

  use GenServer

  alias Lunity.Input.{Session, HeadPose}

  @poll_interval_ms 16
  @developer_id 1001

  @spec start_link(keyword()) :: GenServer.on_start() | {:error, :not_supported}
  def start_link(opts) do
    case :os.type() do
      {:win32, :nt} -> GenServer.start_link(__MODULE__, opts)
      _ -> {:error, :not_supported}
    end
  end

  @impl true
  def init(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    hwnd = Keyword.fetch!(opts, :hwnd)
    dll_path = Keyword.get(opts, :dll_path, "")
    developer_id = Keyword.get(opts, :developer_id, @developer_id)
    poll_interval = Keyword.get(opts, :poll_interval_ms, @poll_interval_ms)

    case __MODULE__.Nif.init(dll_path, hwnd, developer_id) do
      {:ok, resource} ->
        schedule_poll(poll_interval)

        {:ok,
         %{
           resource: resource,
           session_id: session_id,
           interval: poll_interval,
           last_frame: 0
         }}

      {:error, reason} ->
        {:stop, {:trackir_init_failed, reason}}
    end
  end

  @impl true
  def handle_info(:poll, state) do
    case __MODULE__.Nif.poll(state.resource) do
      {:ok, %HeadPose{frame: frame} = hp} when frame != state.last_frame ->
        Session.update_head_pose(state.session_id, hp)
        schedule_poll(state.interval)
        {:noreply, %{state | last_frame: frame}}

      _ ->
        schedule_poll(state.interval)
        {:noreply, state}
    end
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defmodule Nif do
    @moduledoc false
    @on_windows :os.type() == {:win32, :nt}

    if @on_windows do
      use Rustler, otp_app: :lunity, crate: "lunity_trackir"
    else
      use Rustler, otp_app: :lunity, crate: "lunity_trackir", skip_compilation?: true
    end

    @spec init(String.t(), non_neg_integer(), non_neg_integer()) ::
            {:ok, reference()} | {:error, String.t()}
    def init(_dll_path, _hwnd, _developer_id), do: :erlang.nif_error(:nif_not_loaded)

    @spec poll(reference()) :: {:ok, Lunity.Input.HeadPose.t()} | {:error, String.t()}
    def poll(_resource), do: :erlang.nif_error(:nif_not_loaded)
  end
end
