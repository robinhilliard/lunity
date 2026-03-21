defmodule Lunity.Player.WsUrlTest do
  use ExUnit.Case, async: true

  alias Lunity.Player.WsUrl

  test "builds ws URL from http base" do
    assert {:ok, url} = WsUrl.from_base_url("http://127.0.0.1:4111", "sekret")
    assert url == "ws://127.0.0.1:4111/ws/player/websocket?token=sekret"
  end

  test "builds wss URL from https base" do
    assert {:ok, url} = WsUrl.from_base_url("https://example.com", "t")
    # Default HTTPS port is omitted in URI.to_string/1
    assert url == "wss://example.com/ws/player/websocket?token=t"
  end

  test "encodes token for query string" do
    assert {:ok, url} = WsUrl.from_base_url("http://localhost:4000", "a&b=c")
    assert url =~ "token=a%26b%3Dc"
  end

  test "rejects empty token" do
    assert {:error, :bad_ws_token} = WsUrl.from_base_url("http://localhost:4000", "")
  end
end
