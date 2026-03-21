defmodule Lunity.Web.PlayerTranscriptTest do
  @moduledoc """
  Golden ordered transcript for the player protocol (in-process, no WebSocket).

  Phase 3 uses the same shapes for EAGL/WebGL parity tests (bootstrap, `subscribe_state`,
  `actions`, **`auth` + `resume`**). See also `player_socket_integration_test.exs` for Bandit + WebSockex.
  """
  use ExUnit.Case, async: false

  alias Lunity.Auth.PlayerJWT
  alias Lunity.Input.{Session, SessionMeta}
  alias Lunity.Player.Resume
  alias Lunity.Web.PlayerMessage

  setup do
    Application.put_env(:lunity, :player_jwt_secret, "jwt-transcript-secret")

    on_exit(fn ->
      Application.delete_env(:lunity, :player_jwt_secret)
    end)

    :ok
  end

  defp sign(extra) do
    signer = PlayerJWT.signer_from_secret("jwt-transcript-secret")
    {:ok, token, _} = PlayerJWT.generate_and_sign(extra, signer)
    token
  end

  defp base(sid) do
    %{
      session_id: sid,
      params: %{},
      phase: :connected,
      hello_ok: false,
      state_sub: nil,
      state_timer_ref: nil,
      state_interval_ms: 100
    }
  end

  describe "session bootstrap (single connection)" do
    setup do
      sid = make_ref()
      :ok = Session.register(sid)

      on_exit(fn ->
        Session.unregister(sid)
      end)

      {:ok, session_id: sid}
    end

    test "golden transcript: welcome path through auth (simulated)", %{session_id: sid} do
      s0 = base(sid)

      assert {:ok, [hello_ack], s1} = PlayerMessage.handle_in(~s({"v":1,"t":"hello"}), s0)
      assert Jason.decode!(hello_ack)["t"] == "hello_ack"
      assert s1.hello_ok == true

      token = sign(%{"user_id" => "u_golden", "player_id" => "p_golden"})

      assert {:ok, [ack], s2} =
               PlayerMessage.handle_in(Jason.encode!(%{v: 1, t: "auth", token: token}), s1)

      assert %{"t" => "ack", "user_id" => "u_golden"} = Jason.decode!(ack)
      assert s2.phase == :authenticated
    end

    test "actions without op is rejected", %{session_id: sid} do
      s =
        base(sid)
        |> Map.put(:hello_ok, true)
        |> Map.put(:phase, :in_world)

      assert {:ok, [err], _} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{v: 1, t: "actions", actions: [%{"entity" => "e"}], frame: 1}),
                 s
               )

      assert %{"t" => "error", "code" => "bad_actions"} = Jason.decode!(err)
    end

    test "golden transcript: subscribe_state and actions after simulated join", %{session_id: sid} do
      s0 = base(sid)

      assert {:ok, [_hello_ack], s1} = PlayerMessage.handle_in(~s({"v":1,"t":"hello"}), s0)
      token = sign(%{"user_id" => "u_golden", "player_id" => "p_golden"})

      assert {:ok, [_ack], s2} =
               PlayerMessage.handle_in(Jason.encode!(%{v: 1, t: "auth", token: token}), s1)

      assert s2.phase == :authenticated

      meta = Session.get_meta(sid) || %SessionMeta{}

      assert true =
               Session.update_meta(sid, %{
                 meta
                 | instance_id: "golden_inst",
                   entity_id: :paddle_left
               })

      s3 = Map.put(s2, :phase, :in_world)

      assert {:ok, [sub_ack], s4} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{v: 1, t: "subscribe_state", filter: nil}),
                 s3
               )

      sub = Jason.decode!(sub_ack)
      assert sub["t"] == "subscribe_ack"
      assert sub["filter"] == nil

      assert sub["interval_ms"] ==
               Application.get_env(:lunity, :player_state_push_interval_ms, 100)

      assert s4.state_sub != nil

      assert {:ok, [act_ack], _s5} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{
                   v: 1,
                   t: "actions",
                   frame: 42,
                   actions: [%{"op" => "move", "entity" => "paddle_left", "dz" => 0.5}]
                 }),
                 s4
               )

      act = Jason.decode!(act_ack)
      assert act["t"] == "actions_ack"
      assert act["frame"] == 42
    end
  end

  describe "resume transcript (two logical connections)" do
    test "golden transcript: resume ack echoes instance_id entity_id spawn" do
      token = sign(%{"user_id" => "u_golden", "player_id" => "p_golden"})
      sid1 = make_ref()
      :ok = Session.register(sid1)

      s0 = base(sid1)
      assert {:ok, [_], s1} = PlayerMessage.handle_in(~s({"v":1,"t":"hello"}), s0)

      assert {:ok, [_], _s2} =
               PlayerMessage.handle_in(Jason.encode!(%{v: 1, t: "auth", token: token}), s1)

      meta = Session.get_meta(sid1) || %SessionMeta{}

      assert true =
               Session.update_meta(sid1, %{
                 meta
                 | instance_id: "golden_inst",
                   entity_id: :paddle_left,
                   spawn: %{"kind" => "named", "id" => "lobby_a"}
               })

      :ok = Resume.register_disconnect("p_golden", sid1)

      sid2 = make_ref()
      :ok = Session.register(sid2)

      on_exit(fn ->
        _ = Resume.clear_pending("p_golden")
        Session.unregister(sid1)
        Session.unregister(sid2)
      end)

      t0 = base(sid2)
      assert {:ok, [_], t1} = PlayerMessage.handle_in(~s({"v":1,"t":"hello"}), t0)

      assert {:ok, [ack_json], t2} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{v: 1, t: "auth", token: token, resume: true}),
                 t1
               )

      ack = Jason.decode!(ack_json)

      assert %{
               "t" => "ack",
               "resumed" => true,
               "user_id" => "u_golden",
               "player_id" => "p_golden",
               "instance_id" => "golden_inst",
               "entity_id" => "paddle_left",
               "spawn" => %{"kind" => "named", "id" => "lobby_a"}
             } = ack

      assert t2.phase == :in_world
      assert Session.get_meta(sid1) == nil

      meta2 = Session.get_meta(sid2)
      assert meta2.instance_id == "golden_inst"
    end

    test "golden transcript: resume with no pending session" do
      sid = make_ref()
      :ok = Session.register(sid)
      token = sign(%{"user_id" => "u_golden", "player_id" => "p_golden"})
      s0 = base(sid) |> Map.put(:hello_ok, true)

      on_exit(fn -> Session.unregister(sid) end)

      assert {:ok, [err_json], _} =
               PlayerMessage.handle_in(
                 Jason.encode!(%{v: 1, t: "auth", token: token, resume: true}),
                 s0
               )

      assert %{"t" => "error", "code" => "resume_failed"} = Jason.decode!(err_json)
    end
  end
end
