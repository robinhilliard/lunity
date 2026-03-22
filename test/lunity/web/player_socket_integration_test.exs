defmodule Lunity.Web.PlayerSocketIntegrationTest do
  use ExUnit.Case, async: false

  alias Lunity.Auth.PlayerJWT
  alias Lunity.Input.SessionMeta
  alias Lunity.Web.{PlayerSocketIntegrationClient, PlayerWire}

  setup do
    port = 35000 + rem(:erlang.phash2({:player_ws_integration, self()}), 5000)
    prev_ws = Application.get_env(:lunity, :player_ws_token)
    prev_jwt = Application.get_env(:lunity, :player_jwt_secret)

    Application.put_env(:lunity, :player_ws_token, "ws-secret-int")
    Application.put_env(:lunity, :player_jwt_secret, "jwt-int-secret")

    Application.put_env(:lunity, Lunity.Web.Endpoint,
      http: [ip: {127, 0, 0, 1}, port: port],
      server: true,
      secret_key_base: String.duplicate("a", 64)
    )

    {:ok, _} = Application.ensure_all_started(:ssl)
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:phoenix)

    _endpoint_pid =
      case Lunity.Web.Endpoint.start_link([]) do
        {:ok, p} -> p
        {:error, {:already_started, p}} -> p
      end

    on_exit(fn ->
      _ = Supervisor.stop(Lunity.Web.Endpoint, :shutdown, 5000)
      restore_env(:lunity, :player_ws_token, prev_ws)
      restore_env(:lunity, :player_jwt_secret, prev_jwt)
    end)

    {:ok, port: port}
  end

  defp restore_env(app, key, prev) do
    if prev == nil do
      Application.delete_env(app, key)
    else
      Application.put_env(app, key, prev)
    end
  end

  defp ws_url(port) do
    "ws://127.0.0.1:#{port}/ws/player/websocket?token=ws-secret-int"
  end

  defp sign_jwt(extra) do
    signer = PlayerJWT.signer_from_secret("jwt-int-secret")
    {:ok, token, _} = PlayerJWT.generate_and_sign(extra, signer)
    token
  end

  defp recv_json do
    receive do
      {:player_ws_text, msg} -> Jason.decode!(msg)
    after
      3000 -> flunk("timeout waiting for WebSocket frame")
    end
  end

  defp recv_raw do
    receive do
      {:player_ws_text, msg} -> msg
    after
      3000 -> flunk("timeout waiting for WebSocket frame")
    end
  end

  defp send_json(ws, map) do
    :ok = WebSockex.send_frame(ws, {:text, Jason.encode!(map)})
  end

  test "disconnect then auth resume with same JWT restores instance via ack", %{port: port} do
    id = "player_ws_int_#{System.unique_integer([:positive])}"
    jwt = sign_jwt(%{"user_id" => "u1", "player_id" => "p_int"})

    try do
      assert {:ok, _} =
               Lunity.Instance.start(Lunity.HotReloadTest.Scene,
                 id: id,
                 manager: Lunity.HotReloadTest.Manager
               )

      url = ws_url(port)

      {:ok, ws1} = WebSockex.start(url, PlayerSocketIntegrationClient, self(), [])
      m1 = Process.monitor(ws1)

      assert %{"t" => "welcome"} = recv_json()
      send_json(ws1, %{v: 1, t: "hello"})
      assert %{"t" => "hello_ack"} = recv_json()
      send_json(ws1, %{v: 1, t: "auth", token: jwt})
      assert %{"t" => "ack", "user_id" => "u1"} = recv_json()

      send_json(ws1, %{
        v: 1,
        t: "join",
        instance_id: id,
        entity_id: "marker",
        spawn: %{"kind" => "named", "id" => "lobby_a"}
      })

      assert %{"t" => "assigned", "instance_id" => ^id} = recv_json()
      :ok = WebSockex.cast(ws1, :close)

      assert_receive {:DOWN, ^m1, :process, ^ws1, _}

      {:ok, ws2} = WebSockex.start(url, PlayerSocketIntegrationClient, self(), [])
      m2 = Process.monitor(ws2)

      assert %{"t" => "welcome"} = recv_json()
      send_json(ws2, %{v: 1, t: "hello"})
      assert %{"t" => "hello_ack"} = recv_json()
      send_json(ws2, %{v: 1, t: "auth", token: jwt, resume: true})

      ack_raw = recv_raw()

      expected_resume_ack =
        Jason.encode!(
          PlayerWire.resume_ack_map(
            "u1",
            "p_int",
            %SessionMeta{
              instance_id: id,
              entity_id: :marker,
              spawn: %{"kind" => "named", "id" => "lobby_a"}
            }
          )
        )

      assert ack_raw == expected_resume_ack

      :ok = WebSockex.cast(ws2, :close)
      assert_receive {:DOWN, ^m2, :process, ^ws2, _}
    after
      if id in Lunity.Instance.list(), do: Lunity.Instance.stop(id)
    end
  end
end
