defmodule Lunity.Editor.SourcePatcher do
  @moduledoc """
  Surgical source-level patching of scene DSL node properties.

  Uses Sourceror to parse the AST with full position metadata, locate a
  `node(:name, ...)` or `light(:name, ...)` call by name, find the target
  keyword value, and patch just that range in the original source string.
  Everything else -- formatting, comments, other nodes -- is untouched.

  Only literal tuple values (position, scale, rotation) are patchable.
  Function calls or variable references are detected and rejected with
  `{:error, :not_a_literal}`.
  """

  alias Sourceror.Zipper

  @patchable_keys [:position, :scale, :rotation]

  @doc """
  Patch a single keyword value in a `node` or `light` call within a scene file.

  ## Parameters

  - `source_file` - Absolute path to the `.ex` source file
  - `node_name` - Atom name of the node (e.g. `:ball`)
  - `key` - Keyword to patch (`:position`, `:scale`, or `:rotation`)
  - `value` - New tuple value (e.g. `{1.0, 2.0, 3.0}`)

  ## Returns

  - `:ok` on success
  - `{:error, reason}` on failure
  """
  @spec patch_node(String.t(), atom(), atom(), tuple()) :: :ok | {:error, term()}
  def patch_node(source_file, node_name, key, value) when key in @patchable_keys do
    with {:ok, source} <- File.read(source_file),
         {:ok, patched} <- patch_source(source, node_name, key, value) do
      File.write(source_file, patched)
    end
  end

  def patch_node(_source_file, _node_name, key, _value) do
    {:error, {:unsupported_key, key}}
  end

  @doc """
  Like `patch_node/4` but operates on a source string and returns the patched
  string. Useful for testing without file I/O.
  """
  @spec patch_source(String.t(), atom(), atom(), tuple()) :: {:ok, String.t()} | {:error, term()}
  def patch_source(source, node_name, key, value) when key in @patchable_keys do
    ast = Sourceror.parse_string!(source)
    zipper = Zipper.zip(ast)

    with {:ok, value_ast} <- find_value_ast(zipper, node_name, key) do
      range = Sourceror.get_range(value_ast)
      replacement = inspect(value)
      patch = %Sourceror.Patch{range: range, change: replacement, preserve_indentation: true}
      {:ok, Sourceror.patch_string(source, [patch])}
    end
  end

  defp find_value_ast(zipper, node_name, key) do
    case find_node_call(zipper, node_name) do
      nil ->
        {:error, :node_not_found}

      call_zipper ->
        call_ast = Zipper.node(call_zipper)
        find_keyword_value(call_ast, key)
    end
  end

  defp find_node_call(zipper, target_name) do
    Zipper.find(zipper, fn
      {:node, _, [name | _]} -> extract_atom(name) == target_name
      {:light, _, [name | _]} -> extract_atom(name) == target_name
      _ -> false
    end)
  end

  defp find_keyword_value({call, _, [_name | rest]}, key) when call in [:node, :light] do
    kw_list =
      case rest do
        [kw] when is_list(kw) -> kw
        _ -> []
      end

    result =
      Enum.find_value(kw_list, fn
        {{:__block__, _, [^key]}, value_ast} -> {key, value_ast}
        {^key, value_ast} -> {key, value_ast}
        _ -> nil
      end)

    case result do
      nil -> {:error, :key_not_found}
      {_key, value_ast} -> validate_literal_tuple(value_ast)
    end
  end

  defp find_keyword_value(_, _key), do: {:error, :node_not_found}

  defp validate_literal_tuple({:{}, _meta, elements} = ast) when is_list(elements) do
    if Enum.all?(elements, &number_literal?/1),
      do: {:ok, ast},
      else: {:error, :not_a_literal}
  end

  defp validate_literal_tuple({a, b} = ast) do
    if number_literal?(a) and number_literal?(b),
      do: {:ok, ast},
      else: {:error, :not_a_literal}
  end

  defp validate_literal_tuple(_), do: {:error, :not_a_literal}

  defp number_literal?({:__block__, _, [n]}) when is_number(n), do: true
  defp number_literal?({:-, _, [inner]}), do: number_literal?(inner)
  defp number_literal?(n) when is_number(n), do: true
  defp number_literal?(_), do: false

  defp extract_atom({:__block__, _, [atom]}) when is_atom(atom), do: atom
  defp extract_atom(atom) when is_atom(atom), do: atom
  defp extract_atom(_), do: nil
end
