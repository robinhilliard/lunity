defmodule Lunity.Web.PlayerToken do
  @moduledoc """
  Dev / trusted-backend endpoint to mint player JWTs (`POST /api/player/token`).

  Requires `:player_mint_secret` and matching `X-Player-Mint-Key` header.
  Production games should replace this with OAuth + session flows that issue the same JWT shape.
  """

  import Plug.Conn

  alias Lunity.Auth.PlayerJWT

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn =
      case conn.body_params do
        %Plug.Conn.Unfetched{} ->
          Plug.Parsers.call(
            conn,
            Plug.Parsers.init(parsers: [:json], json_decoder: Jason, pass: ["*/*"])
          )

        _ ->
          conn
      end

    case Application.get_env(:lunity, :player_mint_secret) do
      secret when is_binary(secret) and secret != "" ->
        mint_with_secret(conn, secret)

      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(404, Jason.encode!(%{error: "mint_disabled"}))
    end
  end

  defp mint_with_secret(conn, secret) do
    case get_req_header(conn, "x-player-mint-key") do
      [^secret] -> do_mint(conn)
      _ -> send_resp(conn, 401, Jason.encode!(%{error: "unauthorized"}))
    end
  end

  defp do_mint(conn) do
    jwt_secret = Application.get_env(:lunity, :player_jwt_secret)

    cond do
      not (is_binary(jwt_secret) and jwt_secret != "") ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(503, Jason.encode!(%{error: "jwt_not_configured"}))

      true ->
        case conn.body_params do
          %{"user_id" => user_id} = body when is_binary(user_id) ->
            player_id = Map.get(body, "player_id") || user_id

            signer = PlayerJWT.signer_from_secret(jwt_secret)

            case PlayerJWT.generate_and_sign(
                   %{"user_id" => user_id, "player_id" => player_id},
                   signer
                 ) do
              {:ok, token, _claims} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(200, Jason.encode!(%{token: token}))

              {:error, reason} ->
                conn
                |> put_resp_content_type("application/json")
                |> send_resp(500, Jason.encode!(%{error: "sign_failed", detail: inspect(reason)}))
            end

          _ ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(400, Jason.encode!(%{error: "expected JSON with user_id (string)"}))
        end
    end
  end
end
