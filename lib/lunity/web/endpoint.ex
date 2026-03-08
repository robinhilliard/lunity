defmodule Lunity.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :lunity

  socket("/ws/viewer", Lunity.Web.ViewerSocket,
    websocket: true,
    longpoll: false
  )

  plug(Plug.Static,
    at: "/static",
    from: {:lunity, "priv/static"}
  )

  plug(Lunity.Web.Router)
end
