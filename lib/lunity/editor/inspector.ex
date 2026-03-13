defmodule Lunity.Editor.Inspector do
  @moduledoc """
  Right-side inspector panel showing component values for the selected entity.

  Uses a wxGrid with Component and Value columns. Updates are polled from the
  render loop when an instance entity is selected in the hierarchy tree.
  """

  use WX.Const
  import Bitwise

  alias Lunity.Editor.State
  alias Lunity.ComponentStore

  @inspector_width 260

  @grab_width 4

  @doc "Create the inspector panel as a child of `parent`. Returns the widget."
  def create(parent) do
    container = :wxPanel.new(parent)
    :wxWindow.setMinSize(container, {@inspector_width + @grab_width, -1})

    h_sizer = :wxBoxSizer.new(@wx_horizontal)

    grab = :wxPanel.new(container)
    :wxWindow.setMinSize(grab, {@grab_width, 1})
    :wxWindow.setBackgroundColour(grab, {200, 200, 200})
    :wxSizer.add(h_sizer, grab, proportion: 0, flag: 0)
    :wxSizer.setItemMinSize(h_sizer, grab, @grab_width, 1)

    panel = :wxPanel.new(container)
    :wxWindow.setMinSize(panel, {@inspector_width, -1})

    sizer = :wxBoxSizer.new(@wx_vertical)

    grid = :wxGrid.new(panel, -1, [style: @wx_no_border])
    :wxGrid.createGrid(grid, 0, 2)
    :wxGrid.setRowLabelSize(grid, 0)
    :wxGrid.setColLabelSize(grid, 0)
    :wxGrid.setColSize(grid, 0, 120)
    :wxGrid.setColSize(grid, 1, 130)
    :wxGrid.enableGridLines(grid, [{:enable, false}])
    :wxGrid.enableEditing(grid, false)

    :wxSizer.add(sizer, grid, proportion: 1, flag: @wx_expand ||| Bitwise.bsl(1, 6), border: 4)
    :wxPanel.setSizer(panel, sizer)

    :wxSizer.add(h_sizer, panel, proportion: 1, flag: @wx_expand ||| Bitwise.bsl(1, 6), border: 0)
    :wxPanel.setSizer(container, h_sizer)

    State.put_inspector(grid)
    container
  end

  @doc "Refresh the inspector with component data for the currently selected entity."
  def refresh do
    grid = State.get_inspector()
    unless grid, do: throw(:no_inspector)

    case State.get_selection() do
      {:instance_entity, instance_id, entity_id} ->
        refresh_entity(grid, instance_id, entity_id)

      {:scene_root} ->
        refresh_scene_root(grid)

      {:scene_node, name, _aabb} ->
        refresh_scene_node(grid, name)

      {:scene_node, name} ->
        refresh_scene_node(grid, name)

      _ ->
        show_message(grid, "(no entity selected)")
    end
  catch
    :no_inspector -> :ok
  end

  defp refresh_scene_root(grid) do
    path = State.get_scene_path() || "(no scene)"
    path_str = State.format_scene_path_for_display(path) || "(no scene)"
    show_message(grid, "Scene: #{path_str}")
  end

  defp refresh_scene_node(grid, name) do
    scene = State.get_scene()

    node =
      case scene && EAGL.Scene.find_node_with_transform(scene, name) do
        {:ok, node, _world} -> node
        _ -> nil
      end

    unless node do
      show_message(grid, "(node not found)")
      throw(:done)
    end

    props = node.properties || %{}

    rows =
      [
        prefab_entity_row("Prefab", Map.get(props, "prefab")),
        prefab_entity_row("Entity", Map.get(props, "entity")),
        node_prop("Name", node.name),
        node_prop("Position", node.position),
        node_prop("Rotation", node.rotation),
        node_prop("Scale", node.scale),
        light_rows(node.light),
        camera_rows(node.camera),
        properties_rows(props, ["prefab", "entity"])
      ]
      |> List.flatten()
      |> Enum.reject(&is_nil/1)

    populate_grid(grid, rows)
  catch
    :done -> :ok
  end

  defp node_prop(_label, nil), do: nil
  defp node_prop(label, val), do: {label, format_value(val, %{})}

  defp prefab_entity_row(_label, nil), do: nil
  defp prefab_entity_row(label, val) when is_atom(val) do
    {label, inspect(val)}
  end
  defp prefab_entity_row(label, val) when is_binary(val), do: {label, val}
  defp prefab_entity_row(label, val), do: {label, format_value(val, %{})}

  defp light_rows(nil), do: []

  defp light_rows(light) when is_map(light) do
    [
      node_prop("Light Type", Map.get(light, :type)),
      node_prop("Light Color", Map.get(light, :color)),
      node_prop("Light Intensity", Map.get(light, :intensity)),
      node_prop("Light Range", Map.get(light, :range))
    ]
  end

  defp camera_rows(nil), do: []

  defp camera_rows(camera) when is_map(camera) do
    [
      node_prop("Camera Type", Map.get(camera, :type)),
      node_prop("Camera FOV", Map.get(camera, :yfov)),
      node_prop("Camera Near", Map.get(camera, :znear)),
      node_prop("Camera Far", Map.get(camera, :zfar))
    ]
  end

  defp camera_rows(_), do: []

  defp properties_rows(nil, _exclude), do: []

  defp properties_rows(props, exclude) when is_map(props) and is_list(exclude) do
    exclude_set = MapSet.new(exclude)

    props
    |> Enum.reject(fn {k, _} -> MapSet.member?(exclude_set, to_string(k)) end)
    |> Enum.map(fn {k, v} -> node_prop(to_string(k), v) end)
  end

  defp properties_rows(_, _), do: []

  defp refresh_entity(grid, instance_id, entity_id) do
    instance = Lunity.Instance.get(instance_id)

    store_id =
      case instance do
        %{store_id: sid} -> sid
        _ -> nil
      end

    unless store_id do
      show_message(grid, "(instance not found)")
      throw(:done)
    end

    meta_table = :"lunity_meta_#{store_id}"

    components =
      try do
        :ets.tab2list(meta_table)
      rescue
        _ -> []
      end

    rows =
      ComponentStore.with_store(store_id, fn ->
        Enum.flat_map(components, fn {mod, opts} ->
          short = mod |> Module.split() |> List.last()

          val =
            try do
              ComponentStore.get(mod, entity_id)
            rescue
              _ -> nil
            end

          case val do
            nil -> []
            _ -> [{short, format_value(val, opts)}]
          end
        end)
        |> Enum.sort_by(fn {name, _} -> name end)
      end)

    populate_grid(grid, rows)
  catch
    :done -> :ok
  end

  defp populate_grid(grid, rows) do
    clear_grid(grid)

    if rows == [] do
      show_message(grid, "(empty)")
    else
      :wxGrid.appendRows(grid, numRows: length(rows))

      Enum.with_index(rows, fn {name, value}, idx ->
        :wxGrid.setCellValue(grid, idx, 0, String.to_charlist(name))
        :wxGrid.setCellValue(grid, idx, 1, String.to_charlist(value))
      end)

      :wxGrid.autoSizeColumns(grid)
    end
  end

  defp format_value(val, _opts) when is_tuple(val) do
    val
    |> Tuple.to_list()
    |> Enum.map(&format_number/1)
    |> Enum.join(", ")
  end

  defp format_value(val, _opts) when is_list(val) do
    if Enum.all?(val, &is_number/1) do
      val |> Enum.map(&format_number/1) |> Enum.join(", ")
    else
      inspect(val, limit: 50)
    end
  end

  defp format_value(val, _opts) when is_number(val), do: format_number(val)
  defp format_value(val, _opts) when is_atom(val), do: to_string(val)
  defp format_value(val, _opts) when is_binary(val), do: val
  defp format_value(val, _opts), do: inspect(val, limit: 50)

  defp format_number(n) when is_float(n), do: :erlang.float_to_binary(n, decimals: 3)
  defp format_number(n), do: to_string(n)

  defp clear_grid(grid) do
    rows = :wxGrid.getNumberRows(grid)
    if rows > 0, do: :wxGrid.deleteRows(grid, numRows: rows)
  end

  defp show_message(grid, msg) do
    clear_grid(grid)
    :wxGrid.appendRows(grid, numRows: 1)
    :wxGrid.setCellValue(grid, 0, 0, String.to_charlist(msg))
  end
end
