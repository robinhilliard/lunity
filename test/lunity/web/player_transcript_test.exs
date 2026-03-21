defmodule Lunity.Web.PlayerTranscriptTest do
  @moduledoc """
  Golden ordered transcript for the player protocol (in-process, no WebSocket).

  Phase 3 uses the same shapes for EAGL/WebGL parity tests.
  """
  use ExUnit.Case, async: false

  alias Lunity.Auth.PlayerJWT
  alias Lunity.Input.Session
  alias Lunity.Web.PlayerMessage

  setup do
    Application.put_env(:lunity, :player_jwt_secret, "jwt-transcript-secret")

    on_exit(fn ->
      Application.delete_env(:lunity, :player_jwt_secret)
    end)

    sid = make_ref()
    :ok = Session.register(sid)

    on_exit(fn ->
      Session.unregister(sid)
    end)

    {:ok, session_id: sid}
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
end
