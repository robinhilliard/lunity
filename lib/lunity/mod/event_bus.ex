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

  Returns `:ok`. Handler errors are logged but don't stop dispatch.
  """
  @spec dispatch(String.t(), map()) :: :ok
  def dispatch(event_name, payload \\ %{}) do
    GenServer.cast(__MODULE__, {:dispatch, event_name, payload})
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

  def handle_cast({:dispatch, event_name, payload}, state) do
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

    {:noreply, %{state | runtime_states: runtime_states}}
  end

  def handle_cast({:set_runtime, mod_name, lua_state}, state) do
    {:noreply, %{state | runtime_states: Map.put(state.runtime_states, mod_name, lua_state)}}
  end

  def handle_cast(:clear, _state) do
    {:noreply, %{handlers: %{}, runtime_states: %{}}}
  end

  @impl true
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

    task =
      Task.async(fn ->
        payload_table = payload_to_lua(payload)

        case :luerl.call_function(lua_st, func_ref, [payload_table]) do
          {:ok, _results, new_st} -> {:ok, new_st}
          {_results, new_st} when is_tuple(new_st) -> {:ok, new_st}
          error -> {:error, error}
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

  defp payload_to_lua(payload) when is_map(payload) do
    Enum.map(payload, fn {k, v} -> {to_string(k), lua_value(v)} end)
  end

  defp payload_to_lua(payload) when is_list(payload), do: payload

  defp lua_value(v) when is_number(v), do: v * 1.0
  defp lua_value(v) when is_binary(v), do: v
  defp lua_value(v) when is_boolean(v), do: v
  defp lua_value(nil), do: nil
  defp lua_value(v) when is_atom(v), do: Atom.to_string(v)
  defp lua_value(v) when is_map(v), do: payload_to_lua(v)

  defp lua_value(v) when is_list(v),
    do: Enum.with_index(v, 1) |> Enum.map(fn {e, i} -> {i * 1.0, lua_value(e)} end)

  defp lua_value(v), do: inspect(v)
end
