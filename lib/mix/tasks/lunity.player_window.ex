defmodule Mix.Tasks.Lunity.PlayerWindow do
  @shortdoc "wx window: live PlayerSocket `state` / `ecs` JSON (Phase 3 parity)"
  @moduledoc """
  Opens a **native wx** window and connects to `Lunity.Web.PlayerSocket` with the same
  bootstrap as `mix lunity.player`, then **stays subscribed** and renders each periodic
  **`state`** frame’s **`ecs`** snapshot as pretty-printed JSON.

  Run from your **game** project (with `config :lunity, :player_join` set), with the HTTP
  server already up (e.g. `mix lunity.edit`).

  **Path dependency:** if you change code under `lunity/` and run this task from **`pong/`**
  (or any host app), recompile the dep first or you will keep an old BEAM build:

      mix deps.compile lunity --force
      mix lunity.player_window ...

  (Compiling only inside the `lunity` repo updates `lunity/_build`, not the copy linked from
  the game project’s `_build/dev/lib/lunity`.)

      mix lunity.player_window --url http://127.0.0.1:4111 \\
        --token \"$PLAYER_WS_TOKEN\" --jwt \"$JWT\"

  Mint a dev JWT (same as `mix lunity.player`):

      mix lunity.player_window --url http://127.0.0.1:4111 \\
        --token dev_player_ws_token --mint-key dev_player_mint_key --user-id u1

  Options match `mix lunity.player` (`--resume`, `--hints`, `--verbose`, `--secure`, …).

  **Frozen ECS values?** With `mix lunity.edit`, press **Play (▶)** on the transport bar so the
  game instance is **running**. While paused, `state` snapshots repeat the same positions even
  though the player window’s tick line increments.
  """
  use Mix.Task

  alias Lunity.Player.StateWindow

  @impl Mix.Task
  def run(argv) do
    _ = Mix.Task.run("app.config")
    # Path deps are not always rebuilt by `compile` alone; stale `lunity` in
    # `<host>/_build/.../lib/lunity` is the usual reason code changes "don't apply".
    _ = Mix.Task.run("deps.compile", ["lunity"])
    _ = Mix.Task.run("compile")

    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, _} = Application.ensure_all_started(:websockex)

    _ =
      case Code.ensure_loaded(Lunity.Player.StateWindow) do
        {:module, _} ->
          beam = :code.which(Lunity.Player.StateWindow)
          Mix.shell().info("[lunity.player_window] Lunity.Player.StateWindow -> #{beam}")

        _ ->
          :ok
      end

    case parse(argv) do
      {:error, msg} ->
        Mix.shell().error(msg)
        exit({:shutdown, 1})

      {:ok, opts} ->
        _ = StateWindow.run(opts)
        :ok
    end
  end

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
          resume: :boolean,
          verbose: :boolean,
          secure: :boolean
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
        {:ok,
         %{
           url: opts[:url],
           token: opts[:token],
           jwt: opts[:jwt],
           mint_key: opts[:mint_key],
           user_id: opts[:user_id],
           player_id: opts[:player_id],
           hints: opts[:hints],
           resume: opts[:resume] == true,
           verbose: opts[:verbose] == true,
           secure: opts[:secure] == true
         }}
    end
  end
end
