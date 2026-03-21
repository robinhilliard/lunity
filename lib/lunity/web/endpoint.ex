defmodule Lunity.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :lunity

  socket("/ws/viewer", Lunity.Web.ViewerSocket,
    # `:conn` — allow Origin to match the HTTP host (e.g. 127.0.0.1 vs localhost).
    # Default `true` compares against `endpoint url` host only and breaks when the
    # page is opened at 127.0.0.1 while config says localhost.
    websocket: [check_origin: :conn],
    longpoll: false
  )

  socket("/ws/player", Lunity.Web.PlayerSocket,
    websocket: [
      check_origin: :conn,
      auth_token: true,
      connect_info: [:uri, :auth_token]
    ],
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
