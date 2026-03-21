defmodule Lunity.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :lunity

  socket("/ws/viewer", Lunity.Web.ViewerSocket,
    websocket: true,
    longpoll: false
  )

  socket("/ws/player", Lunity.Web.PlayerSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.Static,
    at: "/static",
    from: {:lunity, "priv/static"}
  )

  plug(:track_sse)
  plug(Lunity.Web.Router)

  defp track_sse(%{method: "GET", path_info: path} = conn, _opts)
       when path == ["sse"] or path == ["mcp", "v1", "sse"] do
    Lunity.Web.ConnectionReaper.track(self())
    conn
  end

  defp track_sse(conn, _opts), do: conn
end
