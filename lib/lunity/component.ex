defmodule Lunity.Component do
  @moduledoc """
  Behaviour for Lunity ECS components.

  Components come in two storage flavours:

  - **Tensor** (`storage: :tensor`) -- numeric data stored as Nx tensors in
    contiguous memory. Ideal for data processed every tick (positions,
    velocities, health). Systems operate on the full tensor via `defn`.

  - **Structured** (`storage: :structured`) -- arbitrary Elixir terms stored
    in ETS. Ideal for variable-length or non-numeric data (inventories, names,
    quest state) that changes infrequently and is handled by event-driven code.

  Both backends share a common API for individual entity access (`get/1`,
  `put/2`, `remove/1`, `exists?/1`). Tensor components additionally expose
  raw tensor access for batch processing.

  ## Tensor components

      defmodule MyGame.Components.Position do
        use Lunity.Component,
          storage: :tensor,
          shape: {3},
          dtype: :f32
      end

  Auto-generates `@opaque t :: Nx.Tensor.t()` (distinct per component for
  dialyzer) and `@type input` derived from shape/dtype (e.g. `{number(),
  number(), number()}` for shape `{3}`, dtype `:f32`).

  ## Structured components

  Define `@type t` before `use`:

      defmodule MyGame.Components.Inventory do
        @type t :: [MyGame.Item.t()]
        use Lunity.Component, storage: :structured
      end

  Compile error if `@type t` is missing.

  Both are registered with the `Lunity.ComponentStore` at startup.
  """

  @type entity_id :: term()

  @callback get(entity_id()) :: term() | nil
  @callback put(entity_id(), term()) :: :ok
  @callback remove(entity_id()) :: :ok
  @callback exists?(entity_id()) :: boolean()
  @callback __component_opts__() :: map()

  @doc false
  def input_type_ast(shape, dtype) do
    scalar =
      case dtype do
        :f32 -> quote(do: number())
        :f64 -> quote(do: number())
        :s32 -> quote(do: integer())
        :s64 -> quote(do: integer())
        :u8 -> quote(do: non_neg_integer())
        _ -> quote(do: number())
      end

    # Non-2-element tuples arrive as AST {:{}, meta, elements} in macro context
    dims =
      case shape do
        {:{}, _, elements} when is_list(elements) -> elements
        t when is_tuple(t) -> Tuple.to_list(t)
      end

    case dims do
      [] -> scalar
      [n] when is_integer(n) -> {:{}, [], List.duplicate(scalar, n)}
      _ -> quote(do: term())
    end
  end

  defmacro __using__(opts) do
    storage = Keyword.get(opts, :storage, :tensor)

    case storage do
      :tensor ->
        shape = Keyword.get(opts, :shape, {})
        dtype = Keyword.get(opts, :dtype, :f32)
        input_type = Lunity.Component.input_type_ast(shape, dtype)

        quote do
          @behaviour Lunity.Component

          @opaque t :: Nx.Tensor.t()
          @type input :: unquote(input_type)

          @lunity_component_opts %{
            storage: :tensor,
            shape: unquote(shape),
            dtype: unquote(dtype),
            module: __MODULE__
          }

          @impl Lunity.Component
          def __component_opts__, do: @lunity_component_opts

          @impl Lunity.Component
          @spec get(Lunity.Component.entity_id()) :: unquote(input_type) | nil
          def get(entity_id), do: Lunity.ComponentStore.get(__MODULE__, entity_id)

          @impl Lunity.Component
          @spec put(Lunity.Component.entity_id(), unquote(input_type)) :: :ok
          def put(entity_id, value), do: Lunity.ComponentStore.put(__MODULE__, entity_id, value)

          @impl Lunity.Component
          def remove(entity_id), do: Lunity.ComponentStore.remove(__MODULE__, entity_id)

          @impl Lunity.Component
          def exists?(entity_id), do: Lunity.ComponentStore.exists?(__MODULE__, entity_id)

          @doc "Returns the raw Nx tensor for batch processing."
          def tensor, do: Lunity.ComponentStore.get_tensor(__MODULE__)

          @doc "Replaces the tensor (called by the system runner after defn processing)."
          def put_tensor(t), do: Lunity.ComponentStore.put_tensor(__MODULE__, t)

          def shape, do: unquote(shape)
          def dtype, do: unquote(dtype)
        end

      :structured ->
        index = Keyword.get(opts, :index, false)

        quote do
          @behaviour Lunity.Component
          @before_compile {Lunity.Component, :__before_compile_structured__}

          @lunity_component_opts %{
            storage: :structured,
            index: unquote(index),
            module: __MODULE__
          }

          @impl Lunity.Component
          def __component_opts__, do: @lunity_component_opts

          @impl Lunity.Component
          @spec get(Lunity.Component.entity_id()) :: t() | nil
          def get(entity_id), do: Lunity.ComponentStore.get(__MODULE__, entity_id)

          @impl Lunity.Component
          @spec put(Lunity.Component.entity_id(), t()) :: :ok
          def put(entity_id, value), do: Lunity.ComponentStore.put(__MODULE__, entity_id, value)

          @impl Lunity.Component
          def remove(entity_id), do: Lunity.ComponentStore.remove(__MODULE__, entity_id)

          @impl Lunity.Component
          def exists?(entity_id), do: Lunity.ComponentStore.exists?(__MODULE__, entity_id)

          @doc "Returns all `{entity_id, value}` pairs."
          def all, do: Lunity.ComponentStore.all(__MODULE__)

          if unquote(index) do
            @doc "Returns entity IDs that have the given value (uses index)."
            def search(value), do: Lunity.ComponentStore.search(__MODULE__, value)
          end
        end

      other ->
        raise ArgumentError,
              "Invalid storage type: #{inspect(other)}. Use :tensor or :structured."
    end
  end

  defmacro __before_compile_structured__(env) do
    types = Module.get_attribute(env.module, :type) || []

    has_t =
      Enum.any?(types, fn
        {:type, {:"::", _, [{:t, _, _} | _]}, _} -> true
        _ -> false
      end)

    unless has_t do
      raise CompileError,
        description:
          "#{inspect(env.module)} is a structured component and must define " <>
            "@type t :: ... before use Lunity.Component",
        file: env.file,
        line: env.line
    end

    nil
  end
end
