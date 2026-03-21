defmodule Lunity.Web.PlayerTokenTest do
  use ExUnit.Case, async: false

  alias Lunity.Auth.PlayerJWT

  setup do
    prev_mint = Application.get_env(:lunity, :player_mint_secret)
    prev_jwt = Application.get_env(:lunity, :player_jwt_secret)

    Application.put_env(:lunity, :player_mint_secret, "mint-key")
    Application.put_env(:lunity, :player_jwt_secret, "jwt-signing-secret")

    on_exit(fn ->
      restore(:lunity, :player_mint_secret, prev_mint)
      restore(:lunity, :player_jwt_secret, prev_jwt)
    end)

    :ok
  end

  defp restore(app, key, prev) do
    if prev == nil,
      do: Application.delete_env(app, key),
      else: Application.put_env(app, key, prev)
  end

  test "returns 404 when mint is disabled" do
    Application.delete_env(:lunity, :player_mint_secret)

    conn =
      :post
      |> Plug.Test.conn("/api/player/token", Jason.encode!(%{"user_id" => "u1"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = Lunity.Web.PlayerToken.call(conn, [])
    assert conn.status == 404
  end

  test "returns 401 without mint header" do
    Application.put_env(:lunity, :player_mint_secret, "mint-key")

    conn =
      :post
      |> Plug.Test.conn("/api/player/token", Jason.encode!(%{"user_id" => "u1"}))
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn = Lunity.Web.PlayerToken.call(conn, [])
    assert conn.status == 401
  end

  test "mints JWT when mint key matches" do
    Application.put_env(:lunity, :player_mint_secret, "mint-key")

    conn =
      :post
      |> Plug.Test.conn(
        "/api/player/token",
        Jason.encode!(%{"user_id" => "alice", "player_id" => "p99"})
      )
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("x-player-mint-key", "mint-key")

    conn = Lunity.Web.PlayerToken.call(conn, [])
    assert conn.status == 200
    assert %{"token" => token} = Jason.decode!(conn.resp_body)
    assert is_binary(token)

    assert {:ok, claims} = PlayerJWT.verify_and_validate_token(token)
    assert claims["user_id"] == "alice"
    assert claims["player_id"] == "p99"
  end
end
