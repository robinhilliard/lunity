defmodule Lunity.Web.PlayerSocketTest do
  use ExUnit.Case, async: false

  alias Lunity.Auth.PlayerJWT
  alias Lunity.Input.{Session, SessionMeta}
  alias Lunity.Player.Resume
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

  describe "resume auth" do
    setup do
      prev_join = Application.get_env(:lunity, :player_join)
      Application.delete_env(:lunity, :player_join)

      on_exit(fn ->
        restore_env(:lunity, :player_join, prev_join)
      end)

      :ok
    end

    test "auth with resume:true clones session and sets resumed in ack" do
      sid1 = make_ref()
      :ok = Session.register(sid1)
      token = sign_jwt(%{"user_id" => "u1", "player_id" => "p1"})

      s0 = base_state(sid1)
      assert {:ok, [_], s1} = PlayerMessage.handle_in(~s({"v":1,"t":"hello"}), s0)

      assert {:ok, [_], _s2} =
               PlayerMessage.handle_in(Jason.encode!(%{v: 1, t: "auth", token: token}), s1)

      meta = Session.get_meta(sid1)
      true = Session.update_meta(sid1, %{meta | instance_id: "inst-resume", entity_id: :paddle})

      :ok =
        Session.put_actions(sid1, [
          %{"entity" => "paddle", "op" => "move", "dz" => 0.25}
        ])

      :ok = Resume.register_disconnect("p1", sid1)

      sid2 = make_ref()
      :ok = Session.register(sid2)
      t0 = base_state(sid2)

      assert {:ok, [_], t1} = PlayerMessage.handle_in(~s({"v":1,"t":"hello"}), t0)

      assert {:ok, [ajson], t2} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{v: 1, t: "auth", token: token, resume: true}),
                 t1
               )

      ack = Jason.decode!(ajson)

      assert %{
               "t" => "ack",
               "resumed" => true,
               "player_id" => "p1",
               "instance_id" => "inst-resume"
             } = ack

      assert t2.phase == :in_world

      meta2 = Session.get_meta(sid2)
      assert meta2.instance_id == "inst-resume"
      assert meta2.entity_id == :paddle

      assert Session.get_actions(sid2) == [
               %{"entity" => "paddle", "op" => "move", "dz" => 0.25}
             ]

      assert Session.get_meta(sid1) == nil

      Session.unregister(sid2)
    end

    test "auth with resume:true and no pending fails" do
      sid = make_ref()
      :ok = Session.register(sid)
      token = sign_jwt(%{"user_id" => "u1", "player_id" => "p1"})
      s0 = base_state(sid) |> Map.put(:hello_ok, true)

      assert {:ok, [ejson], _} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{v: 1, t: "auth", token: token, resume: true}),
                 s0
               )

      assert %{"t" => "error", "code" => "resume_failed"} = Jason.decode!(ejson)
      Session.unregister(sid)
    end
  end

  describe "PlayerSocket.terminate/2 (disconnect path)" do
    test "with player_id in session meta, registers Resume and leaves ETS session until grace or take" do
      player_id = "p_term_#{System.unique_integer([:positive])}"
      sid = make_ref()
      :ok = Session.register(sid)

      meta = Session.get_meta(sid) || %SessionMeta{}
      true = Session.update_meta(sid, %{meta | user_id: "u", player_id: player_id})

      on_exit(fn ->
        _ = Resume.clear_pending(player_id)
        Session.unregister(sid)
      end)

      state =
        base_state(sid)
        |> Map.put(:phase, :authenticated)
        |> Map.put(:hello_ok, true)

      assert :ok = PlayerSocket.terminate(:normal, state)

      assert Session.get_meta(sid) != nil
      assert {:ok, ^sid} = Resume.take(player_id)
    end

    test "without player_id, unregisters ETS session" do
      sid = make_ref()
      :ok = Session.register(sid)

      on_exit(fn -> Session.unregister(sid) end)

      state = base_state(sid)

      assert :ok = PlayerSocket.terminate(:normal, state)

      assert Session.get_meta(sid) == nil
    end

    test "grace timer unregisters ETS session when no resume" do
      prev_grace = Application.get_env(:lunity, :player_reconnect_grace_ms)
      Application.put_env(:lunity, :player_reconnect_grace_ms, 50)

      player_id = "p_grace_#{System.unique_integer([:positive])}"
      sid = make_ref()
      :ok = Session.register(sid)

      meta = Session.get_meta(sid) || %SessionMeta{}
      true = Session.update_meta(sid, %{meta | user_id: "u", player_id: player_id})

      on_exit(fn ->
        Application.put_env(:lunity, :player_reconnect_grace_ms, prev_grace)
        _ = Resume.clear_pending(player_id)
        Session.unregister(sid)
      end)

      state =
        base_state(sid)
        |> Map.put(:phase, :authenticated)
        |> Map.put(:hello_ok, true)

      assert :ok = PlayerSocket.terminate(:normal, state)
      assert Session.get_meta(sid) != nil

      Process.sleep(120)
      assert Session.get_meta(sid) == nil
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
