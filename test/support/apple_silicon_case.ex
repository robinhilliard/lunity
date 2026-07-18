defmodule Lunity.AppleSiliconCase do
  @moduledoc """
  ExUnit case template for tests that must run on Apple Silicon Metal (Emily/EMLX).

  Tagged `:apple_silicon` and excluded by default from `mix test`. Opt in with:

      mix test.apple_silicon              # only GPU cases
      mix test --include apple_silicon    # full suite + GPU cases

  Setup configures the MLX backend and restores `Nx.BinaryBackend` on exit so the
  rest of the suite stays deterministic.
  """

  use ExUnit.CaseTemplate

  alias Lunity.Nx.Backend

  using do
    quote do
      @moduletag :apple_silicon
    end
  end

  setup do
    unless apple_silicon?() do
      flunk("Apple Silicon GPU tests require macOS arm64 (got #{inspect(host_arch())})")
    end

    choice = Backend.configure!(backend: :auto)

    unless choice.name in [:emily, :emlx] do
      flunk("""
      expected Emily/EMLX on Apple Silicon, got #{choice.name} (#{choice.detail}).
      Ensure `emily` is in deps and compiled (`mix deps.get && mix compile`).
      """)
    end

    on_exit(fn ->
      Nx.global_default_backend(Nx.BinaryBackend)
      Nx.Defn.global_default_options([])
    end)

    {:ok, choice: choice}
  end

  defp apple_silicon? do
    match?({:unix, :darwin}, :os.type()) and
      :erlang.system_info(:system_architecture)
      |> List.to_string()
      |> String.contains?("aarch64")
  end

  defp host_arch do
    {:os.type(), List.to_string(:erlang.system_info(:system_architecture))}
  end
end
