defmodule Lunity.Mod do
  @moduledoc """
  Mod discovery, metadata parsing, and dependency resolution.

  Discovers mods in `priv/mods/`, parses each `mod.lua` for metadata,
  and returns a topologically sorted load order based on dependencies.

  ## Mod structure

      priv/mods/
        base/
          mod.lua           # metadata: name, version, title, dependencies
          data.lua          # data stage: scene/prefab/entity definitions
          data-updates.lua  # optional: patch other mods' data
          data-final-fixes.lua  # optional: final adjustments
          control.lua       # runtime stage: event handlers
          assets/
            prefabs/
              box.glb

  ## mod.lua format

      return {
        name = "base",
        version = "1.0.0",
        title = "My Game",
        dependencies = {}
      }
  """

  require Logger

  @type mod_info :: %{
          name: String.t(),
          version: String.t(),
          title: String.t(),
          dependencies: [String.t()],
          dir: String.t()
        }

  @doc """
  Discover and sort all mods in the given mods directory.

  Returns `{:ok, [mod_info]}` with mods in dependency order,
  or `{:error, reason}` if metadata is invalid or dependencies cycle.
  """
  @spec discover_and_sort(String.t()) :: {:ok, [mod_info()]} | {:error, term()}
  def discover_and_sort(mods_dir) do
    with {:ok, mods} <- discover(mods_dir),
         {:ok, sorted} <- topological_sort(mods) do
      {:ok, sorted}
    end
  end

  @doc """
  Discover all mods in a directory. Returns unsorted mod info list.
  """
  @spec discover(String.t()) :: {:ok, [mod_info()]} | {:error, term()}
  def discover(mods_dir) do
    if File.dir?(mods_dir) do
      mods_dir
      |> File.ls!()
      |> Enum.filter(&File.dir?(Path.join(mods_dir, &1)))
      |> Enum.reduce_while({:ok, []}, fn dir_name, {:ok, acc} ->
        mod_dir = Path.join(mods_dir, dir_name)

        case parse_mod_lua(mod_dir) do
          {:ok, info} -> {:cont, {:ok, [info | acc]}}
          {:error, reason} -> {:halt, {:error, {dir_name, reason}}}
        end
      end)
      |> case do
        {:ok, mods} -> {:ok, Enum.reverse(mods)}
        error -> error
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Parse mod.lua in a mod directory and return mod info.
  """
  @spec parse_mod_lua(String.t()) :: {:ok, mod_info()} | {:error, term()}
  def parse_mod_lua(mod_dir) do
    mod_lua_path = Path.join(mod_dir, "mod.lua")

    if File.exists?(mod_lua_path) do
      st = :luerl.init()
      lua_code = File.read!(mod_lua_path)

      case :luerl.do_dec(lua_code, st) do
        {:ok, [result], _st2} ->
          extract_mod_info(result, mod_dir)

        _ ->
          {:error, {:invalid_mod_lua, "mod.lua must return a table"}}
      end
    else
      {:error, {:missing_mod_lua, mod_dir}}
    end
  rescue
    e -> {:error, {:mod_lua_error, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:mod_lua_error, {kind, reason}}}
  end

  @doc """
  Topological sort of mods by dependency chain depth, then alphabetical.
  """
  @spec topological_sort([mod_info()]) :: {:ok, [mod_info()]} | {:error, term()}
  def topological_sort(mods) do
    by_name = Map.new(mods, &{&1.name, &1})
    visited = MapSet.new()
    result = []

    try do
      {sorted, _visited} =
        Enum.reduce(mods, {result, visited}, fn mod, {acc, vis} ->
          visit(mod.name, by_name, vis, acc, MapSet.new())
        end)

      {:ok, Enum.reverse(sorted)}
    catch
      {:cycle, name} -> {:error, {:dependency_cycle, name}}
      {:missing_dep, dep, from} -> {:error, {:missing_dependency, dep, from}}
    end
  end

  @doc """
  Returns the mods directory for a given app.
  """
  @spec mods_dir(atom()) :: String.t()
  def mods_dir(app) do
    Path.join(Lunity.priv_dir_for_app(app), "mods")
  end

  # -- Private ----------------------------------------------------------------

  defp visit(name, by_name, visited, result, in_stack) do
    cond do
      MapSet.member?(visited, name) ->
        {result, visited}

      MapSet.member?(in_stack, name) ->
        throw({:cycle, name})

      true ->
        mod = Map.get(by_name, name) || throw({:missing_dep, name, "unknown"})
        in_stack = MapSet.put(in_stack, name)

        {result, visited} =
          Enum.reduce(mod.dependencies, {result, visited}, fn dep, {acc, vis} ->
            unless Map.has_key?(by_name, dep) do
              throw({:missing_dep, dep, name})
            end

            visit(dep, by_name, vis, acc, in_stack)
          end)

        {[mod | result], MapSet.put(visited, name)}
    end
  end

  defp extract_mod_info(decoded, mod_dir) when is_list(decoded) do
    props = Map.new(decoded)
    name_str = to_string_safe(Map.get(props, "name"))

    if name_str == nil or name_str == "" do
      {:error, {:invalid_mod_lua, "mod.lua must have a 'name' field"}}
    else
      deps = decode_deps(Map.get(props, "dependencies"))

      {:ok,
       %{
         name: name_str,
         version: to_string_safe(Map.get(props, "version")) || "0.0.0",
         title: to_string_safe(Map.get(props, "title")) || name_str,
         dependencies: deps,
         dir: mod_dir
       }}
    end
  end

  defp extract_mod_info(other, mod_dir) do
    {:error,
     {:invalid_mod_lua, "mod.lua at #{mod_dir} returned #{inspect(other)}, expected table"}}
  end

  defp decode_deps(nil), do: []

  defp decode_deps(deps) when is_list(deps) do
    deps
    |> Enum.filter(fn {_k, v} -> is_binary(v) end)
    |> Enum.map(fn {_k, v} -> v end)
  end

  defp decode_deps(_), do: []

  defp to_string_safe(nil), do: nil
  defp to_string_safe(bin) when is_binary(bin), do: bin
  defp to_string_safe(num) when is_number(num), do: "#{num}"
  defp to_string_safe(_), do: nil
end
