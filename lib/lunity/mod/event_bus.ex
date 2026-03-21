defmodule Lunity.Mod.EventBus do
  @moduledoc """
  GenServer that manages event handler registration and dispatches
  engine events to mod runtime states.

  Mods register handlers via `lunity.on(event_name, handler)` in their
  `control.lua`. The EventBus dispatches events in mod load order.
  """
  use GenServer

  require Logger

  @type handler :: {mod_name :: String.t(), func_ref :: term()}

  # -- Public API -------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register an event handler for a mod.
  """
  @spec register(String.t(), String.t(), term()) :: :ok
  def register(mod_name, event_name, func_ref) do
    GenServer.cast(__MODULE__, {:register, mod_name, event_name, func_ref})
  end

  @doc """
  Dispatch an event to all registered handlers.

  Returns `:ok` after handlers finish. Uses a synchronous `call` so gameplay ticks
  (`on_tick`) apply ECS/input updates before the instance continues the frame.
  """
  @spec dispatch(String.t(), map()) :: :ok
  def dispatch(event_name, payload \\ %{}) do
    timeout = Application.get_env(:lunity, :mod_dispatch_timeout, 60_000)
    GenServer.call(__MODULE__, {:dispatch, event_name, payload}, timeout)
  end

  @doc """
  Get all registered handlers for an event.
  """
  @spec handlers(String.t()) :: [handler()]
  def handlers(event_name) do
    GenServer.call(__MODULE__, {:handlers, event_name})
  end

  @doc """
  Clear all handlers (e.g. on scene reload).
  """
  @spec clear() :: :ok
  def clear do
    GenServer.cast(__MODULE__, :clear)
  end

  # -- GenServer callbacks ----------------------------------------------------

  @impl true
  def init(_opts) do
    {:ok, %{handlers: %{}, runtime_states: %{}}}
  end

  @impl true
  def handle_cast({:register, mod_name, event_name, func_ref}, state) do
    handlers = state.handlers
    existing = Map.get(handlers, event_name, [])
    updated = existing ++ [{mod_name, func_ref}]
    {:noreply, %{state | handlers: Map.put(handlers, event_name, updated)}}
  end

  def handle_cast({:set_runtime, mod_name, lua_state}, state) do
    {:noreply, %{state | runtime_states: Map.put(state.runtime_states, mod_name, lua_state)}}
  end

  def handle_cast(:clear, _state) do
    {:noreply, %{handlers: %{}, runtime_states: %{}}}
  end

  @impl true
  def handle_call({:dispatch, event_name, payload}, _from, state) do
    handlers = Map.get(state.handlers, event_name, [])

    runtime_states =
      Enum.reduce(handlers, state.runtime_states, fn {mod_name, func_ref}, runtimes ->
        case Map.get(runtimes, mod_name) do
          nil ->
            runtimes

          lua_st ->
            case call_handler_safe(lua_st, func_ref, payload) do
              {:ok, new_st} ->
                Map.put(runtimes, mod_name, new_st)

              {:error, reason} ->
                Logger.warning(
                  "Mod #{mod_name}: error in #{event_name} handler: #{inspect(reason)}"
                )

                runtimes
            end
        end
      end)

    {:reply, :ok, %{state | runtime_states: runtime_states}}
  end

  def handle_call({:handlers, event_name}, _from, state) do
    {:reply, Map.get(state.handlers, event_name, []), state}
  end

  @doc false
  def set_runtime_state(mod_name, lua_state) do
    GenServer.cast(__MODULE__, {:set_runtime, mod_name, lua_state})
  end

  # -- Private ----------------------------------------------------------------

  defp call_handler_safe(lua_st, func_ref, payload) do
    timeout = Application.get_env(:lunity, :mod_handler_timeout, 5_000)

    store_id = Map.get(payload, :store_id) || Map.get(payload, "store_id")
    dt = Map.get(payload, :dt) || Map.get(payload, "dt")

    task =
      Task.async(fn ->
        if store_id do
          sessions = build_sessions_by_entity(to_string(store_id))

          Process.put(:lunity_mod_tick, %{
            store_id: to_string(store_id),
            dt: (dt || 0.0) * 1.0,
            sessions_by_entity: sessions
          })
        end

        try do
          # luerl:call_function(Func, Args, St) — not (St, Func, Args).
          # Args must be encoded luerldata (e.g. one Lua table for the event payload).
          {encoded_args, st1} = :luerl.encode_list([payload], lua_st)

          case :luerl.call_function(func_ref, encoded_args, st1) do
            {:ok, _results, new_st} -> {:ok, new_st}
            {_results, new_st} when is_tuple(new_st) -> {:ok, new_st}
            error -> {:error, error}
          end
        after
          if store_id, do: Process.delete(:lunity_mod_tick)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp build_sessions_by_entity(store_id) do
    Lunity.Input.Session.all_sessions()
    |> Enum.reduce(%{}, fn {sid, meta}, acc ->
      if meta.instance_id == store_id && meta.entity_id do
        Map.put(acc, entity_key_string(meta.entity_id), sid)
      else
        acc
      end
    end)
  end

  defp entity_key_string(id) when is_atom(id), do: Atom.to_string(id)
  defp entity_key_string(id) when is_binary(id), do: id
end
