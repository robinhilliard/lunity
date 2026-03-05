defmodule Lunity.Scene.Def do
  @moduledoc """
  A config-driven scene definition. Returned by `scene do...end` in `.exs` scene files.

  Contains a list of `Lunity.Scene.NodeDef` structs representing the scene layout.
  SceneLoader builds an EAGL scene graph from this definition.
  """
  @type t :: %__MODULE__{
          nodes: [Lunity.Scene.NodeDef.t()]
        }
  defstruct nodes: []
end

defmodule Lunity.Scene.NodeDef do
  @moduledoc """
  A node definition within a config-driven scene.

  ## Fields

  - `:name` - Node name (atom, required)
  - `:prefab` - Prefab ID to load (e.g. `"box"`)
  - `:entity` - Entity module atom (e.g. `Pong.Paddle`) for ECSx integration
  - `:config` - Config path relative to `priv/config/` for entity defaults
  - `:extras` - Map of per-instance overrides (merged with config, extras win)
  - `:position` - `{x, y, z}` tuple or `[x, y, z]` list
  - `:scale` - `{x, y, z}` tuple or `[x, y, z]` list
  - `:rotation` - `{x, y, z, w}` quaternion tuple or list
  - `:children` - List of child `NodeDef` structs (for nested hierarchies)
  """
  @type vec3 :: {number(), number(), number()}
  @type quat :: {number(), number(), number(), number()}

  @type t :: %__MODULE__{
          name: atom(),
          prefab: String.t() | nil,
          entity: module() | nil,
          config: String.t() | nil,
          extras: map() | nil,
          position: vec3() | nil,
          scale: vec3() | nil,
          rotation: quat() | nil,
          children: [t()] | nil
        }

  defstruct [
    :name,
    :prefab,
    :entity,
    :config,
    :extras,
    :position,
    :scale,
    :rotation,
    children: []
  ]
end

defmodule Lunity.Scene.DSL do
  @moduledoc """
  DSL for config-driven scene files.

  Import this module in `.exs` scene files to define scenes declaratively:

      import Lunity.Scene.DSL

      scene do
        node :floor,        prefab: "box", position: {0, 0, -1}, scale: {12, 6, 0.3}
        node :paddle_left,  prefab: "box", entity: Pong.Paddle,
                            position: {-18, 0, 0.5}, scale: {0.3, 1.5, 0.3},
                            extras: %{side: :left}
        node :ball,         prefab: "box", entity: Pong.Ball,
                            position: {0, 0, 0.5}, scale: {0.4, 0.4, 0.4}
      end

  The `scene` macro returns a `%Lunity.Scene.Def{}` struct which SceneLoader
  knows how to build into an EAGL scene graph.
  """

  alias Lunity.Scene.{Def, NodeDef}

  @doc """
  Defines a scene containing node declarations.

  Returns a `%Lunity.Scene.Def{}` struct.
  """
  defmacro scene(do: block) do
    nodes = extract_nodes(block)

    quote do
      %Def{nodes: unquote(nodes)}
    end
  end

  @doc """
  Declares a node within a `scene do...end` block.

  ## Options

  - `:prefab` - Prefab ID (e.g. `"box"`)
  - `:entity` - Entity module atom (e.g. `Pong.Paddle`)
  - `:config` - Config path for entity defaults
  - `:extras` - Map of per-instance overrides
  - `:position` - `{x, y, z}` position
  - `:scale` - `{x, y, z}` scale
  - `:rotation` - `{x, y, z, w}` quaternion rotation
  """
  def node(name, opts \\ []) when is_atom(name) do
    position = validate_vec3(opts[:position], :position)
    scale = validate_vec3(opts[:scale], :scale)
    rotation = validate_quat(opts[:rotation], :rotation)

    %NodeDef{
      name: name,
      prefab: opts[:prefab],
      entity: opts[:entity],
      config: opts[:config],
      extras: opts[:extras],
      position: position,
      scale: scale,
      rotation: rotation,
      children: opts[:children] || []
    }
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp extract_nodes({:__block__, _, statements}) do
    Enum.map(statements, &wrap_node_call/1)
  end

  defp extract_nodes(single_statement) do
    [wrap_node_call(single_statement)]
  end

  defp wrap_node_call({:node, meta, args}) do
    {:node, meta, args}
  end

  defp wrap_node_call(other) do
    other
  end

  defp validate_vec3(nil, _field), do: nil

  defp validate_vec3({x, y, z}, _field) when is_number(x) and is_number(y) and is_number(z),
    do: {x, y, z}

  defp validate_vec3([x, y, z], _field) when is_number(x) and is_number(y) and is_number(z),
    do: {x, y, z}

  defp validate_vec3(other, field) do
    raise ArgumentError, "#{field} must be {x, y, z} or [x, y, z], got: #{inspect(other)}"
  end

  defp validate_quat(nil, _field), do: nil

  defp validate_quat({x, y, z, w}, _field)
       when is_number(x) and is_number(y) and is_number(z) and is_number(w),
       do: {x, y, z, w}

  defp validate_quat([x, y, z, w], _field)
       when is_number(x) and is_number(y) and is_number(z) and is_number(w),
       do: {x, y, z, w}

  defp validate_quat(other, field) do
    raise ArgumentError, "#{field} must be {x, y, z, w} or [x, y, z, w], got: #{inspect(other)}"
  end
end
