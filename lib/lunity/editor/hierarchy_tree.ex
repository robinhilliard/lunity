defmodule Lunity.Editor.HierarchyTree do
  @moduledoc """
  Manages a wxTreeCtrl for the editor's left panel.

  Three root-level sections:

  - **Source** -- nodes from the currently loaded scene definition (the source,
    not a running instance)
  - **Game Instances** -- one expandable subtree per running Instance, showing
    its status (RUNNING/PAUSED) and live entity list
  - **Project** -- discovered Entity, Prefab, and Scene modules

  Selection state is stored in `Lunity.Editor.State` for the inspector to consume.
  """

  use WX.Const
  import Bitwise

  alias Lunity.Editor.State

  @tree_width 220

  @wx_tr_has_buttons 0x0001
  @wx_tr_lines_at_root 0x0004
  @wx_tr_hide_root 0x0800

  defp theme, do: State.get_theme()

  @doc """
  Create the wxTreeCtrl as a child of `parent`. Stores the tree reference
  in the editor ETS state and connects selection events. Returns the widget.
  """
  def create(parent) do
    style = @wx_tr_has_buttons ||| @wx_tr_lines_at_root ||| @wx_tr_hide_root ||| @wx_sunken_border
    tree = :wxTreeCtrl.new(parent, style: style)
    :wxWindow.setMinSize(tree, {@tree_width, -1})

    native_bg = :wxTreeCtrl.getBackgroundColour(tree)
    native_fg = :wxTreeCtrl.getForegroundColour(tree)
    State.put_tree_native_colours(native_bg, native_fg)

    root = :wxTreeCtrl.addRoot(tree, ~c"Root")
    scene_root = :wxTreeCtrl.appendItem(tree, root, ~c"Source: (no scene)")
    instances_root = :wxTreeCtrl.appendItem(tree, root, ~c"Game Instances")
    project_root = :wxTreeCtrl.appendItem(tree, root, ~c"Project")

    :wxTreeCtrl.expand(tree, scene_root)
    :wxTreeCtrl.expand(tree, instances_root)
    :wxTreeCtrl.expand(tree, project_root)

    :wxTreeCtrl.connect(tree, :command_tree_sel_changed)
    :wxTreeCtrl.connect(tree, :command_tree_item_activated)

    State.put_tree(tree, root, scene_root, project_root, instances_root)

    tree
  end

  @doc """
  Rebuild the Scene section from an EAGL scene's root nodes.
  """
  def update_scene(scene) do
    case State.get_tree() do
      nil ->
        :ok

      {tree, _root, scene_root, _project_root, _instances_root} ->
        do_update_scene(tree, scene_root, scene)
    end
  end

  defp do_update_scene(tree, scene_root, nil) do
    :wxTreeCtrl.deleteChildren(tree, scene_root)
    :wxTreeCtrl.setItemText(tree, scene_root, ~c"Source: (no scene)")
    :wxTreeCtrl.expand(tree, scene_root)
  end

  defp do_update_scene(tree, scene_root, scene) do
    :wxTreeCtrl.deleteChildren(tree, scene_root)
    State.put_tree_name_map(%{})

    label =
      case State.get_scene_path() do
        nil -> "Source"
        path -> "Source: #{path}"
      end

    :wxTreeCtrl.setItemText(tree, scene_root, String.to_charlist(label))

    displayable_nodes = State.unwrap_scene_root(scene.root_nodes || [])

    Enum.each(displayable_nodes, fn node ->
      add_scene_node(tree, scene_root, node)
    end)

    :wxTreeCtrl.expand(tree, scene_root)
  end

  defp add_scene_node(tree, parent_item, node) do
    name = node.name || "(unnamed)"

    if auto_generated_name?(name) do
      :ok
    else
      suffix = node_type_suffix(node)
      label = if suffix, do: "#{name}  #{suffix}", else: "#{name}"
      item = :wxTreeCtrl.appendItem(tree, parent_item, String.to_charlist(label))
      set_item_default_style(tree, item)

      :wxTreeCtrl.setItemData(tree, item, {:scene_node, name})
      name_map = State.get_tree_name_map()
      State.put_tree_name_map(Map.put(name_map, name, item))

      children = (node.children || []) |> Enum.reject(&auto_generated_node?/1)
      Enum.each(children, fn child -> add_scene_node(tree, item, child) end)

      if children != [], do: :wxTreeCtrl.expand(tree, item)
    end
  end

  defp auto_generated_name?(name), do: Regex.match?(~r/^node_\d+$/, name)

  defp auto_generated_node?(node) do
    name = node.name || "(unnamed)"
    auto_generated_name?(name) and node.light == nil and node.camera == nil
  end

  defp node_type_suffix(node) do
    cond do
      node.light != nil -> "[light]"
      node.camera != nil -> "[camera]"
      true -> nil
    end
  end

  @doc """
  Rebuild the Game Instances section from running Lunity.Instance processes.
  """
  def update_instances do
    case State.get_tree() do
      nil ->
        :ok

      {tree, _root, _scene_root, _project_root, instances_root} ->
        do_update_instances(tree, instances_root)

      _ ->
        :ok
    end
  end

  defp do_update_instances(tree, instances_root) do
    :wxTreeCtrl.deleteChildren(tree, instances_root)

    instances =
      try do
        for id <- Lunity.Instance.list() do
          case Lunity.Instance.get(id) do
            %{scene_module: mod, entity_ids: eids, status: status} ->
              {id, mod, eids || [], status}
            _ ->
              nil
          end
        end
        |> Enum.reject(&is_nil/1)
      rescue
        _ -> []
      end

    if instances == [] do
      item = :wxTreeCtrl.appendItem(tree, instances_root, ~c"(no instances)")
      set_item_default_style(tree, item)
    else
      Enum.each(instances, fn {instance_id, scene_module, entity_ids, status} ->
        short = scene_module |> Module.split() |> List.last()
        status_label = status_to_label(status)
        label = "#{instance_id}  [#{short}] #{status_label}"
        inst_item = :wxTreeCtrl.appendItem(tree, instances_root, String.to_charlist(label))
        set_item_default_style(tree, inst_item)
        :wxTreeCtrl.setItemData(tree, inst_item, {:game_instance, instance_id, scene_module})

        Enum.each(entity_ids, fn eid ->
          eid_label = inspect(eid)
          eid_item = :wxTreeCtrl.appendItem(tree, inst_item, String.to_charlist(eid_label))
          set_item_default_style(tree, eid_item)
          :wxTreeCtrl.setItemData(tree, eid_item, {:instance_entity, instance_id, eid})
        end)

        :wxTreeCtrl.expand(tree, inst_item)
      end)
    end

    :wxTreeCtrl.expand(tree, instances_root)
  end

  defp status_to_label(:running), do: "RUNNING"
  defp status_to_label(:paused), do: "PAUSED"
  defp status_to_label(other), do: to_string(other)

  @doc """
  Populate the Project section by discovering loaded modules.
  """
  def update_project do
    case State.get_tree() do
      nil ->
        :ok

      {tree, _root, _scene_root, project_root, _instances_root} ->
        do_update_project(tree, project_root)

      _ ->
        :ok
    end
  end

  defp do_update_project(tree, project_root) do
    :wxTreeCtrl.deleteChildren(tree, project_root)

    {entities, prefabs, scenes} = discover_modules()

    if entities != [] do
      ent_item = :wxTreeCtrl.appendItem(tree, project_root, ~c"Entities")
      set_item_default_style(tree, ent_item)

      Enum.each(entities, fn mod ->
        name = short_module_name(mod)
        item = :wxTreeCtrl.appendItem(tree, ent_item, String.to_charlist(name))
        set_item_default_style(tree, item)
        :wxTreeCtrl.setItemData(tree, item, {:project, :entity, mod})
      end)

      :wxTreeCtrl.expand(tree, ent_item)
    end

    if prefabs != [] do
      pref_item = :wxTreeCtrl.appendItem(tree, project_root, ~c"Prefabs")
      set_item_default_style(tree, pref_item)

      Enum.each(prefabs, fn mod ->
        name = short_module_name(mod)
        item = :wxTreeCtrl.appendItem(tree, pref_item, String.to_charlist(name))
        set_item_default_style(tree, item)
        :wxTreeCtrl.setItemData(tree, item, {:project, :prefab, mod})
      end)

      :wxTreeCtrl.expand(tree, pref_item)
    end

    if scenes != [] do
      sc_item = :wxTreeCtrl.appendItem(tree, project_root, ~c"Scenes")
      set_item_default_style(tree, sc_item)

      Enum.each(scenes, fn mod ->
        name = short_module_name(mod)
        item = :wxTreeCtrl.appendItem(tree, sc_item, String.to_charlist(name))
        set_item_default_style(tree, item)
        :wxTreeCtrl.setItemData(tree, item, {:project, :scene, mod})
      end)

      :wxTreeCtrl.expand(tree, sc_item)
    end

    :wxTreeCtrl.expand(tree, project_root)
  end

  @doc """
  Handle a tree selection event. Extracts the item data and stores
  the selection in State. Returns the selection or nil.
  """
  def handle_selection(tree, item) do
    try do
      prev_sel = State.get_tree_selected_item()
      State.put_tree_selected_item(item)
      if prev_sel != nil and prev_sel != item, do: reset_item_style(tree, prev_sel)

      case :wxTreeCtrl.getItemData(tree, item) do
        {:scene_node, name} = data ->
          t = theme()
          set_item_style(tree, item, t.select_bg, t.select_fg)
          State.put_tree_selected_item(item)
          selection = resolve_scene_node_selection(name)
          State.put_selection(selection)
          data

        {:game_instance, instance_id, scene_module} = data ->
          t = theme()
          set_item_style(tree, item, t.select_bg, t.select_fg)
          State.put_tree_selected_item(item)
          State.put_watch_command({:watch, instance_id, scene_module})
          State.put_selection(data)
          data

        {:instance_entity, _instance_id, _entity_id} = data ->
          t = theme()
          set_item_style(tree, item, t.select_bg, t.select_fg)
          State.put_tree_selected_item(item)
          State.put_selection(data)
          data

        data when is_tuple(data) ->
          State.put_selection(data)
          data

        _ ->
          State.put_selection(nil)
          nil
      end
    rescue
      _ ->
        State.put_selection(nil)
        nil
    end
  end

  defp resolve_scene_node_selection(name) do
    case State.get_scene() do
      nil ->
        {:scene_node, name}

      scene ->
        case EAGL.Scene.find_node_with_transform(scene, name) do
          {:ok, node, world} ->
            aabb = Lunity.Editor.View.subtree_world_aabb(node, world)
            {:scene_node, name, aabb}

          nil ->
            {:scene_node, name}
        end
    end
  end

  @doc """
  Poll hover state by checking the global mouse position against the tree.
  Returns `{:scene_node, name, aabb}` if hovering a scene node, or nil.
  Also styles the hovered tree item with a warm highlight.
  """
  def poll_hover do
    case State.get_tree() do
      {tree, _, _, _, _} -> do_poll_hover(tree)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp do_poll_hover(tree) do
    {gx, gy} = :wx_misc.getMousePosition()
    {lx, ly} = :wxWindow.screenToClient(tree, {gx, gy})
    {tw, th} = :wxWindow.getSize(tree)

    prev_hover = State.get_tree_hover_item()

    if lx >= 0 and ly >= 0 and lx < tw and ly < th do
      {item, _flags} = :wxTreeCtrl.hitTest(tree, {lx, ly})

      if item != 0 do
        if prev_hover != nil and prev_hover != item, do: reset_item_style(tree, prev_hover)
        sel_item = State.get_tree_selected_item()
        t = theme()
        if item != sel_item, do: set_item_style(tree, item, t.hover_bg, t.hover_fg)
        State.put_tree_hover_item(item)

        case :wxTreeCtrl.getItemData(tree, item) do
          {:scene_node, name} -> resolve_scene_node_hover(name)
          _ -> nil
        end
      else
        if prev_hover, do: reset_item_style(tree, prev_hover)
        State.put_tree_hover_item(nil)
        nil
      end
    else
      if prev_hover, do: reset_item_style(tree, prev_hover)
      State.put_tree_hover_item(nil)
      nil
    end
  end

  defp resolve_scene_node_hover(name) do
    case State.get_scene() do
      nil ->
        nil

      scene ->
        case EAGL.Scene.find_node_with_transform(scene, name) do
          {:ok, node, world} ->
            aabb = Lunity.Editor.View.subtree_world_aabb(node, world)
            if aabb, do: {:scene_node, name, aabb}

          nil ->
            nil
        end
    end
  end

  @doc """
  Programmatically select a scene node in the tree by name (e.g. after a
  viewport pick). Updates both the wxTreeCtrl visual selection and the
  item styling.
  """
  def select_by_name(name) when is_binary(name) do
    case State.get_tree() do
      {tree, _, _, _, _} ->
        name_map = State.get_tree_name_map()

        case Map.get(name_map, name) do
          nil ->
            :ok

          item ->
            prev_sel = State.get_tree_selected_item()
            State.put_tree_selected_item(item)
            if prev_sel != nil and prev_sel != item, do: reset_item_style(tree, prev_sel)
            t = theme()
            set_item_style(tree, item, t.select_bg, t.select_fg)
            :wxTreeCtrl.selectItem(tree, item)
            :wxTreeCtrl.ensureVisible(tree, item)
            # Give tree focus so selection shows blue (macOS uses gray when unfocused)
            :wxWindow.setFocus(tree)
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def select_by_name(nil), do: clear_selection()
  def select_by_name(_), do: :ok

  @doc """
  Clear the tree selection (e.g. when deselecting from viewport).
  Resets the previously selected item to default styling (white bg, black text).
  """
  def clear_selection do
    case State.get_tree() do
      {tree, _, _, _, _} ->
        prev_sel = State.get_tree_selected_item()

        if prev_sel != nil do
          set_item_default_style(tree, prev_sel)
          :wxTreeCtrl.unselect(tree)
          State.put_tree_selected_item(nil)
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp set_item_default_style(tree, item) do
    try do
      {bg, fg} = State.get_tree_native_colours()
      :wxTreeCtrl.setItemBackgroundColour(tree, item, bg)
      :wxTreeCtrl.setItemTextColour(tree, item, fg)
    rescue
      _ -> :ok
    end
  end

  @doc """
  Programmatically hover a scene node in the tree by name (e.g. from
  viewport hover). Updates the tree item styling. Pass nil to clear.
  """
  def hover_by_name(name) when is_binary(name) do
    case State.get_tree() do
      {tree, _, _, _, _} ->
        name_map = State.get_tree_name_map()
        prev_hover = State.get_tree_hover_item()

        case Map.get(name_map, name) do
          nil ->
            if prev_hover, do: reset_item_style(tree, prev_hover)
            State.put_tree_hover_item(nil)

          item when item == prev_hover ->
            :ok

          item ->
            if prev_hover, do: reset_item_style(tree, prev_hover)
            sel_item = State.get_tree_selected_item()
            t = theme()
            if item != sel_item, do: set_item_style(tree, item, t.hover_bg, t.hover_fg)
            State.put_tree_hover_item(item)
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def hover_by_name(nil) do
    case State.get_tree() do
      {tree, _, _, _, _} ->
        prev_hover = State.get_tree_hover_item()
        if prev_hover, do: reset_item_style(tree, prev_hover)
        State.put_tree_hover_item(nil)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def hover_by_name(_), do: :ok

  @doc """
  Handle a tree item activation (double-click / Enter). Loads scenes or
  inspects prefabs from the Project section.
  """
  def handle_activation(tree, item) do
    try do
      case :wxTreeCtrl.getItemData(tree, item) do
        {:project, :scene, mod} ->
          State.put_load_command(mod)
          :ok

        {:project, :prefab, mod} ->
          glb_id = if function_exported?(mod, :__glb_id__, 0), do: mod.__glb_id__(), else: nil

          if glb_id do
            State.put_load_prefab_command(glb_id)
          end

          :ok

        {:game_instance, instance_id, scene_module} ->
          State.put_watch_command({:watch, instance_id, scene_module})
          :ok

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  @doc false
  def discover_modules do
    all_loaded =
      :code.all_loaded()
      |> Enum.map(fn {mod, _} -> mod end)
      |> Enum.filter(&is_atom/1)

    entities =
      all_loaded
      |> Enum.filter(&exports_function?(&1, :__components__, 0))
      |> Enum.sort()

    prefabs =
      all_loaded
      |> Enum.filter(&exports_function?(&1, :__glb_id__, 0))
      |> Enum.sort()

    scenes =
      all_loaded
      |> Enum.filter(&exports_function?(&1, :__scene_def__, 0))
      |> Enum.sort()

    {entities, prefabs, scenes}
  end

  defp exports_function?(mod, fun, arity) do
    Code.ensure_loaded?(mod) && function_exported?(mod, fun, arity)
  end

  defp short_module_name(mod) do
    mod
    |> Module.split()
    |> List.last()
  end

  defp set_item_style(tree, item, {br, bg, bb}, {fr, fg, fb}) do
    try do
      :wxTreeCtrl.setItemBackgroundColour(tree, item, {br, bg, bb, 255})
      :wxTreeCtrl.setItemTextColour(tree, item, {fr, fg, fb, 255})
    rescue
      _ -> :ok
    end
  end

  defp reset_item_style(tree, item) do
    try do
      sel_item = State.get_tree_selected_item()

      if item == sel_item do
        t = theme()
        set_item_style(tree, item, t.select_bg, t.select_fg)
      else
        set_item_default_style(tree, item)
      end
    rescue
      _ -> :ok
    end
  end
end
