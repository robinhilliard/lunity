defmodule Lunity.Player.StateWindow do
  @moduledoc false

  use WX.Const

  alias Lunity.Player.{Connect, WsClient, WsUrl}

  @wx_te_multiline 0x0020
  # Same numeric value as `wxVERTICAL` for `getScrollPos` / `setScrollPos` (wxOrientation).
  @wx_orient_vertical 8

  @doc """
  Opens a wx window and streams `state` frames (`ecs` JSON) from `PlayerSocket`
  after the same bootstrap as `mix lunity.player` with `stream_state` enabled.
  """
  @spec run(map()) :: :ok
  def run(opts) do
    _ = :application.start(:wx)
    wx = :wx.new()
    frame = :wxFrame.new(wx, -1, ~c"Lunity player — live ECS state", size: {780, 560})
    panel = :wxPanel.new(frame)
    text = :wxTextCtrl.new(panel, -1, value: ~c"Connecting…", style: @wx_te_multiline)
    # `wxTE_READONLY` can block reliable clears on some platforms; use non-editable instead.
    :wxTextCtrl.setEditable(text, false)
    inner = :wxBoxSizer.new(@wx_vertical)
    :wxSizer.add(inner, text, proportion: 1, flag: @wx_expand, border: 4)
    :wxPanel.setSizer(panel, inner)
    outer = :wxBoxSizer.new(@wx_vertical)
    :wxSizer.add(outer, panel, proportion: 1, flag: @wx_expand)
    :wxFrame.setSizer(frame, outer)
    :wxFrame.connect(frame, :close_window)
    :wxFrame.center(frame)
    :wxFrame.show(frame)

    receive do
      {:wx, _, _, _, {:wxShow, :show}} -> :ok
    after
      1000 -> :ok
    end

    Process.sleep(150)

    _result =
      with {:ok, ws_token} <- Connect.ws_token(opts),
           {:ok, ws_url} <- WsUrl.from_base_url(opts.url, ws_token),
           {:ok, jwt} <- Connect.resolve_jwt(opts),
           {:ok, hints} <- Connect.parse_hints(opts[:hints]) do
        parent = self()
        insecure = opts[:secure] != true

        ws_state = %{
          parent: parent,
          jwt: jwt,
          hints: hints,
          auth_only: false,
          followup: true,
          resume: opts[:resume] == true,
          stream_state: true,
          assigned_row: nil,
          subscribe_ack: nil,
          phase: :welcome,
          verbose: opts[:verbose] == true
        }

        case WsClient.start_link(ws_url, ws_state, insecure: insecure) do
          {:ok, ws_pid} ->
            ref = Process.monitor(ws_pid)
            set_text(text, "Connected — handshake…")
            loop(frame, text, ws_pid, ref, 0)

          {:error, reason} ->
            set_text(text, "WebSocket failed: #{inspect(reason)}")
            wait_close(frame)
        end
      else
        {:error, reason} ->
          set_text(text, connect_error_text(reason))
          wait_close(frame)
      end

    try do
      :wxFrame.destroy(frame)
    rescue
      _ -> :ok
    end

    try do
      :application.stop(:wx)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp connect_error_text(msg) when is_binary(msg), do: msg
  defp connect_error_text(:bad_scheme), do: "Invalid --url scheme (use http, https, ws, or wss)"
  defp connect_error_text(:bad_host), do: "Invalid --url (missing host)"
  defp connect_error_text(:bad_ws_token), do: "WebSocket token is empty"
  defp connect_error_text(other), do: "Connect error: #{inspect(other)}"

  defp set_text(ctrl, str) when is_binary(str) do
    :wxTextCtrl.setValue(ctrl, String.to_charlist(str))
  end

  @doc false
  # Each `setValue` resets the macOS scroll position to the top. State arrives ~10×/s, so the
  # user could never “win” against the scrollbar. Save vertical scroll **before** replace and
  # restore after (clamped to the new range).
  defp tick_set_text(ctrl, str) when is_binary(str) do
    cl = String.to_charlist(str)
    orient = @wx_orient_vertical

    :wx.batch(fn ->
      old_pos =
        try do
          :wxTextCtrl.getScrollPos(ctrl, orient)
        rescue
          _ -> 0
        end

      :wxTextCtrl.setValue(ctrl, cl)

      range =
        try do
          :wxTextCtrl.getScrollRange(ctrl, orient)
        rescue
          _ -> 0
        end

      # Thumb size tracks document height; ~45KB pretty JSON is one tick — thumb stays small.
      pos = old_pos |> max(0) |> min(max(0, range - 1))

      try do
        :wxTextCtrl.setScrollPos(ctrl, orient, pos)
      rescue
        _ -> :ok
      end
    end)
  end

  defp loop(frame, text, ws_pid, ref, n) do
    receive do
      {:wx, _, _, _, {:wxClose, :close_window}} ->
        Process.exit(ws_pid, :shutdown)
        :ok

      {:wx, _, _, _, _} ->
        loop(frame, text, ws_pid, ref, n)

      {:lunity_player, {:state, m}} ->
        ecs = Map.get(m, "ecs", %{})
        body =
          case ecs do
            %{} = e -> Jason.encode!(e, pretty: true)
            other -> inspect(other)
          end

        hdr = "tick #{n + 1} — ecs snapshot (#{byte_size(body)} bytes)\n\n"
        tick_set_text(text, hdr <> body)
        loop(frame, text, ws_pid, ref, n + 1)

      {:lunity_player, {:ready, _sub}} ->
        set_text(
          text,
          """
          Subscribed — receiving periodic `state` frames (`ecs` JSON).

          If node positions never change: with `mix lunity.edit`, the editor often **pauses** the watched instance (transport ⏸, or picking an entity). Press **Play (▶)** so the instance status is **running** and physics ticks.

          One snapshot is a large pretty-printed JSON (~tens of KB), so the thumb looks small. Scroll position is kept when each new snapshot arrives (otherwise macOS resets to the top every ~100ms).
          """
          |> String.trim()
        )

        _ = :wx.batch(fn -> :wxWindow.setFocus(text) end)
        loop(frame, text, ws_pid, ref, n)

      {:lunity_player, {:error, e}} ->
        set_text(text, "Error: #{inspect(e)}")
        loop(frame, text, ws_pid, ref, n)

      {:lunity_player, {:ok, other}} ->
        set_text(text, "Unexpected: #{inspect(other)}")
        loop(frame, text, ws_pid, ref, n)

      {:DOWN, ^ref, :process, _, reason} ->
        set_text(text, "WebSocket exited: #{inspect(reason)}")
        wait_close(frame)
    end
  end

  defp wait_close(frame) do
    receive do
      {:wx, _, _, _, {:wxClose, :close_window}} -> :ok
      {:wx, _, _, _, _} -> wait_close(frame)
    end
  end
end
