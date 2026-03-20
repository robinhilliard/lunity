# Quick test: 1 second sawtooth PCM streamed via PortAudio callback API (Rustler NIF)
# Run with: mix run scripts/sawtooth_test.exs
#
# Uses Lunity.Audio.Native which binds to PortAudio's callback API for macOS compatibility.

sample_rate = 48_000
channels = 2  # stereo
duration_sec = 0.02
freq = 440  # A4
num_frames = trunc(sample_rate * duration_sec)

# Generate sawtooth: ramp from -32768 to 32767, repeat at freq
# Duplicate each sample for stereo (L, R, L, R, ...)
samples =
  for i <- 0..(num_frames - 1) do
    phase = i / sample_rate * freq
    ramp = phase - :math.floor(phase)
    s = round(ramp * 65_535 - 32_768)
    for _ <- 1..channels, do: s
  end
  |> List.flatten()

num_samples = length(samples)

# Pack as little-endian 16-bit PCM
pcm = for s <- samples, into: <<>>, do: <<s::signed-16-little>>

IO.puts("Generated #{num_samples} samples (#{byte_size(pcm)} bytes), #{freq} Hz sawtooth")

# Open stream (starts immediately), write PCM, stop, close
{:ok, handle} = Lunity.Audio.Native.Nif.stream_open(sample_rate * 1.0, channels, 2048)

# Stream PCM in chunks (frame size = 4 bytes for stereo int16)
chunk_bytes = 4096
Stream.unfold(0, fn
  offset when offset >= byte_size(pcm) -> nil
  offset ->
    len = min(chunk_bytes, byte_size(pcm) - offset)
    chunk = binary_part(pcm, offset, len)
    Lunity.Audio.Native.Nif.stream_write(handle, chunk)
    {chunk, offset + len}
end)
|> Stream.run()

# Wait for playback to finish (~1 sec of audio + buffer latency)
Process.sleep(1500)

# Stop and close (return {:ok, _} on success)
{:ok, _} = Lunity.Audio.Native.Nif.stream_stop(handle)
{:ok, _} = Lunity.Audio.Native.Nif.stream_close(handle)

IO.puts("Done.")
