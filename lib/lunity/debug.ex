defmodule Lunity.Debug do
  @moduledoc """
  Debug drawing utilities for editor and development overlays.

  Draws lines, rays, bounds, unit grids, and a procedural skybox using EAGL.Line
  and custom shaders. All functions require `view` and `projection` matrices from
  the active camera.

  ## Usage

      view = EAGL.Camera.get_view_matrix(camera)
      proj = EAGL.Camera.get_projection_matrix(camera, aspect)

      Lunity.Debug.draw_skybox(view, proj)
      # ... render scene ...
      Lunity.Debug.draw_grid_xz(view, proj, extent: 20)
      Lunity.Debug.draw_bounds(scene_bounds, view, proj)
  """

  use EAGL.Const
  import EAGL.Math

  @default_ray_length 100.0
  @default_grid_extent 10
  @default_grid_center {0.0, 0.0, 0.0}
  @white vec3(1.0, 1.0, 1.0)
  @grid_color vec3(0.4, 0.4, 0.4)

  # ---------------------------------------------------------------------------
  # Thin wrappers (call EAGL.Line)
  # ---------------------------------------------------------------------------

  @doc """
  Draw a line from `from` to `to` in world space.

  Forwards to `EAGL.Line.draw_line/5`.
  """
  @spec draw_line(
          EAGL.Math.vec3(),
          EAGL.Math.vec3(),
          EAGL.Math.mat4(),
          EAGL.Math.mat4(),
          EAGL.Math.vec3()
        ) :: :ok
  def draw_line(from, to, view, proj, color \\ @white) do
    EAGL.Line.draw_line(from, to, view, proj, color)
  end

  @doc """
  Draw a ray from `origin` along `direction`.

  ## Options

  - `:length` - Visual length of the ray (default: 100.0)
  - `:color` - Line color (default: white)
  """
  @spec draw_ray(
          EAGL.Math.vec3(),
          EAGL.Math.vec3(),
          EAGL.Math.mat4(),
          EAGL.Math.mat4(),
          keyword()
        ) :: :ok
  def draw_ray(origin, direction, view, proj, opts \\ []) do
    length = Keyword.get(opts, :length, @default_ray_length)
    color = Keyword.get(opts, :color, @white)
    dir_norm = normalize(direction)
    to = vec_add(origin, vec_scale(dir_norm, length))
    EAGL.Line.draw_line(origin, to, view, proj, color)
  end

  @doc """
  Draw the 12 edges of an AABB (axis-aligned bounding box).

  Accepts:
  - `{{min_x, min_y, min_z}, {max_x, max_y, max_z}}`
  - `{:ok, {min_x, min_y, min_z}, {max_x, max_y, max_z}}` (from `EAGL.Scene.bounds/1`)

  Returns `:ok` or `:no_bounds` if the input is `:no_bounds`.
  """
  @spec draw_bounds(
          {{float(), float(), float()}, {float(), float(), float()}}
          | {:ok, {float(), float(), float()}, {float(), float(), float()}}
          | :no_bounds,
          EAGL.Math.mat4(),
          EAGL.Math.mat4(),
          EAGL.Math.vec3()
        ) :: :ok | :no_bounds
  def draw_bounds(aabb, view, proj, color \\ @white)

  def draw_bounds(:no_bounds, _view, _proj, _color), do: :no_bounds

  def draw_bounds({:ok, min_pt, max_pt}, view, proj, color) do
    draw_bounds({min_pt, max_pt}, view, proj, color)
  end

  def draw_bounds({{min_x, min_y, min_z}, {max_x, max_y, max_z}}, view, proj, color) do
    # 8 corners
    c0 = vec3(min_x, min_y, min_z)
    c1 = vec3(max_x, min_y, min_z)
    c2 = vec3(min_x, max_y, min_z)
    c3 = vec3(max_x, max_y, min_z)
    c4 = vec3(min_x, min_y, max_z)
    c5 = vec3(max_x, min_y, max_z)
    c6 = vec3(min_x, max_y, max_z)
    c7 = vec3(max_x, max_y, max_z)

    # 12 edges: bottom (4), top (4), vertical (4)
    lines = [
      {c0, c1},
      {c0, c2},
      {c1, c3},
      {c2, c3},
      {c4, c5},
      {c4, c6},
      {c5, c7},
      {c6, c7},
      {c0, c4},
      {c1, c5},
      {c2, c6},
      {c3, c7}
    ]

    EAGL.Line.draw_lines(lines, view, proj, color)
  end

  # ---------------------------------------------------------------------------
  # Unit grids
  # ---------------------------------------------------------------------------

  @doc """
  Draw a 1-unit grid on the XY plane.

  ## Options

  - `:center` - Center point `{x, y, z}` (default: `{0, 0, 0}`)
  - `:extent` - Half-size of grid (default: 10)
  """
  @spec draw_grid_xy(EAGL.Math.mat4(), EAGL.Math.mat4(), keyword()) :: :ok
  def draw_grid_xy(view, proj, opts \\ []) do
    {cx, cy, cz} = Keyword.get(opts, :center, @default_grid_center)
    extent = Keyword.get(opts, :extent, @default_grid_extent)
    color = Keyword.get(opts, :color, @grid_color)

    lines =
      grid_lines_xy(cx, cy, cz, extent)

    EAGL.Line.draw_lines(lines, view, proj, color)
  end

  @doc """
  Draw a 1-unit grid on the YZ plane.

  ## Options

  - `:center` - Center point `{x, y, z}` (default: `{0, 0, 0}`)
  - `:extent` - Half-size of grid (default: 10)
  """
  @spec draw_grid_yz(EAGL.Math.mat4(), EAGL.Math.mat4(), keyword()) :: :ok
  def draw_grid_yz(view, proj, opts \\ []) do
    {cx, cy, cz} = Keyword.get(opts, :center, @default_grid_center)
    extent = Keyword.get(opts, :extent, @default_grid_extent)
    color = Keyword.get(opts, :color, @grid_color)

    lines = grid_lines_yz(cx, cy, cz, extent)
    EAGL.Line.draw_lines(lines, view, proj, color)
  end

  @doc """
  Draw a 1-unit grid on the XZ plane (ground plane).

  ## Options

  - `:center` - Center point `{x, y, z}` (default: `{0, 0, 0}`)
  - `:extent` - Half-size of grid (default: 10)
  """
  @spec draw_grid_xz(EAGL.Math.mat4(), EAGL.Math.mat4(), keyword()) :: :ok
  def draw_grid_xz(view, proj, opts \\ []) do
    {cx, cy, cz} = Keyword.get(opts, :center, @default_grid_center)
    extent = Keyword.get(opts, :extent, @default_grid_extent)
    color = Keyword.get(opts, :color, @grid_color)

    lines = grid_lines_xz(cx, cy, cz, extent)
    EAGL.Line.draw_lines(lines, view, proj, color)
  end

  defp grid_lines_xy(cx, cy, cz, extent) do
    # Lines parallel to X: varying x, fixed y
    lines_y =
      for i <- -extent..extent do
        y = cy + i * 1.0
        {vec3(cx - extent, y, cz), vec3(cx + extent, y, cz)}
      end

    # Lines parallel to Y: varying y, fixed x
    lines_x =
      for i <- -extent..extent do
        x = cx + i * 1.0
        {vec3(x, cy - extent, cz), vec3(x, cy + extent, cz)}
      end

    lines_y ++ lines_x
  end

  defp grid_lines_yz(cx, cy, cz, extent) do
    # Lines parallel to Y: varying y, fixed z
    lines_z =
      for i <- -extent..extent do
        z = cz + i * 1.0
        {vec3(cx, cy - extent, z), vec3(cx, cy + extent, z)}
      end

    # Lines parallel to Z: varying z, fixed y
    lines_y =
      for i <- -extent..extent do
        y = cy + i * 1.0
        {vec3(cx, y, cz - extent), vec3(cx, y, cz + extent)}
      end

    lines_z ++ lines_y
  end

  defp grid_lines_xz(cx, cy, cz, extent) do
    # Lines parallel to X: varying x, fixed z
    lines_z =
      for i <- -extent..extent do
        z = cz + i * 1.0
        {vec3(cx - extent, cy, z), vec3(cx + extent, cy, z)}
      end

    # Lines parallel to Z: varying z, fixed x
    lines_x =
      for i <- -extent..extent do
        x = cx + i * 1.0
        {vec3(x, cy, cz - extent), vec3(x, cy, cz + extent)}
      end

    lines_z ++ lines_x
  end

  # ---------------------------------------------------------------------------
  # Skybox
  # ---------------------------------------------------------------------------

  @doc """
  Draw a procedural skybox: sky blue (+Y) blending to dark gray at XZ horizon.

  Right-handed XYZ, Y up. Horizon is the XZ plane. Rendered first (or with depth
  write disabled) so the scene draws in front.
  """
  @spec draw_skybox(EAGL.Math.mat4(), EAGL.Math.mat4()) :: :ok
  def draw_skybox(view, proj) do
    # Use view matrix with translation zeroed so skybox stays centered on camera
    view_rot = strip_translation(view)
    draw_skybox_cube(view_rot, proj)
  end

  defp strip_translation([
         {m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, _m12, _m13, _m14, m15}
       ]) do
    # Column-major: translation is in elements 12,13,14. Set to 0 for skybox (stays at camera).
    [{m0, m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, 0.0, 0.0, 0.0, m15}]
  end

  defp draw_skybox_cube(view, proj) do
    # Cube vertices: 8 corners at ±1, 36 vertices for 12 triangles (2 per face)
    # Each face: 2 triangles, 6 vertices. Position = direction from center.
    # Order: front(+z), back(-z), right(+x), left(-x), top(+y), bottom(-y)
    vertices = skybox_cube_vertices()
    indices = skybox_cube_indices()

    {vao, vbo, ebo} =
      EAGL.Buffer.create_indexed_array(
        vertices,
        indices,
        [EAGL.Buffer.position_attribute()],
        usage: @gl_static_draw
      )

    program = get_skybox_program()
    :gl.useProgram(program)
    EAGL.Shader.set_uniform(program, "view", view)
    EAGL.Shader.set_uniform(program, "projection", proj)

    # Disable depth write so scene draws in front
    :gl.depthMask(@gl_false)
    :gl.bindVertexArray(vao)
    :gl.drawElements(@gl_triangles, 36, @gl_unsigned_int, 0)
    :gl.bindVertexArray(0)
    :gl.depthMask(@gl_true)

    EAGL.Buffer.delete_indexed_array(vao, vbo, ebo)
    :ok
  end

  defp skybox_cube_vertices do
    # 8 corners: (x,y,z) as float list for interleaved position-only
    # Front face (z=+1): 0,1,2,3 -> 4,5,6,7 in indices
    # Vertices: 0=(-1,-1,-1), 1=(+1,-1,-1), 2=(-1,+1,-1), 3=(+1,+1,-1), 4=(-1,-1,+1), 5=(+1,-1,+1), 6=(-1,+1,+1), 7=(+1,+1,+1)
    [
      # 0
      -1.0,
      -1.0,
      -1.0,
      # 1
      1.0,
      -1.0,
      -1.0,
      # 2
      -1.0,
      1.0,
      -1.0,
      # 3
      1.0,
      1.0,
      -1.0,
      # 4
      -1.0,
      -1.0,
      1.0,
      # 5
      1.0,
      -1.0,
      1.0,
      # 6
      -1.0,
      1.0,
      1.0,
      # 7
      1.0,
      1.0,
      1.0
    ]
  end

  defp skybox_cube_indices do
    # 12 triangles, 36 indices. CCW for front faces (outward normals).
    # Back (-z): 0,1,2, 1,3,2
    # Front (+z): 5,4,7, 4,6,7
    # Left (-x): 4,0,6, 0,2,6
    # Right (+x): 1,5,3, 5,7,3
    # Bottom (-y): 0,4,1, 4,5,1
    # Top (+y): 2,3,6, 3,7,6
    [
      0,
      1,
      2,
      1,
      3,
      2,
      5,
      4,
      7,
      4,
      6,
      7,
      4,
      0,
      6,
      0,
      2,
      6,
      1,
      5,
      3,
      5,
      7,
      3,
      0,
      4,
      1,
      4,
      5,
      1,
      2,
      3,
      6,
      3,
      7,
      6
    ]
  end

  defp get_skybox_program do
    case Process.get(:lunity_skybox_program) do
      nil ->
        vs_code = skybox_vertex_code()
        fs_code = skybox_fragment_code()

        {:ok, vs} = EAGL.Shader.create_shader_from_source(@gl_vertex_shader, vs_code, "skybox_vs")

        {:ok, fs} =
          EAGL.Shader.create_shader_from_source(@gl_fragment_shader, fs_code, "skybox_fs")

        {:ok, program} = EAGL.Shader.create_attach_link([vs, fs])
        Process.put(:lunity_skybox_program, program)
        program

      program ->
        program
    end
  end

  defp skybox_vertex_code do
    """
    #version 330 core
    layout (location = 0) in vec3 aPos;

    out vec3 WorldDir;

    uniform mat4 view;
    uniform mat4 projection;

    void main() {
        WorldDir = aPos;
        vec4 clipPos = projection * view * vec4(aPos, 1.0);
        gl_Position = clipPos.xyww;
    }
    """
  end

  defp skybox_fragment_code do
    """
    #version 330 core
    out vec4 FragColor;

    in vec3 WorldDir;

    void main() {
        vec3 dir = normalize(WorldDir);
        float t = smoothstep(-0.2, 0.5, dir.y);
        vec3 skyBlue = vec3(0.53, 0.81, 0.98);
        vec3 horizonGray = vec3(0.4, 0.4, 0.45);
        FragColor = vec4(mix(horizonGray, skyBlue, t), 1.0);
    }
    """
  end
end
