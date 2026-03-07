defmodule Lunity.Editor.View do
  @moduledoc """
  Quad-viewport editor view for Lunity.

  Renders four viewports in a single GL canvas:
  - Top-left: Top (orthographic, looking down Y)
  - Top-right: Perspective (orbit camera)
  - Bottom-left: Front (orthographic, looking along Z)
  - Bottom-right: Right (orthographic, looking along X)

  Dividers between viewports are draggable. Mouse events are routed
  to the viewport the cursor is over.
  """
  use EAGL.Window
  use EAGL.Const
  use WX.Const

  import Bitwise
  import EAGL.Math
  alias EAGL.Scene
  alias EAGL.Node
  alias Lunity.Editor.State
  alias Lunity.Editor.HierarchyTree
  alias Lunity.PrefabLoader
  alias Lunity.SceneLoader

  @divider_hit_zone 5
  @split_min 0.15
  @split_max 0.85

  def run(opts \\ []) do
    default_opts = [
      depth_testing: true,
      size: {1024, 768},
      enter_to_exit: true
    ]

    EAGL.Window.run(
      __MODULE__,
      "Lunity Editor",
      Keyword.merge(default_opts, opts)
    )
  end

  @impl true
  def setup_layout(frame, gl_canvas) do
    sizer = :wxBoxSizer.new(@wx_horizontal)

    tree = HierarchyTree.create(frame)
    :wxSizer.add(sizer, tree, proportion: 0, flag: @wx_expand)
    :wxSizer.add(sizer, gl_canvas, proportion: 1, flag: @wx_expand)

    State.put_frame(frame)

    sizer
  end

  @impl true
  def setup do
    State.init()

    with {:ok, program} <- GLTF.EAGL.create_pbr_shader() do
      orbit = EAGL.OrbitCamera.new()

      state = %{
        program: program,
        orbit: orbit,
        cam_top: EAGL.OrthoCamera.new(axis: :top),
        cam_front: EAGL.OrthoCamera.new(axis: :front),
        cam_right: EAGL.OrthoCamera.new(axis: :right),
        h_split: 0.5,
        v_split: 0.5,
        dragging: nil,
        active_viewport: :perspective,
        tried_default: false,
        load_retries: 0,
        frame: 0,
        last_w: 1024.0,
        last_h: 768.0,
        tree_scene_path: nil,
        tree_project_done: false,
        click_origin: nil,
        hover_pos: nil
      }

      {:ok, state}
    end
  end

  @impl true
  def render(w, h, state) do
    state = %{state | frame: Map.get(state, :frame, 0) + 1, last_w: w, last_h: h}
    state = apply_orbit_command(state)
    state = maybe_load_default_scene(state)
    state = process_load_command(state)
    state = maybe_refresh_tree(state)
    State.put_viewport(w, h)
    state = process_capture_request(state, w, h)
    state = process_pick_request(state, w, h)
    update_hover(state)

    :gl.clearColor(0.1, 0.1, 0.12, 1.0)
    :gl.clear(@gl_color_buffer_bit ||| @gl_depth_buffer_bit)
    :gl.enable(@gl_cull_face)
    :gl.cullFace(@gl_back)
    :gl.enable(@gl_scissor_test)

    rects = viewport_rects(w, h, state.h_split, state.v_split)

    state = render_viewport(state, :top, rects.top_left, w, h, 0.18, 0.18, 0.22)
    state = render_viewport(state, :perspective, rects.top_right, w, h, 0.15, 0.15, 0.2)
    state = render_viewport(state, :front, rects.bottom_left, w, h, 0.18, 0.18, 0.22)
    state = render_viewport(state, :right, rects.bottom_right, w, h, 0.18, 0.18, 0.22)

    :gl.disable(@gl_scissor_test)

    sync_orbit_to_ets(state)
    {:ok, state}
  end

  # --- Viewport rendering ---

  defp render_viewport(state, viewport_id, {vx, vy, vw, vh}, _w, _h, cr, cg, cb) do
    vx = trunc(vx)
    vy = trunc(vy)
    vw = trunc(vw)
    vh = trunc(vh)

    if vw > 0 and vh > 0 do
      :gl.viewport(vx, vy, vw, vh)
      :gl.scissor(vx, vy, vw, vh)
      :gl.clearColor(cr, cg, cb, 1.0)
      :gl.clear(@gl_color_buffer_bit ||| @gl_depth_buffer_bit)

      :gl.useProgram(state.program)

      {view, proj, view_pos} = camera_matrices(state, viewport_id, vw, vh)

      GLTF.EAGL.set_pbr_uniforms(state.program,
        view_pos: view_pos,
        skip_lights: true
      )

      case State.get_scene() do
        %Scene{} = scene ->
          Scene.render(scene, view, proj)
          render_selection_highlight(scene, view, proj)

        nil ->
          :ok
      end
    end

    state
  end

  defp render_selection_highlight(_scene, view, proj) do
    sel = State.get_selection()
    hover = State.get_hover()

    :gl.disable(@gl_depth_test)

    case hover do
      {:scene_node, hname, {hmin, hmax}} ->
        sel_name = case sel do
          {:scene_node, n, _} -> n
          _ -> nil
        end

        unless hname == sel_name do
          EAGL.Line.draw_aabb(hmin, hmax, view, proj, vec3(0.5, 0.4, 0.15))
        end

      _ -> :ok
    end

    case sel do
      {:scene_node, _name, {min_pt, max_pt}} ->
        EAGL.Line.draw_aabb(min_pt, max_pt, view, proj, vec3(1.0, 0.7, 0.2))

      _ -> :ok
    end

    :gl.enable(@gl_depth_test)
  end

  @doc false
  def subtree_world_aabb(node, world_matrix) do
    collect_mesh_aabbs_at(node, world_matrix)
    |> case do
      [] -> nil
      aabbs -> Enum.reduce(aabbs, &merge_aabb/2)
    end
  end

  defp collect_mesh_aabbs_at(node, world) do

    own =
      case Node.get_mesh(node) do
        %{bounds: {min_pt, max_pt}} ->
          [transform_aabb(min_pt, max_pt, world)]

        _ ->
          []
      end

    children_aabbs =
      (node.children || [])
      |> Enum.flat_map(fn child ->
        child_local = Node.get_local_transform_matrix(child)
        child_world = mat4_mul(world, child_local)
        collect_mesh_aabbs_at(child, child_world)
      end)

    own ++ children_aabbs
  end

  defp transform_aabb({min_x, min_y, min_z}, {max_x, max_y, max_z}, world) do
    corners = [
      [{min_x, min_y, min_z}], [{max_x, min_y, min_z}],
      [{min_x, max_y, min_z}], [{max_x, max_y, min_z}],
      [{min_x, min_y, max_z}], [{max_x, min_y, max_z}],
      [{min_x, max_y, max_z}], [{max_x, max_y, max_z}]
    ]

    transformed = Enum.map(corners, &mat4_transform_point(world, &1))
    [{fx, fy, fz}] = hd(transformed)
    rest = Enum.flat_map(tl(transformed), fn [{x, y, z}] -> [{x, y, z}] end)

    {t_min, t_max} =
      Enum.reduce(rest, {{fx, fy, fz}, {fx, fy, fz}}, fn {x, y, z},
                                                          {{ax, ay, az}, {bx, by, bz}} ->
        {{min(ax, x), min(ay, y), min(az, z)}, {max(bx, x), max(by, y), max(bz, z)}}
      end)

    {t_min, t_max}
  end

  defp merge_aabb({min_a, max_a}, {min_b, max_b}) do
    {ax, ay, az} = min_a
    {bx, by, bz} = min_b
    {cx, cy, cz} = max_a
    {dx, dy, dz} = max_b
    {{min(ax, bx), min(ay, by), min(az, bz)}, {max(cx, dx), max(cy, dy), max(cz, dz)}}
  end

  defp camera_matrices(state, :perspective, vw, vh) do
    orbit = state.orbit
    view = EAGL.OrbitCamera.get_view_matrix(orbit)
    proj = EAGL.OrbitCamera.get_projection_matrix(orbit, vw / max(vh, 1))
    pos = EAGL.OrbitCamera.get_position(orbit)
    {view, proj, pos}
  end

  defp camera_matrices(state, :top, vw, vh) do
    cam = state.cam_top
    view = EAGL.OrthoCamera.get_view_matrix(cam)
    proj = EAGL.OrthoCamera.get_projection_matrix(cam, vw / max(vh, 1))
    pos = EAGL.OrthoCamera.get_position(cam)
    {view, proj, pos}
  end

  defp camera_matrices(state, :front, vw, vh) do
    cam = state.cam_front
    view = EAGL.OrthoCamera.get_view_matrix(cam)
    proj = EAGL.OrthoCamera.get_projection_matrix(cam, vw / max(vh, 1))
    pos = EAGL.OrthoCamera.get_position(cam)
    {view, proj, pos}
  end

  defp camera_matrices(state, :right, vw, vh) do
    cam = state.cam_right
    view = EAGL.OrthoCamera.get_view_matrix(cam)
    proj = EAGL.OrthoCamera.get_projection_matrix(cam, vw / max(vh, 1))
    pos = EAGL.OrthoCamera.get_position(cam)
    {view, proj, pos}
  end

  # --- Viewport geometry ---

  defp viewport_rects(w, h, h_split, v_split) do
    split_x = w * h_split
    split_y = h * v_split

    %{
      top_left: {0, split_y, split_x, h - split_y},
      top_right: {split_x, split_y, w - split_x, h - split_y},
      bottom_left: {0, 0, split_x, split_y},
      bottom_right: {split_x, 0, w - split_x, split_y}
    }
  end

  defp viewport_at(x, y, w, h, h_split, v_split) do
    split_x = w * h_split
    split_y = h * (1.0 - v_split)

    cond do
      x < split_x and y < split_y -> :top
      x >= split_x and y < split_y -> :perspective
      x < split_x and y >= split_y -> :front
      true -> :right
    end
  end

  # --- Event handling ---

  @impl true
  def handle_event({:tick, _dt}, state) do
    {:ok, state}
  end

  def handle_event({:mouse_motion, x, y}, state) do
    state = handle_motion(state, x, y)
    state = %{state | hover_pos: {x, y}}
    {:ok, state}
  end

  def handle_event({:mouse_down, x, y}, state) do
    state = %{state | click_origin: {x, y}}
    state = handle_press(state, :left, x, y)
    {:ok, state}
  end

  def handle_event({:mouse_up, x, y}, state) do
    state = maybe_pick_at(state, x, y)
    state = handle_release(state, :left)
    {:ok, state}
  end

  def handle_event({:middle_down, x, y}, state) do
    state = handle_press(state, :middle, x, y)
    {:ok, state}
  end

  def handle_event({:middle_up, _x, _y}, state) do
    state = handle_release(state, :middle)
    {:ok, state}
  end

  def handle_event({:mouse_wheel, x, y, wheel_rotation, _wd}, state) do
    scroll_delta = wheel_rotation / 120.0
    vp = viewport_at(x, y, state.last_w, state.last_h, state.h_split, state.v_split)
    state = route_scroll(state, vp, scroll_delta)
    {:ok, state}
  end

  def handle_event({:wx_event, {:wxTree, :command_tree_sel_changed, item, _, _}}, state) do
    case State.get_tree() do
      {tree, _, _, _} -> HierarchyTree.handle_selection(tree, item)
      _ -> nil
    end

    {:ok, state}
  end

  def handle_event({:wx_event, {:wxTree, :command_tree_item_activated, item, _, _}}, state) do
    case State.get_tree() do
      {tree, _, _, _} -> HierarchyTree.handle_activation(tree, item)
      _ -> nil
    end

    {:ok, state}
  end

  def handle_event(_event, state), do: {:ok, state}

  # --- Click-to-select via GPU pick ---

  @click_threshold 4

  defp maybe_pick_at(%{click_origin: {ox, oy}} = state, x, y) do
    if abs(x - ox) < @click_threshold and abs(y - oy) < @click_threshold do
      do_viewport_pick(state, x, y)
    else
      state
    end
  end

  defp maybe_pick_at(state, _x, _y), do: state

  defp do_viewport_pick(state, x, y) do
    case pick_at(state, x, y) do
      {:ok, _node, world} ->
        scene = State.get_scene()
        {dsl_name, dsl_aabb} = resolve_dsl_node(scene, world)

        if dsl_name && dsl_aabb do
          State.put_selection({:scene_node, dsl_name, dsl_aabb})
          HierarchyTree.select_by_name(dsl_name)
        end

        state

      nil ->
        State.put_selection(nil)
        state
    end
  end

  defp update_hover(%{hover_pos: {x, y}, dragging: nil} = state) do
    case pick_at(state, x, y) do
      {:ok, _node, world} ->
        scene = State.get_scene()
        {dsl_name, dsl_aabb} = resolve_dsl_node(scene, world)

        if dsl_name && dsl_aabb do
          State.put_hover({:scene_node, dsl_name, dsl_aabb})
          HierarchyTree.hover_by_name(dsl_name)
        end

      nil ->
        case HierarchyTree.poll_hover() do
          {:scene_node, _, _} = hover -> State.put_hover(hover)
          _ ->
            State.put_hover(nil)
            HierarchyTree.hover_by_name(nil)
        end
    end
  end

  defp update_hover(_state) do
    case HierarchyTree.poll_hover() do
      {:scene_node, _, _} = hover -> State.put_hover(hover)
      _ ->
        State.put_hover(nil)
        HierarchyTree.hover_by_name(nil)
    end
  end

  defp pick_at(state, x, y) do
    scene = State.get_scene()
    if scene == nil, do: throw(:no_scene)

    w = state.last_w
    h = state.last_h
    vp_id = viewport_at(x, y, w, h, state.h_split, state.v_split)
    camera = camera_for_viewport(state, vp_id)
    rects = viewport_rects(w, h, state.h_split, state.v_split)
    {_vp_x, _vp_y, vp_w, vp_h} = viewport_rect_for(rects, vp_id)

    {wx_left, wx_top} = wx_viewport_origin(vp_id, w, h, state.h_split, state.v_split)
    local_x = x - wx_left
    local_y = y - wx_top
    viewport = {0, 0, trunc(vp_w), trunc(vp_h)}

    Scene.pick(scene, camera, viewport, local_x, local_y)
  catch
    :no_scene -> nil
  end

  defp resolve_dsl_node(nil, _world), do: {nil, nil}

  defp resolve_dsl_node(scene, picked_world) do
    dsl_roots = unwrap_scene_root(scene.root_nodes || [])

    result =
      Enum.find_value(dsl_roots, fn root ->
        root_local = Node.get_local_transform_matrix(root)

        if has_mesh_descendant_at?(root, root_local, picked_world) do
          aabb = subtree_world_aabb(root, root_local)
          {root.name, aabb}
        end
      end)

    result || {nil, nil}
  end

  defp has_mesh_descendant_at?(node, world, target) do
    if Node.get_mesh(node) != nil and world == target do
      true
    else
      (node.children || [])
      |> Enum.any?(fn child ->
        child_world = mat4_mul(world, Node.get_local_transform_matrix(child))
        has_mesh_descendant_at?(child, child_world, target)
      end)
    end
  end

  defp unwrap_scene_root([%{name: "scene_root", children: children}]) when is_list(children),
    do: children

  defp unwrap_scene_root(nodes), do: nodes

  defp wx_viewport_origin(:top, _w, _h, _h_split, _v_split), do: {0, 0}
  defp wx_viewport_origin(:perspective, w, _h, h_split, _v_split), do: {w * h_split, 0}
  defp wx_viewport_origin(:front, _w, h, _h_split, v_split), do: {0, h * (1.0 - v_split)}
  defp wx_viewport_origin(:right, w, h, h_split, v_split), do: {w * h_split, h * (1.0 - v_split)}

  defp camera_for_viewport(state, :perspective), do: state.orbit
  defp camera_for_viewport(state, :top), do: state.cam_top
  defp camera_for_viewport(state, :front), do: state.cam_front
  defp camera_for_viewport(state, :right), do: state.cam_right

  defp viewport_rect_for(rects, :top), do: rects.top_left
  defp viewport_rect_for(rects, :perspective), do: rects.top_right
  defp viewport_rect_for(rects, :front), do: rects.bottom_left
  defp viewport_rect_for(rects, :right), do: rects.bottom_right

  # --- Input routing ---

  defp handle_press(state, button, x, y) do
    w = state.last_w
    h = state.last_h

    case divider_hit(x, y, w, h, state.h_split, state.v_split) do
      :h ->
        %{state | dragging: :h}

      :v ->
        %{state | dragging: :v}

      :both ->
        %{state | dragging: :both}

      nil ->
        vp = viewport_at(x, y, w, h, state.h_split, state.v_split)
        state = %{state | active_viewport: vp}
        route_press(state, vp, button, x, y)
    end
  end

  defp handle_release(state, button) do
    if state.dragging do
      %{state | dragging: nil}
    else
      route_release(state, state.active_viewport, button)
    end
  end

  defp handle_motion(state, x, y) do
    if state.dragging do
      drag_divider(state, x, y)
    else
      route_motion(state, state.active_viewport, x, y)
    end
  end

  # --- Divider dragging ---

  defp divider_hit(x, y, w, h, h_split, v_split) do
    split_x = w * h_split
    split_y = h * (1.0 - v_split)
    near_h = abs(x - split_x) < @divider_hit_zone
    near_v = abs(y - split_y) < @divider_hit_zone

    cond do
      near_h and near_v -> :both
      near_h -> :h
      near_v -> :v
      true -> nil
    end
  end

  defp drag_divider(state, x, y) do
    w = state.last_w
    h = state.last_h

    state =
      if state.dragging in [:h, :both] do
        new_h = clamp(x / max(w, 1), @split_min, @split_max)
        %{state | h_split: new_h}
      else
        state
      end

    if state.dragging in [:v, :both] do
      new_v = clamp(1.0 - y / max(h, 1), @split_min, @split_max)
      %{state | v_split: new_v}
    else
      state
    end
  end

  # --- Camera event routing ---

  defp route_press(state, :perspective, :left, x, y) do
    orbit = state.orbit |> Map.put(:last_mouse, {x, y}) |> EAGL.OrbitCamera.handle_mouse_down()
    %{state | orbit: orbit}
  end

  defp route_press(state, :perspective, :middle, x, y) do
    orbit = state.orbit |> Map.put(:last_mouse, {x, y}) |> EAGL.OrbitCamera.handle_middle_down()
    %{state | orbit: orbit}
  end

  defp route_press(state, :top, button, x, y) when button in [:left, :middle] do
    cam = state.cam_top |> Map.put(:last_mouse, {x, y}) |> EAGL.OrthoCamera.handle_mouse_down()
    %{state | cam_top: cam}
  end

  defp route_press(state, :front, button, x, y) when button in [:left, :middle] do
    cam = state.cam_front |> Map.put(:last_mouse, {x, y}) |> EAGL.OrthoCamera.handle_mouse_down()
    %{state | cam_front: cam}
  end

  defp route_press(state, :right, button, x, y) when button in [:left, :middle] do
    cam = state.cam_right |> Map.put(:last_mouse, {x, y}) |> EAGL.OrthoCamera.handle_mouse_down()
    %{state | cam_right: cam}
  end

  defp route_release(state, :perspective, :left) do
    %{state | orbit: EAGL.OrbitCamera.handle_mouse_up(state.orbit)}
  end

  defp route_release(state, :perspective, :middle) do
    %{state | orbit: EAGL.OrbitCamera.handle_middle_up(state.orbit)}
  end

  defp route_release(state, :top, _button) do
    %{state | cam_top: EAGL.OrthoCamera.handle_mouse_up(state.cam_top)}
  end

  defp route_release(state, :front, _button) do
    %{state | cam_front: EAGL.OrthoCamera.handle_mouse_up(state.cam_front)}
  end

  defp route_release(state, :right, _button) do
    %{state | cam_right: EAGL.OrthoCamera.handle_mouse_up(state.cam_right)}
  end

  defp route_motion(state, :perspective, x, y) do
    %{state | orbit: EAGL.OrbitCamera.handle_mouse_motion(state.orbit, x, y)}
  end

  defp route_motion(state, :top, x, y) do
    %{state | cam_top: EAGL.OrthoCamera.handle_mouse_motion(state.cam_top, x, y)}
  end

  defp route_motion(state, :front, x, y) do
    %{state | cam_front: EAGL.OrthoCamera.handle_mouse_motion(state.cam_front, x, y)}
  end

  defp route_motion(state, :right, x, y) do
    %{state | cam_right: EAGL.OrthoCamera.handle_mouse_motion(state.cam_right, x, y)}
  end

  defp route_scroll(state, :perspective, delta) do
    %{state | orbit: EAGL.OrbitCamera.handle_scroll(state.orbit, delta)}
  end

  defp route_scroll(state, :top, delta) do
    %{state | cam_top: EAGL.OrthoCamera.handle_scroll(state.cam_top, delta)}
  end

  defp route_scroll(state, :front, delta) do
    %{state | cam_front: EAGL.OrthoCamera.handle_scroll(state.cam_front, delta)}
  end

  defp route_scroll(state, :right, delta) do
    %{state | cam_right: EAGL.OrthoCamera.handle_scroll(state.cam_right, delta)}
  end

  # --- Scene loading ---

  defp maybe_load_default_scene(%{tried_default: true} = state), do: state

  defp maybe_load_default_scene(%{tried_default: false} = state) do
    if Map.get(state, :frame, 0) < 3 do
      state
    else
      case State.get_scene() do
        nil ->
          case Application.get_env(:lunity, :default_scene) do
            path when is_binary(path) and path != "" ->
              State.put_load_command(path)
              %{state | tried_default: true}

            _ ->
              %{state | tried_default: true}
          end

        _ ->
          %{state | tried_default: true}
      end
    end
  end

  defp apply_orbit_command(%{orbit: _} = state) do
    case State.take_orbit_command() do
      {:set_orbit, orbit} -> %{state | orbit: orbit}
      nil -> state
    end
  end

  defp process_load_command(%{program: program} = state) do
    case State.take_load_command() do
      {:load_scene, path, cwd, app} ->
        load_scene_and_apply(state, program, path, cwd, app)

      {:load_scene, path} ->
        load_scene_and_apply(state, program, path, nil, nil)

      {:load_prefab, id} ->
        load_prefab_and_apply(state, program, id)

      nil ->
        state
    end
  end

  defp load_scene_and_apply(state, program, path, cwd, app) do
    opts = [shader_program: program]

    opts =
      if cwd,
        do: Keyword.put(opts, :project_cwd, cwd) |> Keyword.put(:project_app, app),
        else: opts

    case SceneLoader.load_scene(path, opts) do
      {:ok, scene, entities} ->
        State.set_scene(scene, path, entities, :scene)
        orbit = State.take_orbit_after_load() || EAGL.OrbitCamera.fit_to_scene(scene)
        State.put_load_result({:ok, path, length(entities)})

        %{
          state
          | orbit: orbit,
            cam_top: EAGL.OrthoCamera.fit_to_scene(scene, :top),
            cam_front: EAGL.OrthoCamera.fit_to_scene(scene, :front),
            cam_right: EAGL.OrthoCamera.fit_to_scene(scene, :right),
            tried_default: true,
            load_retries: 0
        }

      {:error, {:scene_builder_error, _} = reason} ->
        retries = Map.get(state, :load_retries, 0)

        if retries < 60 do
          State.put_load_command(path, cwd, app)
          State.put_load_result({:error, reason})
          %{state | load_retries: retries + 1}
        else
          State.clear_scene()
          State.put_load_result({:error, reason})
          %{state | tried_default: true, load_retries: 0}
        end

      {:error, reason} ->
        State.clear_scene()
        State.put_load_result({:error, reason})
        %{state | tried_default: true}
    end
  end

  defp load_prefab_and_apply(state, program, id) do
    case PrefabLoader.load_prefab(id, shader_program: program) do
      {:ok, scene, _config} ->
        State.set_scene(scene, id, [], :prefab)
        orbit = State.take_orbit_after_load() || EAGL.OrbitCamera.fit_to_scene(scene)
        State.put_load_result({:ok, id, 0})

        %{
          state
          | orbit: orbit,
            cam_top: EAGL.OrthoCamera.fit_to_scene(scene, :top),
            cam_front: EAGL.OrthoCamera.fit_to_scene(scene, :front),
            cam_right: EAGL.OrthoCamera.fit_to_scene(scene, :right)
        }

      {:error, reason} ->
        State.clear_scene()
        State.put_load_result({:error, reason})
        state
    end
  end

  defp sync_orbit_to_ets(%{orbit: orbit}) do
    State.put_orbit(orbit)
  end

  defp maybe_refresh_tree(state) do
    current_path = State.get_scene_path()

    state =
      if current_path != state.tree_scene_path do
        HierarchyTree.update_scene(State.get_scene())
        State.update_window_title()
        %{state | tree_scene_path: current_path}
      else
        state
      end

    if not state.tree_project_done and state.frame > 5 do
      HierarchyTree.update_project()
      %{state | tree_project_done: true}
    else
      state
    end
  end

  # --- Capture & pick (operate on perspective viewport) ---

  defp process_capture_request(state, w, h) do
    case State.take_capture_request() do
      {:capture, _view_id} ->
        case do_capture(trunc(w), trunc(h)) do
          {:ok, base64} -> State.put_capture_result({:ok, base64})
          {:error, reason} -> State.put_capture_result({:error, reason})
        end

      nil ->
        :ok
    end

    state
  end

  defp do_capture(width, height) when width > 0 and height > 0 do
    try do
      pixel_data = <<0::size(width * height * 4)-unit(8)>>
      :gl.readPixels(0, 0, width, height, @gl_rgba, @gl_unsigned_byte, pixel_data)
      flipped = flip_pixels_vertical(pixel_data, width, height)
      png_base64 = rgba_to_png_base64(flipped, width, height)
      {:ok, png_base64}
    rescue
      e -> {:error, Exception.message(e)}
    end
  end

  defp do_capture(_, _), do: {:error, :invalid_viewport}

  defp flip_pixels_vertical(pixels, width, height) do
    row_bytes = width * 4

    rows =
      for i <- 0..(height - 1) do
        offset = i * row_bytes
        binary_part(pixels, offset, row_bytes)
      end

    rows |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp rgba_to_png_base64(rgba_binary, width, height) do
    tmp = Path.join(System.tmp_dir!(), "lunity_capture_#{System.unique_integer([:positive])}.png")

    try do
      png =
        :png.create(%{
          size: {width, height},
          mode: {:rgba, 8},
          file: tmp
        })

      row_bytes = width * 4
      rows = for i <- 0..(height - 1), do: binary_part(rgba_binary, i * row_bytes, row_bytes)
      :png.append(png, {:rows, rows})
      :png.close(png)

      png_binary = File.read!(tmp)
      Base.encode64(png_binary)
    after
      File.rm(tmp)
    end
  end

  defp process_pick_request(state, w, h) do
    case State.take_pick_request() do
      {:pick, x, y} ->
        case {State.get_scene(), State.get_orbit()} do
          {scene, orbit} when not is_nil(scene) and not is_nil(orbit) ->
            viewport = {0, 0, trunc(w), trunc(h)}

            case Scene.pick(scene, orbit, viewport, x, y) do
              {:ok, node} ->
                entity_id = (node.properties || %{})["entity_id"]
                State.put_pick_result({:ok, node, entity_id})

              nil ->
                State.put_pick_result(nil)
            end

          _ ->
            State.put_pick_result(nil)
        end

      nil ->
        :ok
    end

    state
  end

  @impl true
  def cleanup(%{program: p}) do
    EAGL.Shader.cleanup_program(p)
    :ok
  end
end
