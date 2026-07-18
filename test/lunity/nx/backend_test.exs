defmodule Lunity.Nx.BackendTest do
  use ExUnit.Case, async: false

  alias Lunity.Nx.Backend

  setup do
    # Restore BinaryBackend after each test so the rest of the suite stays deterministic.
    on_exit(fn ->
      Nx.global_default_backend(Nx.BinaryBackend)
    end)

    :ok
  end

  test "select(:binary) returns BinaryBackend" do
    choice = Backend.select(backend: :binary)
    assert choice.name == :binary
    assert choice.backend == Nx.BinaryBackend
  end

  test "configure! with :binary applies BinaryBackend" do
    choice = Backend.configure!(backend: :binary)
    assert choice.name == :binary

    case Nx.default_backend() do
      Nx.BinaryBackend -> :ok
      {Nx.BinaryBackend, _} -> :ok
      other -> flunk("expected BinaryBackend, got #{inspect(other)}")
    end
  end

  test "select(:auto) returns a known backend name" do
    choice = Backend.select(backend: :auto)
    assert choice.name in [:emily, :emlx, :exla, :binary]
    assert is_binary(choice.detail)
  end

  test "unknown backend falls back to auto" do
    choice = Backend.select(backend: :not_a_real_backend)
    assert choice.name in [:emily, :emlx, :exla, :binary]
  end
end
