defmodule Lunity.Editor.Inspector do
  @moduledoc """
  Right-side inspector panel showing component values for the selected entity.

  Uses a wxListCtrl in report mode with Component and Value columns.
  Updates are polled from the render loop when an instance entity is selected.
  """

  use WX.Const
  import Bitwise

  alias Lunity.Editor.State
  alias Lunity.ComponentStore

  @inspector_width 260
  @wx_lc_report 0x0020

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

    list = :wxListCtrl.new(panel, style: @wx_lc_report ||| @wx_sunken_border)
    :wxListCtrl.insertColumn(list, 0, ~c"Component", width: 130)
    :wxListCtrl.insertColumn(list, 1, ~c"Value", width: 120)
    :wxWindow.setBackgroundColour(list, {255, 255, 255})

    :wxSizer.add(sizer, list, proportion: 1, flag: @wx_expand ||| Bitwise.bsl(1, 6), border: 4)
    :wxPanel.setSizer(panel, sizer)

    State.put_inspector(list)
    panel
  end

  @doc "Refresh the inspector with component data for the currently selected entity."
  def refresh do
    list = State.get_inspector()
    unless list, do: throw(:no_inspector)

    case State.get_selection() do
      {:instance_entity, instance_id, entity_id} ->
        refresh_entity(list, instance_id, entity_id)

      {:scene_node, _name, _aabb} ->
        show_message(list, "(scene node selected)")

      _ ->
        show_message(list, "(no entity selected)")
    end
  catch
    :no_inspector -> :ok
  end

  defp refresh_entity(list, instance_id, entity_id) do
    instance = Lunity.Instance.get(instance_id)

    store_id =
      case instance do
        %{store_id: sid} -> sid
        _ -> nil
      end

    unless store_id do
      show_message(list, "(instance not found)")
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

    :wxListCtrl.deleteAllItems(list)

    if rows == [] do
      show_message(list, "(no components)")
    else
      Enum.with_index(rows, fn {name, value}, idx ->
        :wxListCtrl.insertItem(list, idx, String.to_charlist(name))
        :wxListCtrl.setItem(list, idx, 1, String.to_charlist(value))
      end)
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

  defp show_message(list, msg) do
    :wxListCtrl.deleteAllItems(list)
    :wxListCtrl.insertItem(list, 0, String.to_charlist(msg))
  end
end
