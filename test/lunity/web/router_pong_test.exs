defmodule Lunity.Web.RouterPongTest do
  use ExUnit.Case, async: true

  test "GET /pong 404 when host app has no pong_gl.html" do
    conn =
      :get
      |> Plug.Test.conn("/pong")
      |> Lunity.Web.Router.call(Lunity.Web.Router.init([]))

    assert conn.status == 404
  end
end
