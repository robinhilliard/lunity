defmodule Lunity.Scene do
  @moduledoc """
  Scene module definition for compiled scene files.

  Use `use Lunity.Scene` to define a scene as a compiled `.ex` module with
  full IDE support (go-to-definition, autocomplete, undefined-module warnings).

  ## Example

      defmodule Pong.Scenes.PongArena do
        use Lunity.Scene

        scene do
          node :floor,    prefab: Pong.Prefabs.Box, position: {0, 0, -1}, scale: {12, 6, 0.3}
          node :wall_top, prefab: Pong.Prefabs.Box, position: {0, 9.5, 0.15}, scale: {12, 0.3, 0.5}
        end
      end

  Scene modules generate a `__scene_def__/0` function that returns the
  `%Lunity.Scene.Def{}` struct. SceneLoader resolves scene modules via this
  function.

  Scenes can reference other scenes for Godot-style composition:

      defmodule Pong.Scenes.Level1 do
        use Lunity.Scene

        scene do
          node :arena, scene: Pong.Scenes.PongArena
          node :ball,  prefab: Pong.Prefabs.Box, entity: Pong.Ball,
                       position: {0, 0, 0.5}, scale: {0.4, 0.4, 0.4}
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Lunity.Scene.DSL, only: [scene: 1, node: 1, node: 2]
      Module.register_attribute(__MODULE__, :lunity_scene_def, [])
      @before_compile Lunity.Scene
    end
  end

  defmacro __before_compile__(env) do
    scene_def = Module.get_attribute(env.module, :lunity_scene_def)

    if scene_def do
      quote do
        @doc false
        def __scene_def__, do: @lunity_scene_def
      end
    else
      quote do
        @doc false
        def __scene_def__, do: nil
      end
    end
  end

  @doc """
  Returns the scene definition for a scene module, or nil.
  """
  def scene_def(module) do
    if function_exported?(module, :__scene_def__, 0) do
      module.__scene_def__()
    else
      nil
    end
  end
end
