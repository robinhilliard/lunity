defmodule Lunity.Editor.HierarchyTree do
  @moduledoc """
  Manages a wxTreeCtrl for the editor's left panel.

  Two root-level sections:

  - **Scene** -- nodes from the currently loaded scene, mirroring the scene graph
  - **Project** -- discovered Entity, Prefab, and Scene modules, sorted alphabetically

  Selection state is stored in `Lunity.Editor.State` for the inspector to consume.
  """

  use WX.Const
  import Bitwise

  alias Lunity.Editor.State

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
    scene_root = :wxTreeCtrl.appendItem(tree, root, ~c"Scene: (no scene)")
    project_root = :wxTreeCtrl.appendItem(tree, root, ~c"Project")

    :wxTreeCtrl.expand(tree, scene_root)
    :wxTreeCtrl.expand(tree, project_root)

    :wxTreeCtrl.connect(tree, :command_tree_sel_changed)

    State.put_tree(tree, root, scene_root, project_root)

    tree
  end

  @doc """
  Rebuild the Scene section from an EAGL scene's root nodes.
  """
  def update_scene(scene) do
    case State.get_tree() do
      nil -> :ok
      {tree, _root, scene_root, _project_root} -> do_update_scene(tree, scene_root, scene)
    end
  end

  defp do_update_scene(tree, scene_root, nil) do
    :wxTreeCtrl.deleteChildren(tree, scene_root)
    :wxTreeCtrl.setItemText(tree, scene_root, ~c"Scene: (no scene)")
    :wxTreeCtrl.expand(tree, scene_root)
  end

  defp do_update_scene(tree, scene_root, scene) do
    :wxTreeCtrl.deleteChildren(tree, scene_root)

    label =
      case State.get_scene_path() do
        nil -> "Scene"
        path -> "Scene: #{path}"
      end

    :wxTreeCtrl.setItemText(tree, scene_root, String.to_charlist(label))

    root_nodes = scene.root_nodes || []

    Enum.each(root_nodes, fn node ->
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

      :wxTreeCtrl.setItemData(tree, item, {:scene_node, name})

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
      node.mesh != nil -> nil
      node.children != nil and node.children != [] -> "[group]"
      true -> nil
    end
  end

  @doc """
  Populate the Project section by discovering loaded modules.
  """
  def update_project do
    case State.get_tree() do
      nil -> :ok
      {tree, _root, _scene_root, project_root} -> do_update_project(tree, project_root)
    end
  end

  defp do_update_project(tree, project_root) do
    :wxTreeCtrl.deleteChildren(tree, project_root)

    {entities, prefabs, scenes} = discover_modules()

    if entities != [] do
      ent_item = :wxTreeCtrl.appendItem(tree, project_root, ~c"Entities")

      Enum.each(entities, fn mod ->
        name = short_module_name(mod)
        item = :wxTreeCtrl.appendItem(tree, ent_item, String.to_charlist(name))
        :wxTreeCtrl.setItemData(tree, item, {:project, :entity, mod})
      end)

      :wxTreeCtrl.expand(tree, ent_item)
    end

    if prefabs != [] do
      pref_item = :wxTreeCtrl.appendItem(tree, project_root, ~c"Prefabs")

      Enum.each(prefabs, fn mod ->
        name = short_module_name(mod)
        item = :wxTreeCtrl.appendItem(tree, pref_item, String.to_charlist(name))
        :wxTreeCtrl.setItemData(tree, item, {:project, :prefab, mod})
      end)

      :wxTreeCtrl.expand(tree, pref_item)
    end

    if scenes != [] do
      sc_item = :wxTreeCtrl.appendItem(tree, project_root, ~c"Scenes")

      Enum.each(scenes, fn mod ->
        name = short_module_name(mod)
        item = :wxTreeCtrl.appendItem(tree, sc_item, String.to_charlist(name))
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
      case :wxTreeCtrl.getItemData(tree, item) do
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
end
