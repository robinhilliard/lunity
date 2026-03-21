defmodule Lunity.Web.ConnectionReaper do
  @moduledoc """
  Tracks SSE connections and reaps stale ones.

  ExMCP's SSE handler blocks a Bandit process for the lifetime of each SSE
  connection.  When clients disconnect without a clean TCP FIN (crash, sleep,
  network drop), the server-side process can live indefinitely because
  `Plug.Conn.chunk` keeps "succeeding" into the kernel send buffer until TCP
  keepalive eventually notices (default 2 hours on macOS).

  This GenServer:
  - Maintains a registry of active SSE connection processes
  - Monitors each for normal exit (automatic cleanup)
  - Runs a periodic sweep to kill connections older than `@max_age_ms`
  - Exposes `count/0` and `info/0` for diagnostics
  """

  use GenServer
  require Logger

  @ets_table :lunity_sse_connections
  @sweep_interval_ms :timer.minutes(1)
  @max_age_ms :timer.hours(24)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Register the calling process as an SSE connection."
  def track(pid \\ self()) do
    GenServer.cast(__MODULE__, {:track, pid})
  end

  @doc "Number of currently tracked SSE connections."
  def count do
    try do
      :ets.info(@ets_table, :size) || 0
    rescue
      _ -> 0
    end
  end

  @doc "List of {pid, started_monotonic_ms, age_seconds} for all tracked connections."
  def info do
    now = System.monotonic_time(:millisecond)

    try do
      :ets.tab2list(@ets_table)
      |> Enum.map(fn {pid, started, _ref} ->
        %{pid: inspect(pid), alive: Process.alive?(pid), age_s: div(now - started, 1000)}
      end)
    rescue
      _ -> []
    end
  end

  # GenServer callbacks

  @impl true
  def init(_opts) do
    :ets.new(@ets_table, [:named_table, :public, :set])
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:track, pid}, state) do
    ref = Process.monitor(pid)
    :ets.insert(@ets_table, {pid, System.monotonic_time(:millisecond), ref})
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)
    reaped = 0

    entries = :ets.tab2list(@ets_table)

    reaped =
      Enum.reduce(entries, reaped, fn {pid, started, ref}, acc ->
        age = now - started

        cond do
          not Process.alive?(pid) ->
            Process.demonitor(ref, [:flush])
            :ets.delete(@ets_table, pid)
            acc + 1

          age > @max_age_ms ->
            Logger.info(
              "ConnectionReaper: killing stale SSE process #{inspect(pid)} (age #{div(age, 1000)}s)"
            )

            Process.demonitor(ref, [:flush])
            Process.exit(pid, :kill)
            :ets.delete(@ets_table, pid)
            acc + 1

          true ->
            acc
        end
      end)

    if reaped > 0 do
      Logger.info("ConnectionReaper: reaped #{reaped} SSE connection(s), #{count()} remaining")
    end

    schedule_sweep()
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.delete(@ets_table, pid)
    {:noreply, state}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end
end
