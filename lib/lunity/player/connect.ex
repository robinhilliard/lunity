defmodule Lunity.Player.Connect do
  @moduledoc false

  @spec ws_token(map()) :: {:ok, String.t()} | {:error, String.t()}
  def ws_token(opts) do
    case opts[:token] || System.get_env("PLAYER_WS_TOKEN") do
      t when is_binary(t) and t != "" -> {:ok, t}
      _ -> {:error, "Missing --token or PLAYER_WS_TOKEN"}
    end
  end

  @spec resolve_jwt(map()) :: {:ok, String.t()} | {:error, term()}
  def resolve_jwt(%{jwt: jwt}) when is_binary(jwt) and jwt != "", do: {:ok, jwt}

  def resolve_jwt(%{mint_key: key, url: base, user_id: uid} = opts)
      when is_binary(key) and key != "" and is_binary(uid) and uid != "" do
    player_id = opts[:player_id] || uid
    mint_jwt(String.trim_trailing(base, "/"), key, uid, player_id, opts[:verbose] == true)
  end

  def resolve_jwt(%{mint_key: key}) when is_binary(key) and key != "",
    do: {:error, "Mint requires --user-id"}

  def resolve_jwt(_), do: {:error, "Provide --jwt or (--mint-key and --user-id)"}

  defp mint_jwt(base, mint_key, user_id, player_id, verbose) do
    url = base <> "/api/player/token"

    req =
      Req.new(
        url: url,
        method: :post,
        json: %{user_id: user_id, player_id: player_id},
        headers: %{"x-player-mint-key" => mint_key}
      )

    if verbose, do: IO.puts(:stderr, "[lunity.player] POST #{url}")

    case Req.request(req) do
      {:ok, %{status: 200, body: %{"token" => t}}} when is_binary(t) ->
        {:ok, t}

      {:ok, %{status: st, body: body}} ->
        {:error, {:mint_failed, st, body}}

      {:error, e} ->
        {:error, {:mint_req, e}}
    end
  end

  @spec parse_hints(String.t() | nil) :: {:ok, map() | nil} | {:error, String.t()}
  def parse_hints(nil), do: {:ok, nil}

  def parse_hints(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, other} -> {:error, "hints must be a JSON object, got: #{inspect(other)}"}
      {:error, _} -> {:error, "invalid JSON for --hints"}
    end
  end
end
