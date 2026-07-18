defmodule Lunity.Nx.Host do
  @moduledoc """
  Explicit host (CPU / Erlang-term) transfer helpers for ECS IO edges.

  Tensor systems and gather/scatter should keep data on the default Nx backend.
  Use this module when crossing into Lua mods, web JSON, MCP tools, or
  per-entity CRUD APIs.
  """

  @doc "Transfers a tensor to `Nx.BinaryBackend` for host inspection."
  @spec to_host(Nx.Tensor.t()) :: Nx.Tensor.t()
  def to_host(%Nx.Tensor{} = tensor) do
    Nx.backend_transfer(tensor, Nx.BinaryBackend)
  end

  @doc "Returns a flat Elixir list of tensor values (host sync)."
  @spec to_list(Nx.Tensor.t()) :: list()
  def to_list(%Nx.Tensor{} = tensor) do
    tensor |> to_host() |> Nx.to_flat_list()
  end

  @doc "Returns a scalar Elixir number (host sync)."
  @spec to_number(Nx.Tensor.t()) :: number()
  def to_number(%Nx.Tensor{} = tensor) do
    tensor |> to_host() |> Nx.to_number()
  end

  @doc """
  Creates a tensor on the current default backend from an Elixir value.

  Prefer this over bare `Nx.tensor/2` at IO edges so values land on the
  configured GPU/accelerator backend when one is active.
  """
  @spec from_host(term(), keyword()) :: Nx.Tensor.t()
  def from_host(value, opts \\ [])

  def from_host(%Nx.Tensor{} = tensor, opts) do
    backend = Keyword.get(opts, :backend, Nx.default_backend())
    Nx.backend_transfer(tensor, backend)
  end

  def from_host(value, opts) do
    opts
    |> Keyword.put_new(:backend, Nx.default_backend())
    |> then(&Nx.tensor(value, &1))
  end
end
