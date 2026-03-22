defmodule Lunity.System do
  @moduledoc """
  Behaviour for Lunity ECS systems.

  Systems process component data each tick. Two types:

  ## Tensor systems

  Operate on entire tensors at once via `Nx.Defn`. The framework reads
  the declared tensors, passes them as a map to `run/1`, and writes
  the returned tensors back. Reads and writes are derived from the
  `@spec` on `run/1`:

      defmodule MyGame.Systems.MoveBall do
        use Lunity.System, type: :tensor

        alias Lunity.Components.Position
        alias MyGame.Components.Velocity

        @spec run(%{position: Position.t(), velocity: Velocity.t()}) :: %{position: Position.t()}
        defn run(%{position: pos, velocity: vel}) do
          %{position: Nx.add(pos, vel)}
        end
      end

  ## Structured systems

  Operate on individual entities. The framework iterates entities that have
  the declared components and calls `run/2` for each.

      defmodule MyGame.Systems.DecayBuffs do
        use Lunity.System, type: :structured

        alias MyGame.Components.ActiveBuffs

        @spec run(integer(), %{active_buffs: ActiveBuffs.t()}) :: %{active_buffs: ActiveBuffs.t()}
        def run(_entity_id, %{active_buffs: buffs}) do
          %{active_buffs: Enum.reject(buffs, &expired?/1)}
        end
      end
  """

  @callback __system_opts__() :: map()

  defmacro __using__(opts) do
    type = Keyword.get(opts, :type, :tensor)

    import_defn =
      if type == :tensor do
        quote do: import(Nx.Defn)
      end

    entities = Keyword.get(opts, :entities, [])

    filter =
      case Keyword.get(opts, :filter) do
        nil -> nil
        list when is_list(list) -> list
        single -> [single]
      end

    quote do
      @behaviour Lunity.System
      @before_compile Lunity.System
      @lunity_system_type unquote(type)
      @lunity_system_entities unquote(entities)
      @lunity_system_filter unquote(filter)
      unquote(import_defn)
    end
  end

  defmacro __before_compile__(env) do
    type = Module.get_attribute(env.module, :lunity_system_type)
    specs = Module.get_attribute(env.module, :spec) || []
    arity = if type == :tensor, do: 1, else: 2

    run_spec = find_run_spec(specs, arity)

    unless run_spec do
      raise CompileError,
        description: """
        #{inspect(env.module)} must define @spec for run/#{arity} -- the spec's \
        input/output map types declare which components the system reads and writes.

            @spec run(%{position: Position.t(), velocity: Velocity.t()}) :: %{position: Position.t()}\
        """,
        file: env.file,
        line: env.line
    end

    {reads, writes} = extract_reads_writes(run_spec, arity, env)

    Enum.each(reads, fn {key, mod} ->
      expected = Lunity.System.component_key(mod)

      unless key == expected do
        raise CompileError,
          description:
            "#{inspect(env.module)}: spec key :#{key} doesn't match " <>
              "#{inspect(mod)} -> :#{expected}",
          file: env.file,
          line: env.line
      end
    end)

    Enum.each(writes, fn {key, mod} ->
      expected = Lunity.System.component_key(mod)

      unless key == expected do
        raise CompileError,
          description:
            "#{inspect(env.module)}: spec key :#{key} doesn't match " <>
              "#{inspect(mod)} -> :#{expected}",
          file: env.file,
          line: env.line
      end
    end)

    read_modules = Enum.map(reads, fn {_key, mod} -> mod end)
    write_modules = Enum.map(writes, fn {_key, mod} -> mod end)
    entities = Module.get_attribute(env.module, :lunity_system_entities) || []
    filter = Module.get_attribute(env.module, :lunity_system_filter)

    quote do
      @impl Lunity.System
      def __system_opts__ do
        %{
          type: unquote(type),
          reads: unquote(read_modules),
          writes: unquote(write_modules),
          entities: unquote(entities),
          filter: unquote(filter)
        }
      end
    end
  end

  @doc """
  Converts a component module to its short key for use in system input/output maps.
  `MyGame.Components.Position` becomes `:position`.
  """
  def component_key(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  # Find the spec for run/arity in the accumulated specs.
  # Specs are stored as {:spec, expr, pos} tuples in Elixir quoted AST.
  defp find_run_spec(specs, arity) do
    Enum.find_value(specs, fn
      {:spec, {:"::", _, [{:run, _, args} | _]} = spec, _pos}
      when length(args) == arity ->
        spec

      _ ->
        nil
    end)
  end

  # Extract {reads, writes} from the spec AST.
  # Spec shape: {:"::", _, [call, return_type]}
  # For tensor (arity 1): call is {:run, _, [input_map]}
  # For structured (arity 2): call is {:run, _, [_entity_id_type, input_map]}
  defp extract_reads_writes({:"::", _, [call, return_type]}, arity, env) do
    {:run, _, args} = call

    input_map =
      case arity do
        1 -> hd(args)
        2 -> Enum.at(args, 1)
      end

    reads = extract_map_components(input_map, env)
    writes = extract_map_components(return_type, env)
    {reads, writes}
  end

  # Extract [{key, module}] from a map type AST like %{position: Position.t()}
  defp extract_map_components({:%{}, _, kvs}, env) when is_list(kvs) do
    Enum.map(kvs, fn {key, type_call} ->
      mod = extract_module_from_type_call(type_call, env)
      {key, mod}
    end)
  end

  defp extract_map_components({:|, _, types}, env) do
    Enum.find_value(types, [], fn type ->
      case extract_map_components(type, env) do
        [] -> nil
        components -> components
      end
    end)
  end

  defp extract_map_components(_other, _env), do: []

  # Extract the module from a remote type call like Position.t()
  # AST: {{:., meta, [module_alias, :t]}, meta, []}
  defp extract_module_from_type_call({{:., _, [mod_ast, :t]}, _, []}, env) do
    Macro.expand(mod_ast, env)
  end

  defp extract_module_from_type_call({{:., _, [mod_ast, :t]}, _, _args}, env) do
    Macro.expand(mod_ast, env)
  end

  defp extract_module_from_type_call(other, _env) do
    raise CompileError,
      description:
        "System spec map values must be component type references like Position.t(), " <>
          "got: #{Macro.to_string(other)}"
  end
end
