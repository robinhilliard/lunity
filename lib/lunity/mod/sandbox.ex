defmodule Lunity.Mod.Sandbox do
  @moduledoc """
  Lua sandbox configuration for luerl states.

  Strips unsafe globals (io, os, debug, load, loadfile, dofile, require, etc.)
  while keeping safe standard library functions (table, string, math, pairs, etc.).
  """

  @unsafe_globals ~w(io os debug load loadfile dofile require rawget rawset
                     collectgarbage getfenv setfenv newproxy module)

  @doc """
  Create a sandboxed luerl state with unsafe globals removed.
  """
  @spec new() :: :luerl.luerl_state()
  def new do
    st = :luerl.init()
    strip_unsafe(st)
  end

  @doc """
  Strip unsafe globals from an existing luerl state.
  """
  @spec strip_unsafe(:luerl.luerl_state()) :: :luerl.luerl_state()
  def strip_unsafe(st) do
    nils = Enum.map_join(@unsafe_globals, "\n", fn name -> "#{name} = nil" end)

    case :luerl.do(nils, st) do
      {:ok, _, new_st} -> new_st
      {_, new_st} -> new_st
    end
  end

  @doc """
  Set a nested table value using a key path.

  E.g. `set_nested(st, ["lunity", "entity", "get"], func)` creates
  `lunity.entity.get = func` in the Lua state.
  """
  @spec set_nested(:luerl.luerl_state(), [String.t()], term()) :: :luerl.luerl_state()
  def set_nested(st, keys, value) when is_function(value) do
    {enc_val, st} = :luerl.encode(value, st)

    case :luerl.set_table_keys(st, keys, enc_val) do
      {:ok, _, new_st} -> new_st
      new_st -> new_st
    end
  end

  def set_nested(st, keys, value) do
    path = Enum.join(keys, ".")
    lua_val = encode_lua_literal(value)
    lua_code = "#{path} = #{lua_val}"

    case :luerl.do(lua_code, st) do
      {:ok, _, new_st} -> new_st
      {_, new_st} -> new_st
    end
  end

  defp encode_lua_literal(v) when is_number(v), do: "#{v}"
  defp encode_lua_literal(v) when is_binary(v), do: "\"#{v}\""
  defp encode_lua_literal(true), do: "true"
  defp encode_lua_literal(false), do: "false"
  defp encode_lua_literal(nil), do: "nil"
  defp encode_lua_literal(_), do: "nil"

  @doc """
  Create an Erlang function callable from Lua.

  The function receives `(args, lua_state)` and must return `{results, lua_state}`.
  """
  @spec lua_func((list(), :luerl.luerl_state() -> {list(), :luerl.luerl_state()})) ::
          function()
  def lua_func(fun) do
    fun
  end
end
