defmodule Lunity.Web.PlayerSocketTest do
  use ExUnit.Case, async: false

  alias Lunity.Auth.PlayerJWT
  alias Lunity.Input.{Session, SessionMeta}
  alias Lunity.Web.{PlayerMessage, PlayerSocket}

  setup do
    prev_ws = Application.get_env(:lunity, :player_ws_token)
    prev_jwt = Application.get_env(:lunity, :player_jwt_secret)

    Application.put_env(:lunity, :player_ws_token, "ws-secret")
    Application.put_env(:lunity, :player_jwt_secret, "jwt-test-secret")

    on_exit(fn ->
      restore_env(:lunity, :player_ws_token, prev_ws)
      restore_env(:lunity, :player_jwt_secret, prev_jwt)
    end)

    :ok
  end

  defp restore_env(app, key, prev) do
    if prev == nil do
      Application.delete_env(app, key)
    else
      Application.put_env(app, key, prev)
    end
  end

  defp base_state(session_id) do
    %{
      session_id: session_id,
      params: %{},
      phase: :connected,
      hello_ok: false,
      state_sub: nil,
      state_timer_ref: nil,
      state_interval_ms: 100
    }
  end

  defp sign_jwt(extra) do
    signer = PlayerJWT.signer_from_secret("jwt-test-secret")
    {:ok, token, _} = PlayerJWT.generate_and_sign(extra, signer)
    token
  end

  describe "connect/1 (S4 auth spike)" do
    test "rejects when :player_ws_token is unset" do
      Application.delete_env(:lunity, :player_ws_token)
      assert :error == PlayerSocket.connect(%{params: %{"token" => "x"}})
    end

    test "rejects when :player_ws_token is empty string" do
      Application.put_env(:lunity, :player_ws_token, "")
      assert :error == PlayerSocket.connect(%{params: %{"token" => "x"}})
    end

    test "rejects without matching token" do
      Application.put_env(:lunity, :player_ws_token, "secret")
      assert :error == PlayerSocket.connect(%{params: %{}})
      assert :error == PlayerSocket.connect(%{params: %{"token" => "wrong"}})
    end

    test "accepts when token matches" do
      Application.put_env(:lunity, :player_ws_token, "secret")

      assert {:ok, %{params: %{"token" => "secret"}}} =
               PlayerSocket.connect(%{params: %{"token" => "secret"}})
    end

    test "accepts token from connect_info auth_token when query is empty" do
      Application.put_env(:lunity, :player_ws_token, "secret")

      assert {:ok, %{params: %{}, connect_info: %{auth_token: "secret"}}} =
               PlayerSocket.connect(%{
                 params: %{},
                 connect_info: %{auth_token: "secret"}
               })
    end
  end

  describe "Phase 2 protocol (PlayerMessage)" do
    setup do
      prev_join = Application.get_env(:lunity, :player_join)
      Application.delete_env(:lunity, :player_join)

      sid = make_ref()
      :ok = Session.register(sid)

      on_exit(fn ->
        restore_env(:lunity, :player_join, prev_join)
        Session.unregister(sid)
      end)

      {:ok, session_id: sid}
    end

    test "hello then auth ack", %{session_id: sid} do
      s0 = base_state(sid)

      assert {:ok, [hjson], s1} =
               PlayerMessage.handle_in(~s({"v":1,"t":"hello"}), s0)

      assert %{"t" => "hello_ack"} = Jason.decode!(hjson)
      assert s1.hello_ok == true

      token = sign_jwt(%{"user_id" => "u1", "player_id" => "p1"})

      assert {:ok, [ajson], s2} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{v: 1, t: "auth", token: token}),
                 s1
               )

      assert %{"t" => "ack", "user_id" => "u1", "player_id" => "p1"} = Jason.decode!(ajson)
      assert s2.phase == :authenticated

      meta = Session.get_meta(sid)
      assert meta.user_id == "u1"
      assert meta.player_id == "p1"
    end

    test "auth before hello is rejected", %{session_id: sid} do
      token = sign_jwt(%{"user_id" => "u1"})
      s0 = base_state(sid)

      assert {:ok, [ejson], _s} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{v: 1, t: "auth", token: token}),
                 s0
               )

      assert %{"t" => "error", "code" => "auth_order"} = Jason.decode!(ejson)
    end

    test "join fails when instance does not exist", %{session_id: sid} do
      missing_id = "missing-instance-#{System.unique_integer([:positive])}"
      s0 = base_state(sid) |> Map.put(:hello_ok, true) |> Map.put(:phase, :authenticated)

      assert {:ok, [ejson], _} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{v: 1, t: "join", instance_id: missing_id}),
                 s0
               )

      assert %{"t" => "error", "code" => "instance_not_found"} = Jason.decode!(ejson)
    end

    test "join assigns when instance exists", %{session_id: sid} do
      id = "player_msg_join_test"

      try do
        assert {:ok, _} =
                 Lunity.Instance.start(Lunity.HotReloadTest.Scene,
                   id: id,
                   manager: Lunity.HotReloadTest.Manager
                 )

        s0 = base_state(sid) |> Map.put(:hello_ok, true) |> Map.put(:phase, :authenticated)

        assert {:ok, [json], s1} =
                 PlayerMessage.handle_in(
                   Jason.encode!(%{
                     v: 1,
                     t: "join",
                     instance_id: id,
                     entity_id: "marker",
                     spawn: %{"kind" => "named", "id" => "lobby_a"}
                   }),
                   s0
                 )

        assert %{
                 "t" => "assigned",
                 "instance_id" => ^id,
                 "entity_id" => "marker",
                 "spawn" => %{"kind" => "named", "id" => "lobby_a"}
               } =
                 Jason.decode!(json)

        assert s1.phase == :in_world
        meta = Session.get_meta(sid)
        assert meta.instance_id == id
        assert meta.entity_id == :marker
        assert meta.spawn == %{"kind" => "named", "id" => "lobby_a"}
      after
        if id in Lunity.Instance.list(), do: Lunity.Instance.stop(id)
      end
    end

    test "actions after join stores frame", %{session_id: sid} do
      id = "player_msg_actions_test"

      try do
        assert {:ok, _} =
                 Lunity.Instance.start(Lunity.HotReloadTest.Scene,
                   id: id,
                   manager: Lunity.HotReloadTest.Manager
                 )

        s0 = base_state(sid) |> Map.put(:hello_ok, true) |> Map.put(:phase, :authenticated)

        {:ok, [_], s1} =
          PlayerMessage.handle_in(
            Jason.encode!(%{v: 1, t: "join", instance_id: id, entity_id: "marker"}),
            s0
          )

        assert s1.phase == :in_world

        assert {:ok, [ack], _} =
                 PlayerMessage.handle_in(
                   Jason.encode!(%{
                     v: 1,
                     t: "actions",
                     frame: 7,
                     actions: [
                       %{"entity" => "marker", "op" => "move", "dz" => 1.0}
                     ]
                   }),
                   s1
                 )

        assert %{"t" => "actions_ack", "frame" => 7} = Jason.decode!(ack)

        assert Session.get_actions(sid) == [
                 %{"entity" => "marker", "op" => "move", "dz" => 1.0}
               ]
      after
        if id in Lunity.Instance.list(), do: Lunity.Instance.stop(id)
      end
    end
  end

  describe "join with :player_join callback" do
    setup do
      prev = Application.get_env(:lunity, :player_join)
      Application.put_env(:lunity, :player_join, {Lunity.Web.PlayerJoinStub, :assign})

      sid = make_ref()
      :ok = Session.register(sid)

      on_exit(fn ->
        restore_env(:lunity, :player_join, prev)
        Session.unregister(sid)
      end)

      {:ok, session_id: sid}
    end

    test "join without instance_id uses callback assignment", %{session_id: sid} do
      id = "cb_instance"

      try do
        assert {:ok, _} =
                 Lunity.Instance.start(Lunity.HotReloadTest.Scene,
                   id: id,
                   manager: Lunity.HotReloadTest.Manager
                 )

        meta = Session.get_meta(sid) || %SessionMeta{}
        assert true = Session.update_meta(sid, %{meta | user_id: "u1", player_id: "p1"})

        s0 = base_state(sid) |> Map.put(:hello_ok, true) |> Map.put(:phase, :authenticated)

        assert {:ok, [json], s1} =
                 PlayerMessage.handle_in(Jason.encode!(%{v: 1, t: "join"}), s0)

        assert %{
                 "t" => "assigned",
                 "instance_id" => ^id,
                 "entity_id" => "marker",
                 "spawn" => nil
               } =
                 Jason.decode!(json)

        assert s1.phase == :in_world
      after
        if id in Lunity.Instance.list(), do: Lunity.Instance.stop(id)
      end
    end

    test "join with instance_id is rejected when server assigns", %{session_id: sid} do
      id = "cb_instance"

      try do
        assert {:ok, _} =
                 Lunity.Instance.start(Lunity.HotReloadTest.Scene,
                   id: id,
                   manager: Lunity.HotReloadTest.Manager
                 )

        meta = Session.get_meta(sid) || %SessionMeta{}
        assert true = Session.update_meta(sid, %{meta | user_id: "u1", player_id: "p1"})

        s0 = base_state(sid) |> Map.put(:hello_ok, true) |> Map.put(:phase, :authenticated)

        assert {:ok, [ejson], _} =
                 PlayerMessage.handle_in(
                   Jason.encode!(%{
                     v: 1,
                     t: "join",
                     instance_id: "any",
                     hints: %{"mode" => "solo"}
                   }),
                   s0
                 )

        assert %{"t" => "error", "code" => "join_forbidden"} = Jason.decode!(ejson)
      after
        if id in Lunity.Instance.list(), do: Lunity.Instance.stop(id)
      end
    end

    test "join passes client payload as hints", %{session_id: sid} do
      id = "cb_instance"

      try do
        assert {:ok, _} =
                 Lunity.Instance.start(Lunity.HotReloadTest.Scene,
                   id: id,
                   manager: Lunity.HotReloadTest.Manager
                 )

        meta = Session.get_meta(sid) || %SessionMeta{}
        assert true = Session.update_meta(sid, %{meta | user_id: "u1", player_id: "p1"})

        s0 = base_state(sid) |> Map.put(:hello_ok, true) |> Map.put(:phase, :authenticated)

        assert {:ok, [_json], _} =
                 PlayerMessage.handle_in(
                   Jason.encode!(%{v: 1, t: "join", hints: %{"mode" => "solo"}}),
                   s0
                 )
      after
        if id in Lunity.Instance.list(), do: Lunity.Instance.stop(id)
      end
    end
  end

  describe "encode_state_frame/2" do
    test "includes ecs snapshot for running instance" do
      id = "player_msg_state_test"

      try do
        assert {:ok, _} =
                 Lunity.Instance.start(Lunity.HotReloadTest.Scene,
                   id: id,
                   manager: Lunity.HotReloadTest.Manager
                 )

        json = PlayerMessage.encode_state_frame(id, nil)
        assert %{"v" => 1, "t" => "state", "filter" => nil, "ecs" => ecs} = Jason.decode!(json)
        assert is_map(ecs)
      after
        if id in Lunity.Instance.list(), do: Lunity.Instance.stop(id)
      end
    end
  end
end

defmodule Lunity.Web.PlayerJoinStub do
  @behaviour Lunity.Web.PlayerJoin

  @impl true
  def assign(%{client: client}) do
    _ = client
    {:ok, "cb_instance", :marker, nil}
  end
end
