defmodule Lunity.Web.PlayerSocketIntegrationClient do
  @moduledoc false
  use WebSockex

  @impl true
  def handle_frame({:text, msg}, parent) do
    send(parent, {:player_ws_text, msg})
    {:ok, parent}
  end

  @impl true
  def handle_cast(:close, parent), do: {:close, parent}

  @impl true
  def handle_cast({:send, frame}, parent), do: {:reply, frame, parent}
end
