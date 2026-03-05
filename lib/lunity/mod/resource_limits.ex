defmodule Lunity.Mod.ResourceLimits do
  @moduledoc """
  Resource limiting for Lua mod execution.

  Uses luerl's trace function to count instructions and abort runaway scripts.
  Provides configurable limits via application config.

  ## Configuration

      config :lunity,
        mod_instruction_limit: 1_000_000,  # max instructions per script execution
        mod_handler_timeout: 5_000,        # ms timeout for event handlers
        mod_max_state_size: 10_000_000     # bytes limit for luerl state
  """

  require Logger

  @default_instruction_limit 1_000_000
  @default_handler_timeout 5_000
  @default_max_state_size 10_000_000

  @doc """
  Install instruction counting on a luerl state.

  Uses `set_trace_func/2` to count each instruction. When the limit
  is exceeded, the trace function raises an error that aborts execution.
  """
  @spec install_instruction_counter(:luerl.luerl_state()) :: :luerl.luerl_state()
  def install_instruction_counter(st) do
    limit = instruction_limit()

    trace_func = fn _event, st_inner ->
      count =
        case :luerl.get_private(st_inner, :instruction_count) do
          {:ok, val} -> val || 0
          val -> val || 0
        end

      new_count = count + 1

      if new_count > limit do
        throw({:instruction_limit_exceeded, new_count})
      end

      unwrap_luerl(:luerl.put_private(st_inner, :instruction_count, new_count))
    end

    st = unwrap_luerl(:luerl.put_private(st, :instruction_count, 0))
    unwrap_luerl(:luerl.set_trace_func(trace_func, st))
  end

  @doc """
  Reset the instruction counter on a luerl state.
  """
  @spec reset_counter(:luerl.luerl_state()) :: :luerl.luerl_state()
  def reset_counter(st) do
    unwrap_luerl(:luerl.put_private(st, :instruction_count, 0))
  end

  @doc """
  Check if a luerl state exceeds the memory size limit.
  """
  @spec check_state_size(:luerl.luerl_state()) :: :ok | {:error, :state_too_large}
  def check_state_size(st) do
    limit = max_state_size()
    size = :erlang.external_size(st)

    if size > limit do
      Logger.warning("Lua state size #{size} exceeds limit #{limit}")

      {:error, :state_too_large}
    else
      :ok
    end
  end

  @doc """
  Get the configured instruction limit.
  """
  @spec instruction_limit() :: pos_integer()
  def instruction_limit do
    Application.get_env(:lunity, :mod_instruction_limit, @default_instruction_limit)
  end

  @doc """
  Get the configured handler timeout in milliseconds.
  """
  @spec handler_timeout() :: pos_integer()
  def handler_timeout do
    Application.get_env(:lunity, :mod_handler_timeout, @default_handler_timeout)
  end

  @doc """
  Get the configured max state size in bytes.
  """
  @spec max_state_size() :: pos_integer()
  def max_state_size do
    Application.get_env(:lunity, :mod_max_state_size, @default_max_state_size)
  end

  defp unwrap_luerl({:ok, st}), do: st
  defp unwrap_luerl({:ok, _val, st}), do: st
  defp unwrap_luerl(st) when is_tuple(st), do: st
end
