defmodule Lunity.Input.SessionManager do
  @moduledoc """
  Owns the shared `:lunity_input` ETS table for the lifetime of the
  application. Started once in the supervision tree.

  All actual reads and writes happen directly via `Lunity.Input.Session`
  functions -- this GenServer exists only for table lifecycle ownership.
  """

  use GenServer

  @table :lunity_input

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc false
  @spec table_name() :: atom()
  def table_name, do: @table

  @impl true
  def init(_opts) do
    :ets.new(@table, [:public, :set, :named_table])
    {:ok, %{}}
  end
end
