defmodule Lunity.Web.RouterPlayerTest do
  use ExUnit.Case, async: true

  import Plug.Conn, only: [get_resp_header: 2]

  test "GET /player serves parity shell HTML" do
    conn =
      :get
      |> Plug.Test.conn("/player")
      |> Lunity.Web.Router.call(Lunity.Web.Router.init([]))

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
    assert conn.resp_body =~ "player_shell.js"
    assert conn.resp_body =~ "Lunity Player"
  end
end
