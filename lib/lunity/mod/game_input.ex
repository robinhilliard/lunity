defmodule Lunity.Mod.GameInput do
  @moduledoc """
  Dispatches mod `on_tick` after each instance simulation tick so `control.lua` can read
  input via `lunity.input.is_key_down/2` and write ECS state via `lunity.entity.*`.

  Only runs when `:mods_enabled` and `Lunity.Mod.EventBus` is running.
  """

  @spec dispatch_tick(term(), float()) :: :ok
  def dispatch_tick(store_id, dt_s) when is_number(dt_s) do
    sid = to_string(store_id)

    if Application.get_env(:lunity, :mods_enabled, false) and
         Process.whereis(Lunity.Mod.EventBus) do
      Lunity.Mod.EventBus.dispatch("on_tick", %{
        store_id: sid,
        dt: dt_s * 1.0
      })
    else
      :ok
    end

    Lunity.Input.Session.clear_actions_for_instance(sid)
  end
end
