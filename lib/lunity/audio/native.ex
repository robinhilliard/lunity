defmodule Lunity.Audio.Native do
  @moduledoc """
  PortAudio callback-based audio output via Rustler NIF.
  Uses the callback API (not blocking) for macOS compatibility.
  """

  defmodule Nif do
    @moduledoc false
    use Rustler, otp_app: :lunity, crate: "lunity_audio"

    @spec stream_open(
            sample_rate :: float(),
            channels :: integer(),
            frames_per_buffer :: integer()
          ) ::
            {:ok, reference()} | {:error, String.t()}
    def stream_open(_sample_rate, _channels, _frames_per_buffer),
      do: :erlang.nif_error(:nif_not_loaded)

    @spec stream_write(resource :: reference(), data :: binary()) :: :ok | {:error, String.t()}
    def stream_write(_resource, _data), do: :erlang.nif_error(:nif_not_loaded)

    @spec stream_stop(resource :: reference()) :: {:ok, term()} | {:error, String.t()}
    def stream_stop(_resource), do: :erlang.nif_error(:nif_not_loaded)

    @spec stream_close(resource :: reference()) :: {:ok, term()} | {:error, String.t()}
    def stream_close(_resource), do: :erlang.nif_error(:nif_not_loaded)
  end
end
