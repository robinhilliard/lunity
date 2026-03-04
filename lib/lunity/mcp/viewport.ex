defmodule Lunity.MCP.Viewport do
  @moduledoc """
  Viewport and screen-space utilities for Phase 6d MCP tools.

  World-to-screen projection for node_screen_bounds.
  """
  import EAGL.Math

  @doc """
  Project a world-space point to screen coordinates.

  Uses view and projection matrices. Returns {screen_x, screen_y} in pixels.
  Screen origin is bottom-left (OpenGL convention). Returns nil if point
  is behind the camera (z clip > 1).
  """
  @spec world_to_screen(
          EAGL.Math.vec3(),
          EAGL.Math.mat4(),
          EAGL.Math.mat4(),
          {number(), number(), number(), number()}
        ) :: {float(), float()} | nil
  def world_to_screen(world_point, view_matrix, proj_matrix, {vp_x, vp_y, vp_w, vp_h}) do
    # world * view * proj -> clip space
    vp = mat4_transform_point(mat4_mul(proj_matrix, view_matrix), world_point)
    [{x, y, z}] = vp

    # Behind camera
    if z > 1.0 or z < -1.0 do
      nil
    else
      # NDC to screen (bottom-left origin)
      screen_x = (x + 1.0) * 0.5 * vp_w + vp_x
      screen_y = (y + 1.0) * 0.5 * vp_h + vp_y
      {screen_x, screen_y}
    end
  end

  @doc """
  Get the 2D screen bounds (axis-aligned rect) for a node's world position.

  Returns %{x, y, width, height} or nil if behind camera.
  For a single point we return a minimal rect (e.g. 1x1 pixel).
  """
  @spec node_screen_bounds(
          EAGL.Node.t(),
          EAGL.OrbitCamera.t() | EAGL.Camera.t(),
          {number(), number(), number(), number()}
        ) :: %{x: float(), y: float(), width: float(), height: float()} | nil
  def node_screen_bounds(node, camera, viewport) do
    world = EAGL.Node.get_world_transform_matrix(node)
    origin = mat4_transform_point(world, vec3(0.0, 0.0, 0.0))

    view_matrix = get_view_matrix(camera)
    aspect = elem(viewport, 2) / max(elem(viewport, 3), 1)
    proj_matrix = get_projection_matrix(camera, aspect)

    case world_to_screen(origin, view_matrix, proj_matrix, viewport) do
      {sx, sy} ->
        %{x: sx, y: sy, width: 1.0, height: 1.0}

      nil ->
        nil
    end
  end

  defp get_view_matrix(camera) do
    case camera do
      %EAGL.Camera{} -> EAGL.Camera.get_view_matrix(camera)
      %EAGL.OrbitCamera{} -> EAGL.OrbitCamera.get_view_matrix(camera)
    end
  end

  defp get_projection_matrix(camera, aspect) do
    case camera do
      %EAGL.Camera{} -> EAGL.Camera.get_projection_matrix(camera, aspect)
      %EAGL.OrbitCamera{} -> EAGL.OrbitCamera.get_projection_matrix(camera, aspect)
    end
  end
end
