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

  @doc "Create the inspector panel as a child of `parent`. Returns the widget."
  def create(parent) do
    panel = :wxPanel.new(parent)
    :wxWindow.setMinSize(panel, {@inspector_width, -1})
    :wxWindow.setBackgroundColour(panel, {245, 245, 245})

    sizer = :wxBoxSizer.new(@wx_vertical)

    label = :wxStaticText.new(panel, -1, ~c"Inspector")
    font = :wxFont.new(12, 70, 90, 92)
    :wxStaticText.setFont(label, font)
    :wxSizer.add(sizer, label, flag: @wx_expand ||| Bitwise.bsl(1, 6), border: 6)

    grid = :wxGrid.new(panel, -1)
    :wxGrid.createGrid(grid, 0, 2)
    :wxGrid.setColLabelValue(grid, 0, ~c"Component")
    :wxGrid.setColLabelValue(grid, 1, ~c"Value")
    :wxGrid.setRowLabelSize(grid, 0)
    :wxGrid.setColSize(grid, 0, 120)
    :wxGrid.setColSize(grid, 1, 130)
    :wxGrid.enableEditing(grid, false)
    :wxWindow.setBackgroundColour(grid, {255, 255, 255})

    :wxSizer.add(sizer, grid, proportion: 1, flag: @wx_expand ||| Bitwise.bsl(1, 6), border: 4)
    :wxPanel.setSizer(panel, sizer)

    State.put_inspector(grid)
    panel
  end

  @doc "Refresh the inspector with component data for the currently selected entity."
  def refresh do
    grid = State.get_inspector()
    unless grid, do: throw(:no_inspector)

    case State.get_selection() do
      {:instance_entity, instance_id, entity_id} ->
        refresh_entity(grid, instance_id, entity_id)

      {:scene_node, _name, _aabb} ->
        show_message(grid, "(scene node selected)")

      _ ->
        show_message(grid, "(no entity selected)")
    end
  catch
    :no_inspector -> :ok
  end

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

    clear_grid(grid)

    if rows == [] do
      show_message(grid, "(no components)")
    else
      :wxGrid.appendRows(grid, numRows: length(rows))

      Enum.with_index(rows, fn {name, value}, idx ->
        :wxGrid.setCellValue(grid, idx, 0, String.to_charlist(name))
        :wxGrid.setCellValue(grid, idx, 1, String.to_charlist(value))
      end)

      :wxGrid.autoSizeColumns(grid)
    end
  catch
    :done -> :ok
  end

  defp format_value(val, _opts) when is_tuple(val) do
    val
    |> Tuple.to_list()
    |> Enum.map(&format_number/1)
    |> Enum.join(", ")
  end

  defp format_value(val, _opts) when is_number(val), do: format_number(val)
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
