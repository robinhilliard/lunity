defmodule Lunity.Web.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  forward "/",
    to: ExMCP.HttpPlug,
    init_opts: [
      handler: Lunity.MCP.Server,
      server_info: %{name: "lunity", version: "0.1.0"},
      sse_enabled: true,
      cors_enabled: true
    ]
end
