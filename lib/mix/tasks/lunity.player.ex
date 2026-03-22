defmodule Mix.Tasks.Lunity.Player do
  @shortdoc "Headless Player WebSocket client (bootstrap → auth → optional join)"
  @moduledoc """
  Connects to a running game server's `Lunity.Web.PlayerSocket` using the same
  transcript as the browser: `welcome` → `hello` → `hello_ack` → `auth` → `ack`,
  then `join` → `assigned`, then by default **`subscribe_state`** and **`actions`** (same as
  `/player` in the browser). Use **`--skip-followup`** to stop after **`assigned`** (legacy
  one-line output). **`--verbose`** logs the full transcript on stderr.

  ## Examples

  With a JWT (e.g. from your auth layer):

      mix lunity.player --url http://127.0.0.1:4111 --token \"$PLAYER_WS_TOKEN\" --jwt \"$JWT\"

  Mint a dev JWT via `POST /api/player/token` (requires `:player_mint_secret` on the server):

      mix lunity.player --url http://127.0.0.1:4111 --token \"$PLAYER_WS_TOKEN\" \\
        --mint-key \"$MINT_KEY\" --user-id u1 --player-id p1

  After **`auth`**, this task sends **`join`** with **only** optional **`hints`** — the game
  assigns `instance_id` / `entity_id` / `spawn` via `config :lunity, :player_join` (not via CLI).
  The **server** must have been started from a Mix project that sets that (e.g. run
  `mix lunity.edit` from your **game** repo, not from `lunity` alone — otherwise the
  endpoint uses client-driven join and you get `bad_join` / `instance_id required`).

      mix lunity.player ... --hints '{"queue":"ranked"}'

  Auth only (no `join`), e.g. testing mint + handshake:

      mix lunity.player ... --auth-only

  Stop after `assigned` (no subscribe/actions; stdout is the `assigned` JSON):

      mix lunity.player ... --skip-followup

  Reconnect within the server grace window (same JWT; sends `auth` with `resume: true`). If the
  server **`ack`** includes **`resumed`** and **`instance_id`**, this task skips **`join`** and
  sends **`subscribe_state`** (same as the browser shell with `resume=1`).

  Environment:

  - `PLAYER_WS_TOKEN` — used when `--token` is omitted (must match server `:player_ws_token`).

  This task loads config and starts only **Req + WebSockex** (and their deps). It does **not**
  run `app.start`, so from a game project it will not boot the host application (no wx/EAGL,
  no `Pong.Application`, no TrackIR NIF load noise from a full Lunity start).
  """
  use Mix.Task

  alias Lunity.Player.{Connect, WsClient, WsUrl}

  @impl Mix.Task
  def run(argv) do
    _ = Mix.Task.run("app.config")
    _ = Mix.Task.run("compile")

    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:websockex)

    case parse(argv) do
      {:error, msg} ->
        Mix.shell().error(msg)
        exit({:shutdown, 1})

      {:ok, opts} ->
        case run_client(opts) do
          :ok ->
            :ok

          {:error, reason} ->
            Mix.shell().error(format_error(reason))
            exit({:shutdown, 1})
        end
    end
  end

  defp run_client(opts) do
    with {:ok, ws_token} <- Connect.ws_token(opts),
         {:ok, ws_url} <- WsUrl.from_base_url(opts.url, ws_token),
         {:ok, jwt} <- Connect.resolve_jwt(opts),
         {:ok, hints} <- Connect.parse_hints(opts[:hints]) do
      parent = self()

      ws_state = %{
        parent: parent,
        jwt: jwt,
        hints: hints,
        auth_only: opts[:auth_only] == true,
        followup: opts[:auth_only] != true and opts[:skip_followup] != true,
        resume: opts[:resume] == true,
        stream_state: false,
        assigned_row: nil,
        subscribe_ack: nil,
        phase: :welcome,
        verbose: opts[:verbose] == true
      }

      insecure = opts[:secure] != true

      case WsClient.start_link(ws_url, ws_state, insecure: insecure) do
        {:ok, pid} ->
          ref = Process.monitor(pid)

          receive do
            {:lunity_player, {:ok, _} = ok} ->
              _ = flush_down(ref)
              report_ok(ok, opts)
              :ok

            {:lunity_player, {:error, e}} ->
              _ = flush_down(ref)
              {:error, e}

            {:DOWN, ^ref, :process, _, reason} ->
              {:error, {:ws_down, reason}}
          after
            opts[:timeout] ->
              Process.exit(pid, :kill)
              {:error, :timeout}
          end

        {:error, reason} ->
          {:error, {:ws_start, reason}}
      end
    end
  end

  defp flush_down(ref) do
    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      0 -> :ok
    end
  end

  defp report_ok({:ok, {:authenticated, ack}}, opts) do
    if opts[:verbose] != true do
      IO.puts(Jason.encode!(ack))
    end
  end

  defp report_ok({:ok, {:parity, _assigned, _sub, actions_ack, meta}}, opts) do
    if opts[:verbose] != true do
      if meta[:resume] == true and opts[:resume] == true do
        IO.puts(:stderr, "[lunity.player] parity: resume path (join skipped)")
      end

      IO.puts(Jason.encode!(actions_ack))
    end
  end

  defp report_ok({:ok, {:in_world, m}}, opts) do
    if opts[:verbose] != true do
      IO.puts(Jason.encode!(m))
    end
  end

  defp report_ok(_, _), do: :ok

  defp format_error(msg) when is_binary(msg), do: msg

  defp format_error(:bad_scheme),
    do: "Invalid --url scheme (use http, https, ws, or wss)"

  defp format_error(:bad_host), do: "Invalid --url (missing host)"
  defp format_error(:bad_ws_token), do: "WebSocket token is empty"

  defp format_error({:disconnect, reason}), do: "Disconnected: #{inspect(reason)}"
  defp format_error({:ws_down, reason}), do: "WebSocket process exited: #{inspect(reason)}"
  defp format_error({:ws_start, reason}), do: "Failed to start client: #{inspect(reason)}"
  defp format_error({:mint_failed, st, body}), do: "Mint HTTP #{st}: #{inspect(body)}"
  defp format_error({:mint_req, e}), do: "Mint request failed: #{inspect(e)}"
  defp format_error(:timeout), do: "Timed out waiting for server"

  defp format_error(%{"code" => "bad_join", "message" => "instance_id required"} = err) do
    """
    #{inspect(err)}

    Hint: the Player WebSocket server is using client-driven join (`player_join` not set for
    that process). Start the HTTP endpoint from your **game** Mix project so `config` sets
    `player_join` — e.g. `cd /path/to/lunity-pong && mix lunity.edit` (not `mix lunity.edit`
    from the `lunity` repo only).
    """
    |> String.trim()
  end

  defp format_error(other), do: inspect(other)

  defp parse(argv) do
    {opts, _rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          url: :string,
          token: :string,
          jwt: :string,
          mint_key: :string,
          user_id: :string,
          player_id: :string,
          hints: :string,
          auth_only: :boolean,
          skip_followup: :boolean,
          resume: :boolean,
          verbose: :boolean,
          secure: :boolean,
          timeout: :integer
        ],
        aliases: [
          u: :url,
          t: :token,
          j: :jwt,
          v: :verbose
        ]
      )

    cond do
      invalid != [] ->
        {:error, "Unknown or invalid flags: #{inspect(invalid)}"}

      opts[:url] in [nil, ""] ->
        {:error, "Required: --url http(s)://host:port"}

      true ->
        timeout = Keyword.get(opts, :timeout, 15_000)

        {:ok,
         %{
           url: opts[:url],
           token: opts[:token],
           jwt: opts[:jwt],
           mint_key: opts[:mint_key],
           user_id: opts[:user_id],
           player_id: opts[:player_id],
           hints: opts[:hints],
           auth_only: opts[:auth_only] == true,
           skip_followup: opts[:skip_followup] == true,
           resume: opts[:resume] == true,
           verbose: opts[:verbose] == true,
           secure: opts[:secure] == true,
           timeout: timeout
         }}
    end
  end
end
