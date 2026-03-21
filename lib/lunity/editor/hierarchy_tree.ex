defmodule Lunity.Editor.HierarchyTree do
  @moduledoc """
  Manages a wxTreeCtrl for the editor's left panel.

  Root-level sections:

  - **Game Instances** -- one expandable subtree per running Instance, showing
    its status (RUNNING/PAUSED) and live entity list
  - **Scenes** -- the currently loaded scene (with its entity hierarchy) plus
    other discovered scene modules

  Selection state is stored in `Lunity.Editor.State` for the inspector to consume.

  ## Scene node name vs instance entity

  A scene definition uses a single node name per object (e.g. `"ball"`). The
  running instance creates an ECS entity with the same name (e.g. `:ball`).
  `Lunity.Editor.State` keeps `instance_entity_map` as `%{\"ball\" => :ball}`.

  There is no separate "game name" and "scene name" for the same object — they
  are the same identifier. **Disambiguation is by UI context**, not by
  embedding two names in one string:

  - Tree items under **Scenes** carry `{:scene_node, name}` — user intent is
    the scene graph / file (may queue leaving instance watch).
  - Tree items under **Game Instances** carry `{:instance_entity, instance_id, entity_id}`.
  - Viewport picks while watching an instance resolve to `{:instance_entity, ...}`
    when the picked mesh maps to an entity (`view.ex` `do_viewport_pick`).
  """

  use WX.Const
  import Bitwise

  alias Lunity.Editor.State
  alias Lunity.Instance

  @tree_width 220

  @wx_tr_has_buttons 0x0001
  @wx_tr_lines_at_root 0x0004
  @wx_tr_hide_root 0x0800

  @doc """
  Create the wxTreeCtrl as a child of `parent`. Stores the tree reference
  in the editor ETS state and connects selection events. Returns the widget.
  """
  def create(parent) do
    style = @wx_tr_has_buttons ||| @wx_tr_lines_at_root ||| @wx_tr_hide_root ||| @wx_sunken_border
    tree = :wxTreeCtrl.new(parent, style: style)
    :wxWindow.setMinSize(tree, {@tree_width, -1})

    root = :wxTreeCtrl.addRoot(tree, ~c"Root")
    instances_root = :wxTreeCtrl.appendItem(tree, root, ~c"Game Instances")
    scenes_root = :wxTreeCtrl.appendItem(tree, root, ~c"Scenes")

    :wxTreeCtrl.expand(tree, instances_root)
    :wxTreeCtrl.expand(tree, scenes_root)

    :wxTreeCtrl.connect(tree, :command_tree_sel_changed)
    :wxTreeCtrl.connect(tree, :command_tree_item_activated)

    State.put_tree(tree, root, instances_root, scenes_root)

    tree
  end

  @doc """
  Rebuild the Scenes section (loaded scene + discovered modules).
  """
  def update_scene(scene) do
    case State.get_tree() do
      nil ->
        :ok

      {tree, _root, _instances_root, scenes_root} ->
        do_update_scenes_section(tree, scenes_root, scene)
    end
  end

  defp add_scene_node(tree, parent_item, node) do
    name = node.name || "(unnamed)"

    if auto_generated_name?(name) do
      :ok
    else
      suffix = node_type_suffix(node)
      label = if suffix, do: "#{name}  #{suffix}", else: "#{name}"
      children = (node.children || []) |> Enum.reject(&auto_generated_node?/1)

      item = :wxTreeCtrl.appendItem(tree, parent_item, String.to_charlist(label))
      :wxTreeCtrl.setItemData(tree, item, {:scene_node, name})
      name_map = State.get_tree_name_map()
      State.put_tree_name_map(Map.put(name_map, name, item))

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

      {tree, _root, instances_root, _scenes_root} ->
        do_update_instances(tree, instances_root)

      _ ->
        :ok
    end
  end

  defp do_update_instances(tree, instances_root) do
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

    current_ids = Enum.map(instances, fn {id, _, _, _} -> id end) |> MapSet.new()
    existing = collect_instance_items(tree, instances_root)
    existing_ids = Enum.map(existing, fn {id, _item} -> id end) |> MapSet.new()

    if current_ids == existing_ids do
      update_instance_labels(tree, existing, instances)
    else
      rebuild_instances(tree, instances_root, instances)
    end
  end

  defp collect_instance_items(tree, parent) do
    case :wxTreeCtrl.getChildrenCount(tree, parent, [{:recursively, false}]) do
      0 ->
        []

      _ ->
        {first, _cookie} = :wxTreeCtrl.getFirstChild(tree, parent)
        collect_siblings(tree, first, [])
    end
  rescue
    _ -> []
  end

  defp collect_siblings(_tree, 0, acc), do: Enum.reverse(acc)

  defp collect_siblings(tree, item, acc) do
    entry =
      case :wxTreeCtrl.getItemData(tree, item) do
        {:game_instance, id, _mod} -> {id, item}
        _ -> nil
      end

    next = :wxTreeCtrl.getNextSibling(tree, item)

    if entry,
      do: collect_siblings(tree, next, [entry | acc]),
      else: collect_siblings(tree, next, acc)
  rescue
    _ -> Enum.reverse(acc)
  end

  defp update_instance_labels(tree, existing, instances) do
    instance_map = Map.new(instances, fn {id, _mod, _eids, status} -> {id, status} end)

    Enum.each(existing, fn {id, item} ->
      case Map.get(instance_map, id) do
        nil ->
          :ok

        status ->
          label = "#{id} #{status_to_label(status)}"
          :wxTreeCtrl.setItemText(tree, item, String.to_charlist(label))
      end
    end)
  end

  defp rebuild_instances(tree, instances_root, instances) do
    :wxTreeCtrl.deleteChildren(tree, instances_root)

    if instances == [] do
      :wxTreeCtrl.appendItem(tree, instances_root, ~c"(no instances)")
    else
      Enum.each(instances, fn {instance_id, scene_module, entity_ids, status} ->
        status_label = status_to_label(status)
        label = "#{instance_id} #{status_label}"
        inst_item = :wxTreeCtrl.appendItem(tree, instances_root, String.to_charlist(label))
        :wxTreeCtrl.setItemData(tree, inst_item, {:game_instance, instance_id, scene_module})

        Enum.each(entity_ids, fn eid ->
          eid_label = format_entity_id(eid)
          eid_item = :wxTreeCtrl.appendItem(tree, inst_item, String.to_charlist(eid_label))
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

  defp format_entity_id(eid) when is_atom(eid), do: Atom.to_string(eid)
  defp format_entity_id(eid), do: inspect(eid)

  @doc """
  Populate the Project section by discovering loaded modules.
  """
  def update_project do
    case State.get_tree() do
      nil ->
        :ok

      {tree, _root, _instances_root, scenes_root} ->
        do_update_scenes_section(tree, scenes_root, State.get_scene())
        :wxTreeCtrl.expand(tree, scenes_root)

      _ ->
        :ok
    end
  end

  defp do_update_scenes_section(tree, scenes_root, scene) do
    :wxTreeCtrl.deleteChildren(tree, scenes_root)

    scene_path = State.get_scene_path()
    scenes = discover_scenes()

    # Exclude the currently loaded scene from the discovered list
    loaded_mod = if is_atom(scene_path), do: scene_path, else: nil
    other_scenes = Enum.reject(scenes, &(&1 == loaded_mod))

    # Add loaded scene first (with entity hierarchy) if we have one
    if scene != nil do
      label =
        case scene_path do
          nil -> "(no scene)"
          path -> State.format_scene_path_for_display(path)
        end

      scene_item = :wxTreeCtrl.appendItem(tree, scenes_root, String.to_charlist(label))
      :wxTreeCtrl.setItemData(tree, scene_item, {:scene_root})
      State.put_loaded_scene_item(scene_item)

      State.put_tree_name_map(%{})
      displayable_nodes = State.unwrap_scene_root(scene.root_nodes || [])

      Enum.each(displayable_nodes, fn node ->
        add_scene_node(tree, scene_item, node)
      end)

      :wxTreeCtrl.expand(tree, scene_item)
    else
      State.put_loaded_scene_item(nil)
      State.put_tree_name_map(%{})
    end

    # Add other discovered scene modules
    Enum.each(other_scenes, fn mod ->
      name = short_module_name(mod)
      item = :wxTreeCtrl.appendItem(tree, scenes_root, String.to_charlist(name))
      :wxTreeCtrl.setItemData(tree, item, {:project, :scene, mod})
    end)

    :wxTreeCtrl.expand(tree, scenes_root)
  end

  @doc """
  Handle a tree selection event. Extracts the item data and stores
  the selection in State. Returns the selection or nil.
  """
  def handle_selection(tree, item) do
    try do
      State.put_tree_selected_item(item)

      case :wxTreeCtrl.getItemData(tree, item) do
        {:scene_root} = data ->
          maybe_return_to_scene_view()
          State.put_selection(data)
          data

        {:scene_node, name} = data ->
          # Scenes-tree row only (not Game Instances). Restore scene-from-disk view when watching.
          maybe_return_to_scene_view()
          selection = resolve_scene_node_selection(name)
          State.put_selection(selection)
          data

        {:game_instance, instance_id, scene_module} = data ->
          if State.get_watching_instance() != instance_id do
            State.put_watch_command({:watch, instance_id, scene_module})
          end

          State.put_selection(data)
          data

        {:instance_entity, instance_id, _entity_id} = data ->
          maybe_watch_instance_for_entity(instance_id)
          State.put_selection(data)
          data

        {:project, :scene, mod} = data ->
          maybe_return_to_scene_view(mod)
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

  defp maybe_watch_instance_for_entity(instance_id) do
    if State.get_watching_instance() == instance_id do
      :ok
    else
      case Instance.get(instance_id) do
        %{scene_module: mod} when not is_nil(mod) ->
          State.put_watch_command({:watch, instance_id, mod})

        _ ->
          :ok
      end
    end
  end

  defp maybe_return_to_scene_view do
    case State.get_watching_instance() do
      nil ->
        :ok

      instance_id ->
        case Instance.get(instance_id) do
          %{scene_module: mod} when not is_nil(mod) ->
            State.put_load_command(mod)

          _ ->
            :ok
        end
    end
  end

  defp maybe_return_to_scene_view(mod) when not is_nil(mod) do
    if State.get_watching_instance() != nil do
      State.put_load_command(mod)
    end

    :ok
  end

  defp maybe_return_to_scene_view(_), do: :ok

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
  Recomputes the selection AABB from the current scene graph after a scene load.

  Call after `State.set_scene/4` so cached `{:scene_node, name, aabb}` matches meshes
  (e.g. after switching from a live instance to an on-disk scene).
  """
  def refresh_scene_node_selection_aabb do
    case State.get_selection() do
      {:scene_node, name} when is_binary(name) ->
        State.put_selection(resolve_scene_node_selection(name))

      {:scene_node, name, _} when is_binary(name) ->
        State.put_selection(resolve_scene_node_selection(name))

      _ ->
        :ok
    end
  end

  @doc """
  Poll hover state by checking the global mouse position against the tree.
  Returns `{:scene_node, name, aabb}` if hovering a scene node, or nil.
  Also styles the hovered tree item with a warm highlight.
  """
  def poll_hover do
    case State.get_tree() do
      {tree, _, _, _} -> do_poll_hover(tree)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp do_poll_hover(tree) do
    {gx, gy} = :wx_misc.getMousePosition()
    {lx, ly} = :wxWindow.screenToClient(tree, {gx, gy})
    {tw, th} = :wxWindow.getSize(tree)

    if lx >= 0 and ly >= 0 and lx < tw and ly < th do
      {item, _flags} = :wxTreeCtrl.hitTest(tree, {lx, ly})

      if item != 0 do
        State.put_tree_hover_item(item)

        case :wxTreeCtrl.getItemData(tree, item) do
          {:scene_node, name} -> resolve_scene_node_hover(name)
          _ -> nil
        end
      else
        State.put_tree_hover_item(nil)
        nil
      end
    else
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
      {tree, _, _, _} ->
        name_map = State.get_tree_name_map()

        case Map.get(name_map, name) do
          nil ->
            :ok

          item ->
            State.put_tree_selected_item(item)
            :wxTreeCtrl.selectItem(tree, item)
            :wxTreeCtrl.ensureVisible(tree, item)
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
  Select the entity row under Game Instances (e.g. after a viewport pick while
  watching that instance). Does not switch to on-disk scene view.
  """
  def select_instance_entity(instance_id, entity_id) do
    case State.get_tree() do
      {tree, _root, instances_root, _scenes_root} ->
        case find_instance_item(tree, instances_root, instance_id) do
          nil ->
            :ok

          inst_item ->
            case find_instance_entity_item(tree, inst_item, instance_id, entity_id) do
              nil ->
                :ok

              item ->
                State.put_tree_selected_item(item)
                :wxTreeCtrl.selectItem(tree, item)
                :wxTreeCtrl.ensureVisible(tree, item)
            end
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp find_instance_item(tree, instances_root, instance_id) do
    case first_tree_child(tree, instances_root) do
      nil -> nil
      first -> find_instance_item_siblings(tree, first, instance_id)
    end
  end

  defp find_instance_item_siblings(tree, item, instance_id) do
    case :wxTreeCtrl.getItemData(tree, item) do
      {:game_instance, ^instance_id, _} ->
        item

      _ ->
        next = :wxTreeCtrl.getNextSibling(tree, item)

        if next == 0 do
          nil
        else
          find_instance_item_siblings(tree, next, instance_id)
        end
    end
  rescue
    _ -> nil
  end

  defp find_instance_entity_item(tree, inst_item, instance_id, entity_id) do
    case first_tree_child(tree, inst_item) do
      nil -> nil
      first -> find_instance_entity_siblings(tree, first, instance_id, entity_id)
    end
  end

  defp find_instance_entity_siblings(tree, item, instance_id, entity_id) do
    case :wxTreeCtrl.getItemData(tree, item) do
      {:instance_entity, ^instance_id, ^entity_id} ->
        item

      _ ->
        next = :wxTreeCtrl.getNextSibling(tree, item)

        if next == 0 do
          nil
        else
          find_instance_entity_siblings(tree, next, instance_id, entity_id)
        end
    end
  rescue
    _ -> nil
  end

  defp first_tree_child(tree, parent) do
    case :wxTreeCtrl.getChildrenCount(tree, parent, [{:recursively, false}]) do
      0 ->
        nil

      _ ->
        {first, _cookie} = :wxTreeCtrl.getFirstChild(tree, parent)
        first
    end
  rescue
    _ -> nil
  end

  @doc """
  Programmatically select the Source (scene root) item in the tree.
  """
  def select_scene_root do
    case {State.get_tree(), State.get_loaded_scene_item()} do
      {{tree, _, _, _}, scene_item} when scene_item != nil ->
        State.put_tree_selected_item(scene_item)
        :wxTreeCtrl.selectItem(tree, scene_item)
        :wxTreeCtrl.ensureVisible(tree, scene_item)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Clear the tree selection (e.g. when deselecting from viewport).
  Resets the previously selected item to default styling (white bg, black text).
  """
  def clear_selection do
    case State.get_tree() do
      {tree, _, _, _} ->
        :wxTreeCtrl.unselect(tree)
        State.put_tree_selected_item(nil)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Programmatically hover a scene node in the tree by name (e.g. from
  viewport hover). Updates the tree item styling. Pass nil to clear.
  """
  def hover_by_name(name) when is_binary(name) do
    case State.get_tree() do
      {_tree, _, _, _} ->
        name_map = State.get_tree_name_map()

        case Map.get(name_map, name) do
          nil ->
            State.put_tree_hover_item(nil)

          item ->
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
      {_tree, _, _, _} ->
        State.put_tree_hover_item(nil)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  def hover_by_name(_), do: :ok

  @doc """
  Handle a tree item activation (double-click / Enter). Loads scenes from
  the Scenes section.
  """
  def handle_activation(tree, item) do
    try do
      case :wxTreeCtrl.getItemData(tree, item) do
        {:scene_root} ->
          maybe_return_to_scene_view()
          :ok

        {:project, :scene, mod} ->
          State.put_load_command(mod)
          :ok

        {:game_instance, instance_id, scene_module} ->
          if State.get_watching_instance() != instance_id do
            State.put_watch_command({:watch, instance_id, scene_module})
          end

          :ok

        {:scene_node, _name} ->
          maybe_return_to_scene_view()
          :ok

        _ ->
          :ok
      end
    rescue
      _ -> :ok
    end
  end

  @doc false
  def discover_scenes do
    :code.all_loaded()
    |> Enum.map(fn {mod, _} -> mod end)
    |> Enum.filter(&is_atom/1)
    |> Enum.filter(&exports_function?(&1, :__scene_def__, 0))
    |> Enum.sort()
  end

  defp exports_function?(mod, fun, arity) do
    Code.ensure_loaded?(mod) && function_exported?(mod, fun, arity)
  end

  defp short_module_name(mod) do
    mod
    |> Module.split()
    |> List.last()
  end
end
